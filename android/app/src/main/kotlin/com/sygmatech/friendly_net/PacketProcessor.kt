package com.sygmatech.friendly_net

import android.util.Log
import kotlinx.coroutines.*
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * PacketProcessor — Exit-Node IP Packet Engine
 *
 * Reçoit des paquets IP bruts du guest via le relay WebSocket.
 * Parse les headers IP/TCP/UDP, ouvre de vraies connexions Internet,
 * et reconstruit des paquets IP valides pour les réponses.
 *
 * Architecture :
 *   Guest TUN → raw IP → WebSocket relay → PacketProcessor
 *   PacketProcessor → parse IP → Socket.connect() → Internet
 *   Internet → response → construct IP packet → relay → Guest TUN
 *
 * Supporte :
 *   - TCP (HTTP, HTTPS, tout trafic TCP)
 *   - UDP port 53 (DNS) — renvoyé vers 1.1.1.1
 */
class PacketProcessor(
    private val onResponsePacket: (ByteArray) -> Unit,
    private val onMetrics: (bytesIn: Long, bytesOut: Long) -> Unit = { _, _ -> },
) {
    companion object {
        private const val TAG = "FN-Packet"

        // IP Protocol numbers
        private const val PROTO_TCP = 6
        private const val PROTO_UDP = 17

        // TCP flags
        private const val TCP_FIN = 0x01
        private const val TCP_SYN = 0x02
        private const val TCP_RST = 0x04
        private const val TCP_PSH = 0x08
        private const val TCP_ACK = 0x10

        // Guest TUN address
        private const val GUEST_IP = "10.99.0.2"
    }

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val sessions = ConcurrentHashMap<String, TcpSession>()
    private val nextFakeSeq = AtomicInteger(1000)

    @Volatile var totalBytesIn = 0L; private set
    @Volatile var totalBytesOut = 0L; private set
    @Volatile var activeConnections = 0; private set

    // ═══════════════════════════════════════════
    // PROCESS INCOMING RAW IP PACKET
    // ═══════════════════════════════════════════

    fun processPacket(rawPacket: ByteArray) {
        if (rawPacket.size < 20) return

        // Parse IP header
        val version = (rawPacket[0].toInt() and 0xF0) ushr 4
        if (version != 4) return // IPv4 only for now

        val ihl = (rawPacket[0].toInt() and 0x0F) * 4
        if (rawPacket.size < ihl) return

        val totalLen = ((rawPacket[2].toInt() and 0xFF) shl 8) or (rawPacket[3].toInt() and 0xFF)
        val protocol = rawPacket[9].toInt() and 0xFF

        val srcIp = formatIp(rawPacket, 12)
        val dstIp = formatIp(rawPacket, 16)

        when (protocol) {
            PROTO_TCP -> handleTcpPacket(rawPacket, ihl, srcIp, dstIp)
            PROTO_UDP -> handleUdpPacket(rawPacket, ihl, srcIp, dstIp)
            else -> Log.v(TAG, "Ignored proto $protocol")
        }
    }

    // ═══════════════════════════════════════════
    // TCP HANDLING
    // ═══════════════════════════════════════════

    private fun handleTcpPacket(packet: ByteArray, ipHeaderLen: Int, srcIp: String, dstIp: String) {
        if (packet.size < ipHeaderLen + 20) return

        val tcpOffset = ipHeaderLen
        val srcPort = ((packet[tcpOffset].toInt() and 0xFF) shl 8) or
                (packet[tcpOffset + 1].toInt() and 0xFF)
        val dstPort = ((packet[tcpOffset + 2].toInt() and 0xFF) shl 8) or
                (packet[tcpOffset + 3].toInt() and 0xFF)
        val seqNum = readInt(packet, tcpOffset + 4)
        val ackNum = readInt(packet, tcpOffset + 8)
        val dataOffset = ((packet[tcpOffset + 12].toInt() and 0xF0) ushr 4) * 4
        val flags = packet[tcpOffset + 13].toInt() and 0x3F

        val key = "$srcPort→$dstIp:$dstPort"
        val payloadStart = tcpOffset + dataOffset
        val payloadLen = packet.size - payloadStart

        // SYN — New TCP connection
        if (flags and TCP_SYN != 0 && flags and TCP_ACK == 0) {
            Log.d(TAG, "TCP SYN $key (seq=$seqNum)")
            openTcpSession(key, srcIp, srcPort, dstIp, dstPort, seqNum)
            return
        }

        val session = sessions[key] ?: return

        // ACK only (no data) — likely completing handshake or keepalive
        if (payloadLen <= 0 && flags and TCP_ACK != 0) {
            session.guestAckNum = ackNum.toLong() and 0xFFFFFFFFL
            return
        }

        // FIN or RST — Close connection
        if (flags and TCP_FIN != 0 || flags and TCP_RST != 0) {
            Log.d(TAG, "TCP ${if (flags and TCP_FIN != 0) "FIN" else "RST"} $key")
            closeTcpSession(key)
            return
        }

        // Data packet — forward payload to real socket
        if (payloadLen > 0) {
            val payload = packet.copyOfRange(payloadStart, packet.size)
            session.guestSeqNum = (seqNum.toLong() and 0xFFFFFFFFL) + payloadLen
            totalBytesOut += payloadLen

            scope.launch {
                try {
                    session.socket?.getOutputStream()?.apply {
                        write(payload)
                        flush()
                    }
                } catch (e: Exception) {
                    Log.v(TAG, "TCP write $key: ${e.message}")
                    closeTcpSession(key)
                }
            }

            // Send ACK back to guest
            val ackPacket = buildTcpPacket(
                srcIp = dstIp, dstIp = srcIp,
                srcPort = dstPort, dstPort = srcPort,
                seqNum = session.hostSeqNum,
                ackNum = session.guestSeqNum,
                flags = TCP_ACK,
                payload = ByteArray(0)
            )
            onResponsePacket(ackPacket)
        }
    }

    private fun openTcpSession(
        key: String, srcIp: String, srcPort: Int,
        dstIp: String, dstPort: Int, guestIsn: Int
    ) {
        // Remove existing session if any
        closeTcpSession(key, silent = true)

        val hostIsn = nextFakeSeq.addAndGet(64000).toLong() and 0xFFFFFFFFL
        val session = TcpSession(
            srcIp = srcIp, srcPort = srcPort,
            dstIp = dstIp, dstPort = dstPort,
            guestIsn = guestIsn.toLong() and 0xFFFFFFFFL,
            hostIsn = hostIsn,
        )
        sessions[key] = session
        activeConnections = sessions.size

        scope.launch {
            try {
                val sock = Socket()
                sock.connect(InetSocketAddress(dstIp, dstPort), 10_000)
                sock.soTimeout = 0
                session.socket = sock
                session.connected = true
                Log.d(TAG, "TCP connected $key → $dstIp:$dstPort")

                // Send SYN-ACK to guest
                val synAck = buildTcpPacket(
                    srcIp = dstIp, dstIp = srcIp,
                    srcPort = dstPort, dstPort = srcPort,
                    seqNum = hostIsn,
                    ackNum = (session.guestIsn + 1) and 0xFFFFFFFFL,
                    flags = TCP_SYN or TCP_ACK,
                    payload = ByteArray(0)
                )
                session.hostSeqNum = (hostIsn + 1) and 0xFFFFFFFFL
                session.guestSeqNum = (session.guestIsn + 1) and 0xFFFFFFFFL
                onResponsePacket(synAck)

                // Read loop: Internet → guest
                readFromSocket(key, session, sock.getInputStream())

            } catch (e: Exception) {
                Log.w(TAG, "TCP connect fail $key: ${e.message}")
                // Send RST to guest
                val rst = buildTcpPacket(
                    srcIp = dstIp, dstIp = srcIp,
                    srcPort = dstPort, dstPort = srcPort,
                    seqNum = hostIsn,
                    ackNum = (session.guestIsn + 1) and 0xFFFFFFFFL,
                    flags = TCP_RST or TCP_ACK,
                    payload = ByteArray(0)
                )
                onResponsePacket(rst)
                sessions.remove(key)
                activeConnections = sessions.size
            }
        }
    }

    private fun readFromSocket(key: String, session: TcpSession, input: InputStream) {
        val buf = ByteArray(4096)
        try {
            while (true) {
                val n = input.read(buf)
                if (n < 0) break

                totalBytesIn += n
                val payload = buf.copyOf(n)

                // Construct IP+TCP data packet to guest
                val dataPacket = buildTcpPacket(
                    srcIp = session.dstIp, dstIp = session.srcIp,
                    srcPort = session.dstPort, dstPort = session.srcPort,
                    seqNum = session.hostSeqNum,
                    ackNum = session.guestSeqNum,
                    flags = TCP_ACK or TCP_PSH,
                    payload = payload
                )
                session.hostSeqNum = (session.hostSeqNum + n) and 0xFFFFFFFFL
                onResponsePacket(dataPacket)
                onMetrics(totalBytesIn, totalBytesOut)
            }
        } catch (_: Exception) {}

        // Connection closed by remote — send FIN-ACK
        Log.d(TAG, "TCP remote close $key")
        val fin = buildTcpPacket(
            srcIp = session.dstIp, dstIp = session.srcIp,
            srcPort = session.dstPort, dstPort = session.srcPort,
            seqNum = session.hostSeqNum,
            ackNum = session.guestSeqNum,
            flags = TCP_FIN or TCP_ACK,
            payload = ByteArray(0)
        )
        onResponsePacket(fin)
        sessions.remove(key)
        activeConnections = sessions.size
    }

    private fun closeTcpSession(key: String, silent: Boolean = false) {
        val session = sessions.remove(key) ?: return
        activeConnections = sessions.size
        try { session.socket?.close() } catch (_: Exception) {}

        if (!silent && session.connected) {
            // Send FIN-ACK to guest
            val fin = buildTcpPacket(
                srcIp = session.dstIp, dstIp = session.srcIp,
                srcPort = session.dstPort, dstPort = session.srcPort,
                seqNum = session.hostSeqNum,
                ackNum = session.guestSeqNum,
                flags = TCP_FIN or TCP_ACK,
                payload = ByteArray(0)
            )
            onResponsePacket(fin)
        }
    }

    // ═══════════════════════════════════════════
    // UDP HANDLING (DNS only)
    // ═══════════════════════════════════════════

    private fun handleUdpPacket(packet: ByteArray, ipHeaderLen: Int, srcIp: String, dstIp: String) {
        if (packet.size < ipHeaderLen + 8) return

        val udpOffset = ipHeaderLen
        val srcPort = ((packet[udpOffset].toInt() and 0xFF) shl 8) or
                (packet[udpOffset + 1].toInt() and 0xFF)
        val dstPort = ((packet[udpOffset + 2].toInt() and 0xFF) shl 8) or
                (packet[udpOffset + 3].toInt() and 0xFF)

        // Only handle DNS (port 53)
        if (dstPort != 53) return

        val udpPayload = packet.copyOfRange(udpOffset + 8, packet.size)
        if (udpPayload.isEmpty()) return

        scope.launch {
            try {
                // Forward DNS query to 1.1.1.1 via real UDP
                val dnsSocket = java.net.DatagramSocket()
                dnsSocket.soTimeout = 5000
                val dnsPacket = java.net.DatagramPacket(
                    udpPayload, udpPayload.size,
                    java.net.InetAddress.getByName("1.1.1.1"), 53
                )
                dnsSocket.send(dnsPacket)

                val respBuf = ByteArray(512)
                val respPacket = java.net.DatagramPacket(respBuf, respBuf.size)
                dnsSocket.receive(respPacket)
                dnsSocket.close()

                val dnsResponse = respBuf.copyOf(respPacket.length)

                // Construct UDP response IP packet
                val responseIp = buildUdpPacket(
                    srcIp = dstIp, dstIp = srcIp,
                    srcPort = dstPort, dstPort = srcPort,
                    payload = dnsResponse
                )
                onResponsePacket(responseIp)

            } catch (e: Exception) {
                Log.v(TAG, "DNS forward fail: ${e.message}")
            }
        }
    }

    // ═══════════════════════════════════════════
    // IP PACKET CONSTRUCTION
    // ═══════════════════════════════════════════

    private fun buildTcpPacket(
        srcIp: String, dstIp: String,
        srcPort: Int, dstPort: Int,
        seqNum: Long, ackNum: Long,
        flags: Int,
        payload: ByteArray
    ): ByteArray {
        val ipHeaderLen = 20
        val tcpHeaderLen = 20
        val totalLen = ipHeaderLen + tcpHeaderLen + payload.size
        val packet = ByteArray(totalLen)

        // ─── IP Header ───
        packet[0] = 0x45.toByte() // Version=4, IHL=5
        // packet[1] = 0 // DSCP/ECN
        writeShort(packet, 2, totalLen)
        // packet[4..5] = identification (0)
        // packet[6..7] = flags+fragment (0)
        packet[8] = 64 // TTL
        packet[9] = PROTO_TCP.toByte()
        // packet[10..11] = checksum (calculated below)
        writeIp(packet, 12, srcIp)
        writeIp(packet, 16, dstIp)
        writeShort(packet, 10, ipChecksum(packet, 0, ipHeaderLen))

        // ─── TCP Header ───
        val t = ipHeaderLen
        writeShort(packet, t, srcPort)
        writeShort(packet, t + 2, dstPort)
        writeInt(packet, t + 4, seqNum)
        writeInt(packet, t + 8, ackNum)
        packet[t + 12] = 0x50.toByte() // Data offset = 5 (20 bytes)
        packet[t + 13] = flags.toByte()
        writeShort(packet, t + 14, 65535) // Window size
        // packet[t + 16..17] = checksum (calculated below)
        // packet[t + 18..19] = urgent pointer (0)

        // Copy payload
        if (payload.isNotEmpty()) {
            System.arraycopy(payload, 0, packet, t + tcpHeaderLen, payload.size)
        }

        // TCP checksum (includes pseudo-header)
        val tcpLen = tcpHeaderLen + payload.size
        writeShort(packet, t + 16, tcpChecksum(packet, ipHeaderLen, srcIp, dstIp, PROTO_TCP, tcpLen))

        return packet
    }

    private fun buildUdpPacket(
        srcIp: String, dstIp: String,
        srcPort: Int, dstPort: Int,
        payload: ByteArray
    ): ByteArray {
        val ipHeaderLen = 20
        val udpHeaderLen = 8
        val totalLen = ipHeaderLen + udpHeaderLen + payload.size
        val packet = ByteArray(totalLen)

        // IP Header
        packet[0] = 0x45.toByte()
        writeShort(packet, 2, totalLen)
        packet[8] = 64
        packet[9] = PROTO_UDP.toByte()
        writeIp(packet, 12, srcIp)
        writeIp(packet, 16, dstIp)
        writeShort(packet, 10, ipChecksum(packet, 0, ipHeaderLen))

        // UDP Header
        val u = ipHeaderLen
        writeShort(packet, u, srcPort)
        writeShort(packet, u + 2, dstPort)
        writeShort(packet, u + 4, udpHeaderLen + payload.size)
        // UDP checksum optional for IPv4: leave as 0

        // Payload
        System.arraycopy(payload, 0, packet, u + udpHeaderLen, payload.size)

        return packet
    }

    // ═══════════════════════════════════════════
    // CHECKSUM UTILITIES
    // ═══════════════════════════════════════════

    private fun ipChecksum(data: ByteArray, offset: Int, length: Int): Int {
        var sum = 0L
        var i = offset
        var len = length
        while (len > 1) {
            sum += ((data[i].toInt() and 0xFF) shl 8) or (data[i + 1].toInt() and 0xFF)
            i += 2
            len -= 2
        }
        if (len > 0) sum += (data[i].toInt() and 0xFF) shl 8
        while (sum shr 16 != 0L) sum = (sum and 0xFFFF) + (sum shr 16)
        return (sum.toInt().inv()) and 0xFFFF
    }

    private fun tcpChecksum(
        packet: ByteArray, tcpOffset: Int,
        srcIp: String, dstIp: String,
        proto: Int, tcpLen: Int
    ): Int {
        // Pseudo-header: srcIP(4) + dstIP(4) + zero(1) + proto(1) + tcpLen(2) = 12 bytes
        val pseudo = ByteArray(12 + tcpLen)
        writeIp(pseudo, 0, srcIp)
        writeIp(pseudo, 4, dstIp)
        pseudo[8] = 0
        pseudo[9] = proto.toByte()
        writeShort(pseudo, 10, tcpLen)
        // Copy TCP segment (with checksum field zeroed)
        System.arraycopy(packet, tcpOffset, pseudo, 12, tcpLen)
        // Zero out checksum field in pseudo
        pseudo[12 + 16] = 0
        pseudo[12 + 17] = 0

        return ipChecksum(pseudo, 0, pseudo.size)
    }

    // ═══════════════════════════════════════════
    // BYTE UTILITIES
    // ═══════════════════════════════════════════

    private fun formatIp(data: ByteArray, offset: Int): String {
        return "${data[offset].toInt() and 0xFF}.${data[offset+1].toInt() and 0xFF}." +
                "${data[offset+2].toInt() and 0xFF}.${data[offset+3].toInt() and 0xFF}"
    }

    private fun writeIp(data: ByteArray, offset: Int, ip: String) {
        val parts = ip.split(".")
        if (parts.size != 4) return
        for (i in 0..3) data[offset + i] = (parts[i].toIntOrNull() ?: 0).toByte()
    }

    private fun readInt(data: ByteArray, offset: Int): Int {
        return ((data[offset].toInt() and 0xFF) shl 24) or
                ((data[offset+1].toInt() and 0xFF) shl 16) or
                ((data[offset+2].toInt() and 0xFF) shl 8) or
                (data[offset+3].toInt() and 0xFF)
    }

    private fun writeInt(data: ByteArray, offset: Int, value: Long) {
        data[offset]     = ((value shr 24) and 0xFF).toByte()
        data[offset + 1] = ((value shr 16) and 0xFF).toByte()
        data[offset + 2] = ((value shr 8) and 0xFF).toByte()
        data[offset + 3] = (value and 0xFF).toByte()
    }

    private fun writeShort(data: ByteArray, offset: Int, value: Int) {
        data[offset]     = ((value shr 8) and 0xFF).toByte()
        data[offset + 1] = (value and 0xFF).toByte()
    }

    // ═══════════════════════════════════════════
    // CLEANUP
    // ═══════════════════════════════════════════

    fun dispose() {
        scope.cancel()
        sessions.values.forEach { s ->
            try { s.socket?.close() } catch (_: Exception) {}
        }
        sessions.clear()
        activeConnections = 0
    }

    // ═══════════════════════════════════════════
    // TCP SESSION DATA
    // ═══════════════════════════════════════════

    data class TcpSession(
        val srcIp: String,
        val srcPort: Int,
        val dstIp: String,
        val dstPort: Int,
        val guestIsn: Long,
        val hostIsn: Long,
        var guestSeqNum: Long = 0L,
        var hostSeqNum: Long = 0L,
        var guestAckNum: Long = 0L,
        var socket: Socket? = null,
        var connected: Boolean = false,
    )
}

package com.sygmatech.friendly_net

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.VpnService
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.net.InetAddress

class MainActivity : FlutterActivity() {

    // ─── Channels ───
    private val SYSTEM_CHANNEL    = "friendlynet/system"
    private val VPN_CHANNEL       = "friendlynet/vpn"
    private val RELAY_CHANNEL     = "friendlynet/relay"
    private val WIFI_DIRECT_CH    = "friendlynet/wifidirect"
    private val WIFI_EVENT_CH     = "friendlynet/wifidirect/events"

    private val VPN_PERMISSION_CODE = 101

    // ─── State ───
    private var pendingVpnResult: MethodChannel.Result? = null
    private var pendingVpnArgs: Map<String, Any>? = null

    private var wifiDirectManager: WifiDirectManager? = null
    private var wifiEventSink: EventChannel.EventSink? = null

    // ═══════════════════════════════════════════
    // CONFIGURE FLUTTER ENGINE
    // ═══════════════════════════════════════════

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        setupSystemChannel(flutterEngine)
        setupVpnChannel(flutterEngine)
        setupRelayChannel(flutterEngine)
        setupWifiDirectChannel(flutterEngine)
    }

    // ─── System Protection ─────────────────────────────────────────────
    private fun setupSystemChannel(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, SYSTEM_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestBatteryOptExemption" -> {
                        requestBatteryOptimizationExemption()
                        result.success(true)
                    }
                    "isBatteryOptExempt" -> result.success(isBatteryOptExempt())

                    "requestUnrestrictedData" -> {
                        openUnrestrictedDataSettings()
                        result.success(true)
                    }
                    // ─── New: ouvre directement les settings réseau ───
                    "openDataSaverSettings" -> {
                        openDataSaverExemption()
                        result.success(true)
                    }
                    "openBatterySettings" -> {
                        openBatterySettings()
                        result.success(true)
                    }
                    "openAppSettings" -> {
                        openAppDetails()
                        result.success(true)
                    }

                    "startForeground" -> {
                        val title = call.argument<String>("title") ?: "FriendlyNET"
                        val body  = call.argument<String>("body") ?: "Actif"
                        startForegroundGuard(title, body)
                        result.success(true)
                    }
                    "stopForeground" -> {
                        stopForegroundGuard()
                        result.success(true)
                    }

                    "isBatteryOptExempt" -> result.success(isBatteryOptExempt())

                    else -> result.notImplemented()
                }
            }
    }

    // ─── VPN Service ───────────────────────────────────────────────────
    private fun setupVpnChannel(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, VPN_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startVpn" -> {
                        @Suppress("UNCHECKED_CAST")
                        val args = (call.arguments as? Map<String, Any> ?: emptyMap()).toMutableMap()
                        // Injecter l'IP locale WiFi pour TailscaleMode (chemin LAN direct)
                        getLocalWifiIp()?.let { args["localIp"] = it }
                        val prepareIntent = VpnService.prepare(this)
                        if (prepareIntent != null) {
                            pendingVpnResult = result
                            pendingVpnArgs = args
                            startActivityForResult(prepareIntent, VPN_PERMISSION_CODE)
                        } else {
                            launchVpnService(args)
                            result.success(true)
                        }
                    }
                    "stopVpn" -> {
                        startService(Intent(this, FriendlyNetVpnService::class.java).apply {
                            putExtra(FriendlyNetVpnService.EXTRA_STOP, true)
                        })
                        result.success(true)
                    }
                    "prepareVpn" -> {
                        // Check if VPN permission is already granted
                        val prepareIntent = VpnService.prepare(this)
                        if (prepareIntent != null) {
                            // Need to request permission — show system dialog
                            pendingVpnResult = result
                            pendingVpnArgs = null // just checking, not starting
                            startActivityForResult(prepareIntent, VPN_PERMISSION_CODE)
                        } else {
                            // Already granted
                            result.success(true)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ─── DNS Relay Instance ───
    private var dnsRelay: DnsRelayEngine? = null

    // ─── TCP Forwarding Manager (Host side) ───
    private val tcpChannels = java.util.concurrent.ConcurrentHashMap<Int, java.net.Socket>()
    private val tcpScope = kotlinx.coroutines.CoroutineScope(
        kotlinx.coroutines.Dispatchers.IO + kotlinx.coroutines.SupervisorJob()
    )
    private var relayMethodChannel: MethodChannel? = null
    @Volatile private var totalBytesIn = 0L
    @Volatile private var totalBytesOut = 0L
    @Volatile private var totalTcpConns = 0

    // ─── PacketProcessor (raw IP packet engine) ───
    private var packetProcessor: PacketProcessor? = null

    private fun ensurePacketProcessor() {
        if (packetProcessor != null) return
        packetProcessor = PacketProcessor(
            onResponsePacket = { responseIpPacket ->
                // Send constructed IP response packet back to Dart → EdgeRelay → Guest
                runOnUiThread {
                    relayMethodChannel?.invokeMethod("responsePacket", mapOf(
                        "data" to responseIpPacket.toList(),
                    ))
                }
            },
            onMetrics = { bytesIn, bytesOut ->
                runOnUiThread {
                    relayMethodChannel?.invokeMethod("metricsUpdate", mapOf(
                        "bytesIn" to bytesIn,
                        "bytesOut" to bytesOut,
                    ))
                }
            },
        )
        android.util.Log.d("FN-TCP", "PacketProcessor initialized")
    }

    // ─── Relay Service ─────────────────────────────────────────────────
    private fun setupRelayChannel(engine: FlutterEngine) {
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, RELAY_CHANNEL)
        relayMethodChannel = channel
        channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "startRelay" -> {
                        val port = call.argument<Int>("port") ?: 8899
                        val i = Intent(this, FriendlyNetRelayService::class.java).apply {
                            putExtra(FriendlyNetRelayService.EXTRA_PORT, port)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(i)
                        else startService(i)

                        // Start DNS relay alongside TCP relay
                        if (dnsRelay == null) dnsRelay = DnsRelayEngine()
                        dnsRelay?.start()

                        result.success(true)
                    }
                    "stopRelay" -> {
                        startService(Intent(this, FriendlyNetRelayService::class.java).apply {
                            putExtra(FriendlyNetRelayService.EXTRA_STOP, true)
                        })

                        // Stop DNS relay alongside TCP relay
                        dnsRelay?.stop()

                        // Close all TCP forwarding channels
                        closeTcpAll()

                        result.success(true)
                    }
                    "startDns" -> {
                        if (dnsRelay == null) dnsRelay = DnsRelayEngine()
                        dnsRelay?.start()
                        result.success(true)
                    }
                    "stopDns" -> {
                        dnsRelay?.stop()
                        result.success(true)
                    }
                    "relayStatus" -> {
                        result.success(mapOf(
                            "dnsRunning" to (dnsRelay?.isRunning ?: false),
                            "dnsCacheSize" to (dnsRelay?.cacheSize ?: 0),
                        ))
                    }

                    // ─── TCP Forwarding (Host-side exit node) ───

                    "forwardTcp" -> {
                        val ch   = call.argument<Int>("channelId") ?: 0
                        val host = call.argument<String>("host") ?: ""
                        val port = call.argument<Int>("port") ?: 0
                        if (ch == 0 || host.isEmpty() || port == 0) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        openTcpChannel(ch, host, port)
                        result.success(true)
                    }

                    "relayData" -> {
                        val ch   = call.argument<Int>("channelId") ?: 0
                        @Suppress("UNCHECKED_CAST")
                        val data = call.argument<ByteArray>("data")
                            ?: (call.argument<List<Int>>("data"))?.let { list ->
                                ByteArray(list.size) { list[it].toByte() }
                            }
                        if (ch != 0 && data != null) {
                            writeTcpChannel(ch, data)
                        }
                        result.success(true)
                    }

                    "closeChannel" -> {
                        val ch = call.argument<Int>("channelId") ?: 0
                        closeTcpChannel(ch)
                        result.success(true)
                    }

                    "processPacket" -> {
                        // Raw IP packet from guest → PacketProcessor
                        @Suppress("UNCHECKED_CAST")
                        val data = call.argument<ByteArray>("data")
                            ?: (call.argument<List<Int>>("data"))?.let { list ->
                                ByteArray(list.size) { list[it].toByte() }
                            }
                        if (data != null) {
                            ensurePacketProcessor()
                            packetProcessor?.processPacket(data)
                        }
                        result.success(true)
                    }

                    "getRelayMetrics" -> {
                        result.success(mapOf(
                            "activeChannels" to tcpChannels.size,
                            "totalConnections" to totalTcpConns,
                            "bytesIn" to (packetProcessor?.totalBytesIn ?: totalBytesIn),
                            "bytesOut" to (packetProcessor?.totalBytesOut ?: totalBytesOut),
                            "activeConns" to (packetProcessor?.activeConnections ?: 0),
                        ))
                    }

                    else -> result.notImplemented()
                }
            }
    }

    // ─── TCP Channel Management ───

    private fun openTcpChannel(channelId: Int, host: String, port: Int) {
        tcpScope.launch {
            try {
                val socket = java.net.Socket()
                socket.connect(java.net.InetSocketAddress(host, port), 10_000)
                socket.soTimeout = 0
                tcpChannels[channelId] = socket
                totalTcpConns++

                android.util.Log.d("FN-TCP", "[$channelId] Connected → $host:$port")

                // Notify Dart that connection is established
                runOnUiThread {
                    relayMethodChannel?.invokeMethod("tcpConnected", mapOf(
                        "channelId" to channelId,
                    ))
                }

                // Read loop: Internet → Dart → EdgeRelay → Worker → Guest
                val buf = ByteArray(8192)
                val inputStream = socket.getInputStream()
                try {
                    while (true) {
                        val n = inputStream.read(buf)
                        if (n < 0) break
                        totalBytesIn += n
                        val data = buf.copyOf(n)
                        // Send response data back to Dart
                        runOnUiThread {
                            relayMethodChannel?.invokeMethod("tcpData", mapOf(
                                "channelId" to channelId,
                                "data" to data.toList(),
                            ))
                        }
                    }
                } catch (_: Exception) {}

                android.util.Log.d("FN-TCP", "[$channelId] Socket closed by remote")
                tcpChannels.remove(channelId)

                runOnUiThread {
                    relayMethodChannel?.invokeMethod("tcpClosed", mapOf(
                        "channelId" to channelId,
                    ))
                }
            } catch (e: Exception) {
                android.util.Log.w("FN-TCP", "[$channelId] Connect fail: ${e.message}")
                runOnUiThread {
                    relayMethodChannel?.invokeMethod("tcpError", mapOf(
                        "channelId" to channelId,
                        "error" to (e.message ?: "unknown"),
                    ))
                }
            }
        }
    }

    private fun writeTcpChannel(channelId: Int, data: ByteArray) {
        tcpScope.launch {
            try {
                val socket = tcpChannels[channelId] ?: return@launch
                socket.getOutputStream().write(data)
                socket.getOutputStream().flush()
                totalBytesOut += data.size
            } catch (e: Exception) {
                android.util.Log.v("FN-TCP", "[$channelId] Write error: ${e.message}")
                closeTcpChannel(channelId)
            }
        }
    }

    private fun closeTcpChannel(channelId: Int) {
        val socket = tcpChannels.remove(channelId) ?: return
        try { socket.close() } catch (_: Exception) {}
        android.util.Log.d("FN-TCP", "[$channelId] Closed")
    }

    private fun closeTcpAll() {
        tcpChannels.forEach { (id, socket) ->
            try { socket.close() } catch (_: Exception) {}
        }
        tcpChannels.clear()
        android.util.Log.d("FN-TCP", "All channels closed")
    }

    // ─── WiFi Direct Channel ───────────────────────────────────────────
    private fun setupWifiDirectChannel(engine: FlutterEngine) {
        // Method channel : commandes
        MethodChannel(engine.dartExecutor.binaryMessenger, WIFI_DIRECT_CH)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialize" -> {
                        val mgr = WifiDirectManager(applicationContext)
                        mgr.initialize()
                        mgr.setCallbacks(
                            onPeers = { peers ->
                                val list = peers.map {
                                    mapOf("mac" to it.mac, "name" to it.name, "status" to it.statusLabel)
                                }
                                wifiEventSink?.success(mapOf("type" to "peers", "data" to list))
                            },
                            onConn = { ip ->
                                wifiEventSink?.success(mapOf("type" to "connected", "ip" to ip))
                            },
                            onErr = { msg ->
                                wifiEventSink?.success(mapOf("type" to "error", "msg" to msg))
                            },
                        )
                        wifiDirectManager = mgr
                        result.success(true)
                    }
                    "startDiscovery" -> {
                        wifiDirectManager?.startDiscovery()
                        result.success(true)
                    }
                    "stopDiscovery" -> {
                        wifiDirectManager?.stopDiscovery()
                        result.success(true)
                    }
                    "connect" -> {
                        val mac = call.argument<String>("mac") ?: ""
                        val peer = wifiDirectManager?.peers?.value?.find { it.mac == mac }
                        if (peer != null) {
                            wifiDirectManager?.connectToPeer(peer)
                            result.success(true)
                        } else {
                            result.error("NOT_FOUND", "Pair introuvable: $mac", null)
                        }
                    }
                    "disconnect" -> {
                        wifiDirectManager?.disconnect()
                        result.success(true)
                    }
                    "cleanup" -> {
                        wifiDirectManager?.cleanup()
                        wifiDirectManager = null
                        result.success(true)
                    }
                    "peers" -> {
                        val list = wifiDirectManager?.peers?.value?.map {
                            mapOf("mac" to it.mac, "name" to it.name, "status" to it.statusLabel)
                        } ?: emptyList<Map<String,String>>()
                        result.success(list)
                    }
                    else -> result.notImplemented()
                }
            }

        // Event channel : updates en temps réel
        EventChannel(engine.dartExecutor.binaryMessenger, WIFI_EVENT_CH)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                    wifiEventSink = sink
                }
                override fun onCancel(args: Any?) {
                    wifiEventSink = null
                }
            })
    }

    // ═══════════════════════════════════════════
    // VPN PERMISSION RESULT
    // ═══════════════════════════════════════════

    @Deprecated("Required for VPN permission flow")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == VPN_PERMISSION_CODE) {
            if (resultCode == RESULT_OK) {
                pendingVpnArgs?.let { launchVpnService(it) }
                pendingVpnResult?.success(true)
            } else {
                pendingVpnResult?.success(false)
            }
            pendingVpnResult = null
            pendingVpnArgs = null
        } else {
            @Suppress("DEPRECATION")
            super.onActivityResult(requestCode, resultCode, data)
        }
    }

    private fun launchVpnService(args: Map<String, Any>) {
        val i = Intent(this, FriendlyNetVpnService::class.java).apply {
            putExtra(FriendlyNetVpnService.EXTRA_NODE_ID,    args["nodeId"]    as? String ?: "")
            putExtra(FriendlyNetVpnService.EXTRA_USER_ID,    args["userId"]    as? String ?: "")
            putExtra(FriendlyNetVpnService.EXTRA_WORKER_URL, args["workerUrl"] as? String ?: "")
            putExtra(FriendlyNetVpnService.EXTRA_TUNNEL_KEY, args["tunnelKey"] as? String ?: "")
            putExtra(FriendlyNetVpnService.EXTRA_KEEPALIVE,  (args["keepaliveInterval"] as? Int) ?: 15)
            putExtra(FriendlyNetVpnService.EXTRA_LOW_BW,     (args["lowBandwidth"] as? Boolean) ?: false)
            // ─── TailscaleMode : IP locale pour tentative LAN directe ───
            (args["localIp"] as? String)?.let { putExtra(FriendlyNetVpnService.EXTRA_LOCAL_IP, it) }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(i)
        else startService(i)
    }

    /** Récupère l'adresse IP locale WiFi de l'appareil (pour tentative LAN de TailscaleMode). */
    @Suppress("DEPRECATION")
    private fun getLocalWifiIp(): String? {
        return try {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val ip = wm.connectionInfo.ipAddress
            if (ip == 0) return null
            // Convertir l'int little-endian en adresse IP lisible
            InetAddress.getByAddress(
                byteArrayOf(
                    (ip and 0xff).toByte(),
                    (ip shr 8 and 0xff).toByte(),
                    (ip shr 16 and 0xff).toByte(),
                    (ip shr 24 and 0xff).toByte()
                )
            ).hostAddress
        } catch (_: Exception) { null }
    }

    // ═══════════════════════════════════════════
    // BATTERY OPTIMIZATION
    // ═══════════════════════════════════════════

    private fun requestBatteryOptimizationExemption() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                try {
                    startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                        data = Uri.parse("package:$packageName")
                    })
                } catch (_: Exception) { openBatterySettings() }
            }
        }
    }

    private fun isBatteryOptExempt(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            return pm.isIgnoringBatteryOptimizations(packageName)
        }
        return true
    }

    /** Ouvre directement la page batterie de l'app dans les paramètres système. */
    private fun openBatterySettings() {
        try {
            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:$packageName")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            })
        } catch (_: Exception) {}
    }

    // ═══════════════════════════════════════════
    // UNRESTRICTED DATA (ZeroTier / Background data)
    // ═══════════════════════════════════════════

    /**
     * Ouvre le paramètre "Données non restreintes" (unrestricted data) pour cette app.
     * Critique pour que FriendlyNET survive quand le mode "Économie de données" est actif.
     *
     * Android tue les apps background qui ne sont pas en "unrestricted data"
     * quand le mode Data Saver est activé — typique quand Orange throttle à 64 Kbps.
     */
    private fun openUnrestrictedDataSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                // ACTION_IGNORE_BACKGROUND_DATA_RESTRICTIONS_SETTINGS ouvre
                // directement le paramètre "Données non restreintes"
                startActivity(Intent(Settings.ACTION_IGNORE_BACKGROUND_DATA_RESTRICTIONS_SETTINGS).apply {
                    data = Uri.parse("package:$packageName")
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                })
            } catch (_: Exception) {
                // Fallback si non supporté : page détails de l'app
                openAppDetails()
            }
        } else {
            openAppDetails()
        }
    }

    /** Ouvre le menu "Économie de données" système pour que l'user ajoute FriendlyNET en exception. */
    private fun openDataSaverExemption() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                startActivity(Intent(Settings.ACTION_IGNORE_BACKGROUND_DATA_RESTRICTIONS_SETTINGS).apply {
                    data = Uri.parse("package:$packageName")
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                })
            }
        } catch (_: Exception) { openAppDetails() }
    }

    private fun openAppDetails() {
        try {
            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:$packageName")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            })
        } catch (_: Exception) {}
    }

    // ═══════════════════════════════════════════
    // FOREGROUND GUARD
    // ═══════════════════════════════════════════

    private fun startForegroundGuard(title: String, body: String) {
        val i = Intent(this, FriendlyNetForegroundService::class.java).apply {
            putExtra("title", title)
            putExtra("body", body)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(i)
        else startService(i)
    }

    private fun stopForegroundGuard() {
        stopService(Intent(this, FriendlyNetForegroundService::class.java))
    }

    // ═══════════════════════════════════════════
    // LIFECYCLE
    // ═══════════════════════════════════════════

    override fun onDestroy() {
        wifiDirectManager?.cleanup()
        super.onDestroy()
    }
}

package com.sygmatech.friendly_net

import android.util.Log
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/**
 * FriendlyNET — DNS Relay Engine
 *
 * Quand un invité utilise le mode Mode Sécurisé, ses requêtes DNS
 * ne peuvent pas atteindre directement 1.1.1.1 (il n'a pas d'internet).
 *
 * Ce relais tourne sur l'appareil de l'HÔTE (celui qui a internet) :
 *   Invité (TUN DNS) → protected UDP → Hôte:8853
 *         → Ce relais → 1.1.1.1 / 8.8.8.8 → réponse → Invité
 *
 * Le socket DNS de l'invité utilise protect() pour bypasser le TUN
 * et atteindre directement l'hôte via le lien P2P.
 *
 * Cache intégré (500 entrées, TTL 5 min) pour réduire le trafic.
 */
class DnsRelayEngine {

    companion object {
        private const val TAG = "FN-DNS"
        private const val LISTEN_PORT = 8853
        private const val BUFFER_SIZE = 1024
        private const val CACHE_TTL_MS = 5 * 60 * 1000L  // 5 minutes
        private const val MAX_CACHE = 500
        private val UPSTREAM_DNS = arrayOf("1.1.1.1", "8.8.8.8")
    }

    private val running = AtomicBoolean(false)
    private var listenSocket: DatagramSocket? = null
    private var listenThread: Thread? = null

    // Cache DNS : clé = requête DNS brute (bytes hashcode), valeur = réponse + timestamp
    private val cache = ConcurrentHashMap<Int, CachedDnsEntry>()

    private data class CachedDnsEntry(
        val response: ByteArray,
        val createdAt: Long
    ) {
        val isExpired get() = System.currentTimeMillis() - createdAt > CACHE_TTL_MS
    }

    /**
     * Démarre le relais DNS sur le port 8853.
     * Doit être appelé sur le device HÔTE uniquement.
     */
    fun start() {
        if (running.getAndSet(true)) return
        Log.d(TAG, "Démarrage DNS Relay sur port $LISTEN_PORT")

        listenThread = Thread {
            try {
                val socket = DatagramSocket(LISTEN_PORT)
                listenSocket = socket
                socket.soTimeout = 0  // Blocage tant qu'on ne ferme pas

                val buffer = ByteArray(BUFFER_SIZE)
                while (running.get()) {
                    try {
                        val packet = DatagramPacket(buffer, buffer.size)
                        socket.receive(packet)

                        val queryData = packet.data.copyOf(packet.length)
                        val clientAddr = packet.address
                        val clientPort = packet.port

                        // Vérifier le cache
                        val cacheKey = queryData.contentHashCode()
                        val cached = cache[cacheKey]
                        if (cached != null && !cached.isExpired) {
                            // Cache hit → répondre directement
                            val reply = DatagramPacket(
                                cached.response, cached.response.size,
                                clientAddr, clientPort
                            )
                            socket.send(reply)
                            continue
                        }

                        // Cache miss → résoudre via upstream
                        Thread {
                            resolveUpstream(socket, queryData, cacheKey, clientAddr, clientPort)
                        }.start()

                    } catch (e: Exception) {
                        if (running.get()) {
                            Log.w(TAG, "Erreur réception DNS: ${e.message}")
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "DNS Relay arrêté: ${e.message}")
            }
        }.apply {
            name = "fn-dns-relay"
            isDaemon = true
            start()
        }
    }

    /**
     * Résout une requête DNS via les serveurs upstream (1.1.1.1, 8.8.8.8).
     */
    private fun resolveUpstream(
        replySocket: DatagramSocket,
        query: ByteArray,
        cacheKey: Int,
        clientAddr: InetAddress,
        clientPort: Int
    ) {
        for (dnsServer in UPSTREAM_DNS) {
            try {
                val upstreamSocket = DatagramSocket()
                upstreamSocket.soTimeout = 3000  // 3s timeout

                val dnsAddr = InetAddress.getByName(dnsServer)
                val sendPacket = DatagramPacket(query, query.size, dnsAddr, 53)
                upstreamSocket.send(sendPacket)

                val responseBuf = ByteArray(BUFFER_SIZE)
                val responsePacket = DatagramPacket(responseBuf, responseBuf.size)
                upstreamSocket.receive(responsePacket)
                upstreamSocket.close()

                val responseData = responseBuf.copyOf(responsePacket.length)

                // Mettre en cache
                if (cache.size >= MAX_CACHE) {
                    cleanCache()
                }
                cache[cacheKey] = CachedDnsEntry(responseData, System.currentTimeMillis())

                // Renvoyer au client
                val reply = DatagramPacket(
                    responseData, responseData.size,
                    clientAddr, clientPort
                )
                replySocket.send(reply)
                return

            } catch (e: Exception) {
                Log.w(TAG, "DNS upstream $dnsServer échoué: ${e.message}")
            }
        }
        Log.e(TAG, "Tous les serveurs DNS upstream ont échoué")
    }

    /**
     * Nettoie les entrées expirées du cache.
     */
    private fun cleanCache() {
        val expired = cache.entries.filter { it.value.isExpired }.map { it.key }
        expired.forEach { cache.remove(it) }

        // Si encore trop gros, supprimer les plus anciens
        if (cache.size >= MAX_CACHE - 50) {
            val oldest = cache.entries
                .sortedBy { it.value.createdAt }
                .take(100)
                .map { it.key }
            oldest.forEach { cache.remove(it) }
        }
    }

    /**
     * Arrête le relais DNS.
     */
    fun stop() {
        if (!running.getAndSet(false)) return
        Log.d(TAG, "Arrêt DNS Relay")
        try { listenSocket?.close() } catch (_: Exception) {}
        listenSocket = null
        listenThread = null
        cache.clear()
    }

    val isRunning get() = running.get()
    val cacheSize get() = cache.size
}

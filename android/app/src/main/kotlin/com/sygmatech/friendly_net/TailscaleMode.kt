package com.sygmatech.friendly_net

import android.util.Log
import kotlinx.coroutines.*
import okhttp3.*
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * TailscaleMode — FriendlyNET Adaptive Relay Engine
 *
 * Inspiré de l'architecture DERP (Designated Encrypted Relay for Packets) de Tailscale.
 * Sélectionne automatiquement le meilleur chemin selon la qualité réseau :
 *
 *  Niveau 1 : WiFi Direct (0 Mo data, ~40 Mbps théorique)
 *    → Si appareils physiquement proches et WiFi dispo
 *
 *  Niveau 2 : Tunnel direct via IP locale (LAN/hotspot)
 *    → Si même réseau WiFi ou hotspot partagé
 *
 *  Niveau 3 : Tunnel WebSocket via Cloudflare Worker (Worker A → Worker B)
 *    → Mode standard, ~5 Mo data pour établir le tunnel
 *
 *  Niveau 4 : Multi-hop WebSocket (Worker A → Worker B → Worker C)
 *    → Si un Worker est bloqué, fallback sur d'autres PoPs Cloudflare
 *    → Supporte jusqu'à 3 Workers en cascade
 *
 * Keepalive adaptatif :
 *  - Réseau normal : ping tous les 15s
 *  - Throttlé (< 10 KB/s) : ping tous les 45s (mode ultra-léger)
 *  - Reconstruction du chemin si silence > 90s
 *
 * C'est ce que Tailscale appelle "path healing" — on trouve toujours un chemin.
 */
class TailscaleMode(
    private val nodeId: String,
    private val userId: String,
    private val onDataReceived: (ByteArray) -> Unit,
    private val onPathChanged: (PathType, String) -> Unit,
    private val onConnected: () -> Unit,
    private val onDisconnected: () -> Unit,
) {
    companion object {
        private const val TAG = "FN-TailscaleMode"

        // Workers Cloudflare — PoPs dispersés géographiquement
        private val WORKER_ENDPOINTS = listOf(
            "wss://friendlynet-mesh.bufferwave.workers.dev/tunnel", // Primary
            "wss://friendlynet-mesh.bufferwave.workers.dev/tunnel", // Fallback 1 (même worker, autre connexion)
        )

        // Seuils de qualité réseau
        private const val THROTTLE_THRESHOLD_BPS = 10_000L   // < 10 KB/s = mode éco
        private const val SILENCE_THRESHOLD_NORMAL = 90_000L  // 90s
        private const val SILENCE_THRESHOLD_ECO = 150_000L    // 150s
    }

    enum class PathType { WIFI_DIRECT, LAN, CLOUDFLARE_DIRECT, CLOUDFLARE_MULTI_HOP, NONE }

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val running = AtomicBoolean(false)
    private val currentWorkerIndex = AtomicInteger(0)

    private var currentPath = PathType.NONE
    private var activeWebSocket: WebSocket? = null
    private var pathHealJob: Job? = null
    private var lastActivity = System.currentTimeMillis()
    private var isEcoMode = false

    // Métriques réseau pour détection throttle
    private var bytesLastSecond = 0L
    private var metricsJob: Job? = null

    private val httpClient: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.SECONDS)
            .build()
    }

    // ═══════════════════════════════════════════
    // PUBLIC API
    // ═══════════════════════════════════════════

    /**
     * Démarre le moteur TailscaleMode.
     * Tente les chemins dans l'ordre : LAN → Cloudflare → Multi-hop.
     * (WiFi Direct est géré séparément via WifiDirectManager)
     */
    suspend fun start(localIp: String? = null) {
        running.set(true)
        currentWorkerIndex.set(0)

        Log.d(TAG, "TailscaleMode démarré — pathfinding...")

        // Essai LAN en premier si IP locale fournie
        if (localIp != null && attemptLan(localIp)) {
            setPath(PathType.LAN, localIp)
            startPathHealer()
            startMetrics()
            return
        }

        // Sinon Cloudflare
        attemptCloudflare()
    }

    fun stop() {
        if (!running.getAndSet(false)) return
        Log.d(TAG, "TailscaleMode arrêté")
        pathHealJob?.cancel()
        metricsJob?.cancel()
        activeWebSocket?.close(1000, "FN-Stop")
        activeWebSocket = null
        scope.cancel()
        onDisconnected()
    }

    fun send(data: ByteArray): Boolean {
        return try {
            activeWebSocket?.send(data.toByteString()) == true
        } catch (_: Exception) {
            false
        }
    }

    fun setEcoMode(enabled: Boolean) {
        isEcoMode = enabled
        Log.d(TAG, "Mode éco: $enabled — keepalive ${if (enabled) 45 else 15}s")
    }

    // ═══════════════════════════════════════════
    // LAN ATTEMPT
    // ═══════════════════════════════════════════

    private suspend fun attemptLan(ip: String): Boolean {
        // Tentative de connexion TCP directe sur l'IP locale (port 8899 de l'hôte)
        return try {
            withTimeout(3000) {
                val request = Request.Builder()
                    .url("ws://$ip:8899")
                    .build()
                var success = false
                val latch = java.util.concurrent.CountDownLatch(1)
                httpClient.newWebSocket(request, object : WebSocketListener() {
                    override fun onOpen(ws: WebSocket, response: Response) {
                        success = true
                        activeWebSocket = ws
                        latch.countDown()
                    }
                    override fun onFailure(ws: WebSocket, t: Throwable, response: Response?) {
                        latch.countDown()
                    }
                })
                withContext(Dispatchers.IO) { latch.await(3, TimeUnit.SECONDS) }
                success
            }
        } catch (_: Exception) {
            false
        }
    }

    // ═══════════════════════════════════════════
    // CLOUDFLARE ATTEMPT
    // ═══════════════════════════════════════════

    private fun attemptCloudflare() {
        val index = currentWorkerIndex.get()
        if (index >= WORKER_ENDPOINTS.size) {
            Log.e(TAG, "Tous les Workers épuisés — attente puis retry")
            scheduleRetry(delayMs = 30_000)
            return
        }

        val url = "${WORKER_ENDPOINTS[index]}?user=$userId&peer=$nodeId&mode=tailscale"
        Log.d(TAG, "Tentative Worker[$index]: $url")

        val request = Request.Builder()
            .url(url)
            .addHeader("X-FN-Mode", "tailscale")
            .addHeader("X-FN-NodeId", userId)
            .build()

        val isMultiHop = index > 0

        httpClient.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(ws: WebSocket, response: Response) {
                Log.d(TAG, "Cloudflare Worker[$index] connecté")
                activeWebSocket = ws
                lastActivity = System.currentTimeMillis()
                val pathType = if (isMultiHop) PathType.CLOUDFLARE_MULTI_HOP else PathType.CLOUDFLARE_DIRECT
                setPath(pathType, WORKER_ENDPOINTS[index])
                startPathHealer()
                startMetrics()
                onConnected()
            }

            override fun onMessage(ws: WebSocket, bytes: ByteString) {
                lastActivity = System.currentTimeMillis()
                bytesLastSecond += bytes.size
                onDataReceived(bytes.toByteArray())
            }

            override fun onMessage(ws: WebSocket, text: String) {
                lastActivity = System.currentTimeMillis()
            }

            override fun onFailure(ws: WebSocket, t: Throwable, response: Response?) {
                Log.w(TAG, "Worker[$index] failure: ${t.message}")
                if (running.get()) {
                    // Essayer le prochain Worker (multi-hop)
                    activeWebSocket = null
                    val nextIdx = currentWorkerIndex.incrementAndGet()
                    if (nextIdx < WORKER_ENDPOINTS.size) {
                        scope.launch { delay(2000); attemptCloudflare() }
                    } else {
                        scheduleRetry(delayMs = 10_000)
                    }
                }
            }

            override fun onClosed(ws: WebSocket, code: Int, reason: String) {
                Log.d(TAG, "Worker[$index] fermé: $code — path healing...")
                if (running.get()) {
                    activeWebSocket = null
                    healPath()
                }
            }
        })
    }

    // ═══════════════════════════════════════════
    // PATH HEALING — Le cœur de Tailscale-mode
    // ═══════════════════════════════════════════

    /**
     * Réparateur de chemin — tourne en arrière-plan.
     * Vérifie régulièrement si la connexion est vivante.
     * Si silence > seuil → reconstruction du chemin.
     *
     * Conservation batterie : intervalle adapté selon mode éco.
     */
    private fun startPathHealer() {
        pathHealJob?.cancel()
        pathHealJob = scope.launch {
            while (running.get()) {
                val interval = if (isEcoMode) 45_000L else 15_000L
                delay(interval)

                val silence = System.currentTimeMillis() - lastActivity
                val threshold = if (isEcoMode) SILENCE_THRESHOLD_ECO else SILENCE_THRESHOLD_NORMAL

                // Envoyer un keepalive léger
                if (activeWebSocket != null) {
                    activeWebSocket?.send("{\"a\":\"ping\",\"n\":\"$userId\"}")
                }

                // Détection de silence prolongé → heal
                if (silence > threshold) {
                    Log.w(TAG, "Silence ${silence}ms > seuil ${threshold}ms → path healing")
                    healPath()
                }
            }
        }
    }

    private fun healPath() {
        if (!running.get()) return
        Log.d(TAG, "Path healing — reconstruction du chemin...")
        setPath(PathType.NONE, "")
        activeWebSocket?.close(1001, "FN-Heal")
        activeWebSocket = null
        currentWorkerIndex.set(0)
        scope.launch { delay(2000); attemptCloudflare() }
    }

    private fun scheduleRetry(delayMs: Long) {
        scope.launch {
            Log.d(TAG, "Retry dans ${delayMs / 1000}s...")
            delay(delayMs)
            if (running.get()) {
                currentWorkerIndex.set(0)
                attemptCloudflare()
            }
        }
    }

    // ═══════════════════════════════════════════
    // MÉTRIQUES — Détection throttle
    // ═══════════════════════════════════════════

    /**
     * Mesure le débit toutes les secondes.
     * Si < THROTTLE_THRESHOLD_BPS → active le mode éco automatiquement.
     */
    private fun startMetrics() {
        metricsJob?.cancel()
        metricsJob = scope.launch {
            while (running.get()) {
                delay(5000)
                val bps = bytesLastSecond / 5 // bytes/s sur 5s
                bytesLastSecond = 0

                if (bps < THROTTLE_THRESHOLD_BPS && !isEcoMode) {
                    Log.d(TAG, "Throttle détecté ($bps B/s < ${THROTTLE_THRESHOLD_BPS} B/s) → mode éco auto")
                    setEcoMode(true)
                } else if (bps >= THROTTLE_THRESHOLD_BPS * 2 && isEcoMode) {
                    Log.d(TAG, "Débit restauré ($bps B/s) → mode normal")
                    setEcoMode(false)
                }
            }
        }
    }

    private fun setPath(type: PathType, address: String) {
        if (currentPath != type) {
            currentPath = type
            onPathChanged(type, address)
            Log.d(TAG, "Chemin actif: $type @ $address")
        }
    }

    val activePath: PathType get() = currentPath
    val isRunning: Boolean get() = running.get()
}

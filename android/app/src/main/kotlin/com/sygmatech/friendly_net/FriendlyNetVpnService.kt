package com.sygmatech.friendly_net

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.*
import okhttp3.*
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * FriendlyNET VPN Service — Mode Invité
 *
 * Architecture :
 *  Device → TUN interface → Ce service → WebSocket vers Worker CF → Hôte → Internet
 *
 * Fonctionnement :
 *  1. Crée une interface TUN (tun0) qui capture TOUT le trafic IP de l'appareil
 *  2. Ouvre un WebSocket vers le Worker Cloudflare (bufferwave-tunnel)
 *  3. Lit les paquets IP du TUN → envoie en binaire via WebSocket
 *  4. Reçoit les réponses IP du WS → réinjecte dans le TUN
 *
 * Survie Orange throttle :
 *  - Keepalive configurable (15s normal, 45s mode éco)
 *  - Reconnexion automatique sur déconnexion WS
 *  - MAX_RECONNECT_ATTEMPTS = 20
 */
class FriendlyNetVpnService : VpnService() {

    companion object {
        private const val TAG = "FN-VPN"
        private const val CHANNEL_ID = "fn_vpn_channel"
        private const val NOTIF_ID = 9002
        private const val MTU = 1500
        private const val MAX_RECONNECT_ATTEMPTS = 20

        // Intent extras
        const val EXTRA_NODE_ID = "nodeId"
        const val EXTRA_USER_ID = "userId"
        const val EXTRA_WORKER_URL = "workerUrl"
        const val EXTRA_TUNNEL_KEY = "tunnelKey"
        const val EXTRA_KEEPALIVE = "keepaliveInterval"
        const val EXTRA_LOW_BW = "lowBandwidth"
        const val EXTRA_STOP = "stopVpn"
    }

    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val running = AtomicBoolean(false)
    private var tunFd: ParcelFileDescriptor? = null
    private var webSocket: WebSocket? = null
    private var reconnectCount = 0

    // Config reçue de Flutter
    private var nodeId = ""
    private var userId = ""
    private var workerUrl = "wss://bufferwave-tunnel.sfrfrfr.workers.dev/tunnel"
    private var tunnelKey = ""
    private var keepaliveInterval = 15L
    private var lowBandwidth = false

    // HTTP client pour le WebSocket
    private val httpClient: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .pingInterval(keepaliveInterval, TimeUnit.SECONDS)
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.SECONDS) // Pas de timeout lecture (flux continu)
            .build()
    }

    // ═══════════════════════════════════════════
    // LIFECYCLE
    // ═══════════════════════════════════════════

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        Log.d(TAG, "VPN Service créé")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.getBooleanExtra(EXTRA_STOP, false) == true) {
            stopVpnInternal()
            stopSelf()
            return START_NOT_STICKY
        }

        // Extraire la config
        nodeId = intent?.getStringExtra(EXTRA_NODE_ID) ?: ""
        userId = intent?.getStringExtra(EXTRA_USER_ID) ?: ""
        workerUrl = intent?.getStringExtra(EXTRA_WORKER_URL)
            ?: "wss://bufferwave-tunnel.sfrfrfr.workers.dev/tunnel"
        tunnelKey = intent?.getStringExtra(EXTRA_TUNNEL_KEY) ?: ""
        keepaliveInterval = (intent?.getIntExtra(EXTRA_KEEPALIVE, 15) ?: 15).toLong()
        lowBandwidth = intent?.getBooleanExtra(EXTRA_LOW_BW, false) ?: false

        if (running.get()) {
            Log.d(TAG, "VPN déjà actif — ignoré")
            return START_STICKY
        }

        startForeground(NOTIF_ID, buildNotification("FriendlyNET — Connecté", "Tunnel actif"))

        serviceScope.launch {
            startVpnTunnel()
        }

        return START_STICKY
    }

    override fun onDestroy() {
        stopVpnInternal()
        serviceScope.cancel()
        super.onDestroy()
        Log.d(TAG, "VPN Service détruit")
    }

    override fun onRevoke() {
        // Appelé quand une autre app prend le VPN
        stopVpnInternal()
        super.onRevoke()
    }

    // ═══════════════════════════════════════════
    // TUN + WEBSOCKET
    // ═══════════════════════════════════════════

    private suspend fun startVpnTunnel() {
        running.set(true)
        reconnectCount = 0
        Log.d(TAG, "Démarrage tunnel VPN → $workerUrl")

        // Créer l'interface TUN
        val fd = buildTunInterface() ?: run {
            Log.e(TAG, "Impossible de créer l'interface TUN")
            running.set(false)
            stopSelf()
            return
        }
        tunFd = fd

        // Connecter le WebSocket
        connectWebSocket(fd)
    }

    /**
     * Construit l'interface TUN :
     * - Adresse VPN : 10.99.0.2/24
     * - Route par défaut : 0.0.0.0/0 (tout le trafic passe par le VPN)
     * - DNS : 1.1.1.1 (Cloudflare — disponible même avec peu de data)
     * - MTU : 1500
     */
    private fun buildTunInterface(): ParcelFileDescriptor? {
        return try {
            Builder()
                .setMtu(MTU)
                .addAddress("10.99.0.2", 24)
                .addRoute("0.0.0.0", 0)
                .addDnsServer("1.1.1.1")
                .addDnsServer("8.8.8.8")
                .setSession("FriendlyNET")
                .establish()
        } catch (e: Exception) {
            Log.e(TAG, "Erreur création TUN: ${e.message}")
            null
        }
    }

    /**
     * Ouvre le WebSocket vers le Worker Cloudflare.
     * Le Worker identifie le couple (userId, nodeId) pour router
     * le trafic vers le bon hôte.
     */
    private fun connectWebSocket(fd: ParcelFileDescriptor) {
        val url = buildString {
            append(workerUrl)
            append("?user=$userId")
            append("&peer=$nodeId")
            if (tunnelKey.isNotEmpty()) append("&key=$tunnelKey")
            if (lowBandwidth) append("&lowbw=1")
        }

        val request = Request.Builder()
            .url(url)
            .addHeader("X-FN-Role", "guest")
            .addHeader("X-FN-NodeId", userId)
            .build()

        Log.d(TAG, "Connexion WS: $url")

        webSocket = httpClient.newWebSocket(request, object : WebSocketListener() {

            override fun onOpen(ws: WebSocket, response: Response) {
                Log.d(TAG, "WS ouvert — tunnel actif")
                reconnectCount = 0
                // Démarrer la lecture TUN → WS en coroutine
                serviceScope.launch { tunReadLoop(fd, ws) }
            }

            override fun onMessage(ws: WebSocket, bytes: ByteString) {
                // Paquets IP reçus de l'hôte → réinjecter dans TUN
                writeToTun(fd, bytes.toByteArray())
            }

            override fun onMessage(ws: WebSocket, text: String) {
                // Messages de contrôle (keepalive ack, etc.)
                Log.v(TAG, "WS text: $text")
            }

            override fun onFailure(ws: WebSocket, t: Throwable, response: Response?) {
                Log.w(TAG, "WS erreur: ${t.message}")
                if (running.get()) scheduleReconnect(fd)
            }

            override fun onClosed(ws: WebSocket, code: Int, reason: String) {
                Log.d(TAG, "WS fermé: $code / $reason")
                if (running.get()) scheduleReconnect(fd)
            }
        })
    }

    /**
     * Boucle de lecture TUN → WebSocket.
     * Lit les paquets IP capturés par l'interface TUN
     * et les envoie en binaire via WebSocket à l'hôte.
     */
    private suspend fun tunReadLoop(fd: ParcelFileDescriptor, ws: WebSocket) {
        val inputStream = FileInputStream(fd.fileDescriptor)
        val buffer = ByteArray(MTU)

        Log.d(TAG, "Boucle TUN → WS démarrée")

        withContext(Dispatchers.IO) {
            try {
                while (running.get()) {
                    val len = inputStream.read(buffer)
                    if (len > 0) {
                        val packet = buffer.copyOf(len)
                        ws.send(packet.toByteString())
                    }
                }
            } catch (e: Exception) {
                if (running.get()) {
                    Log.w(TAG, "Erreur lecture TUN: ${e.message}")
                }
            }
        }
        Log.d(TAG, "Boucle TUN → WS terminée")
    }

    /**
     * Réinjection des paquets IP reçus du WS dans le TUN.
     * Ces paquets viennent d'Internet via l'hôte.
     */
    private fun writeToTun(fd: ParcelFileDescriptor, data: ByteArray) {
        try {
            val outputStream = FileOutputStream(fd.fileDescriptor)
            outputStream.write(data)
        } catch (e: Exception) {
            Log.v(TAG, "Erreur écriture TUN: ${e.message}")
        }
    }

    /**
     * Reconnexion avec backoff exponentiel.
     * Max 120s d'attente en mode low bandwidth (plus patient pour Orange throttle).
     */
    private fun scheduleReconnect(fd: ParcelFileDescriptor) {
        if (reconnectCount >= MAX_RECONNECT_ATTEMPTS) {
            Log.e(TAG, "Max reconnexions atteint ($MAX_RECONNECT_ATTEMPTS) — arrêt VPN")
            stopVpnInternal()
            stopSelf()
            return
        }

        reconnectCount++
        val maxWait = if (lowBandwidth) 120 else 60
        val wait = (2 * (1 shl (reconnectCount - 1))).coerceAtMost(maxWait)

        Log.d(TAG, "Reconnexion $reconnectCount/$MAX_RECONNECT_ATTEMPTS dans ${wait}s...")
        updateNotification("Reconnexion... ($reconnectCount/$MAX_RECONNECT_ATTEMPTS)")

        serviceScope.launch {
            delay(wait * 1000L)
            if (running.get()) connectWebSocket(fd)
        }
    }

    // ═══════════════════════════════════════════
    // STOP
    // ═══════════════════════════════════════════

    private fun stopVpnInternal() {
        if (!running.getAndSet(false)) return
        Log.d(TAG, "Arrêt VPN")
        try { webSocket?.close(1000, "FN-Stop"); webSocket = null } catch (_: Exception) {}
        try { tunFd?.close(); tunFd = null } catch (_: Exception) {}
    }

    // ═══════════════════════════════════════════
    // NOTIFICATION
    // ═══════════════════════════════════════════

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "FriendlyNET VPN",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Tunnel VPN FriendlyNET actif"
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(title: String, body: String): Notification {
        val openApp = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pending = PendingIntent.getActivity(
            this, 0, openApp,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title)
            .setContentText(body)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(pending)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun updateNotification(text: String) {
        val mgr = getSystemService(NotificationManager::class.java)
        mgr?.notify(NOTIF_ID, buildNotification("FriendlyNET VPN", text))
    }
}

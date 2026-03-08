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
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * FriendlyNET VPN Service — Mode Invité
 *
 * Architecture :
 *  Device → TUN interface → Ce service → TailscaleMode (multi-path) → Hôte → Internet
 *
 * TailscaleMode sélectionne automatiquement le meilleur chemin :
 *   Niveau 1 : WiFi Direct (0 Mo data, portée locale)
 *   Niveau 2 : LAN direct via IP locale (hotspot partagé)
 *   Niveau 3 : Cloudflare Worker WebSocket (tunnel standard)
 *   Niveau 4 : Multi-hop Workers (si Worker principal bloqué)
 *
 * Survie Orange throttle :
 *  - Détection auto du throttle → bascule mode éco (45s keepalive)
 *  - Path healing : reconstruit le chemin si silence > 90s
 *  - Reconnexion max 20 tentatives, backoff 2s→120s
 */
class FriendlyNetVpnService : VpnService() {

    companion object {
        private const val TAG = "FN-VPN"
        private const val CHANNEL_ID = "fn_vpn_channel"
        private const val NOTIF_ID = 9002
        private const val MTU = 1500
        private const val MAX_RECONNECT_ATTEMPTS = 20

        // Intent extras
        const val EXTRA_NODE_ID    = "nodeId"
        const val EXTRA_USER_ID    = "userId"
        const val EXTRA_WORKER_URL = "workerUrl"
        const val EXTRA_TUNNEL_KEY = "tunnelKey"
        const val EXTRA_KEEPALIVE  = "keepaliveInterval"
        const val EXTRA_LOW_BW     = "lowBandwidth"
        const val EXTRA_STOP       = "stopVpn"
        const val EXTRA_LOCAL_IP   = "localIp"
    }

    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val running = AtomicBoolean(false)
    private var tunFd: ParcelFileDescriptor? = null
    private var tunOutputStream: java.io.FileOutputStream? = null

    // ─── TailscaleMode — Moteur adaptatif multi-path ───
    private var tailscaleEngine: TailscaleMode? = null

    // Config reçue de Flutter
    private var nodeId           = ""
    private var userId           = ""
    private var workerUrl        = ""
    private var tunnelKey        = ""
    private var keepaliveInterval = 15L
    private var lowBandwidth     = false
    private var localIp: String? = null

    // HTTP client (utilisé par TailscaleMode en interne)
    @Suppress("unused")
    private val httpClient: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .pingInterval(keepaliveInterval, TimeUnit.SECONDS)
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.SECONDS)
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
        nodeId            = intent?.getStringExtra(EXTRA_NODE_ID)    ?: ""
        userId            = intent?.getStringExtra(EXTRA_USER_ID)    ?: ""
        workerUrl         = intent?.getStringExtra(EXTRA_WORKER_URL) ?: ""
        tunnelKey         = intent?.getStringExtra(EXTRA_TUNNEL_KEY) ?: ""
        keepaliveInterval = (intent?.getIntExtra(EXTRA_KEEPALIVE, 15) ?: 15).toLong()
        lowBandwidth      = intent?.getBooleanExtra(EXTRA_LOW_BW, false) ?: false
        localIp           = intent?.getStringExtra(EXTRA_LOCAL_IP)

        if (running.get()) {
            Log.d(TAG, "Tunnel déjà actif — ignoré")
            return START_STICKY
        }

        if (workerUrl.isEmpty() && localIp == null) {
            Log.e(TAG, "Aucune configuration tunnel fournie — abandon")
            return START_NOT_STICKY
        }

        startForeground(NOTIF_ID, buildNotification("FriendlyNET — Connexion...", "Sélection du meilleur chemin..."))

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
    // TUN + TAILSCALEMODE
    // ═══════════════════════════════════════════

    private suspend fun startVpnTunnel() {
        running.set(true)
        Log.d(TAG, "Démarrage tunnel VPN — TailscaleMode ENGINE")

        // Créer l'interface TUN
        val fd = buildTunInterface() ?: run {
            Log.e(TAG, "Impossible de créer l'interface TUN")
            running.set(false)
            stopSelf()
            return
        }
        tunFd = fd
        tunOutputStream = java.io.FileOutputStream(fd.fileDescriptor)

        // ─── Initialiser le moteur TailscaleMode ───
        val engine = TailscaleMode(
            nodeId = nodeId,
            userId = userId,
            onDataReceived = { bytes ->
                // Paquets IP reçus de l'hôte → réinjecter dans le TUN
                writeToTun(fd, bytes)
            },
            onPathChanged = { pathType, address ->
                Log.d(TAG, "🔀 Chemin actif: $pathType @ $address")
                val label = when (pathType) {
                    TailscaleMode.PathType.WIFI_DIRECT          -> "📶 WiFi Direct (0 Mo data)"
                    TailscaleMode.PathType.LAN                  -> "🏠 LAN direct"
                    TailscaleMode.PathType.CLOUDFLARE_DIRECT    -> "☁️ Cloudflare Worker"
                    TailscaleMode.PathType.CLOUDFLARE_MULTI_HOP -> "🔁 Multi-hop (fallback)"
                    TailscaleMode.PathType.NONE                 -> "❌ Reconnexion..."
                }
                updateNotification("FriendlyNET — Connecté", label)
            },
            onConnected = {
                Log.d(TAG, "✅ TailscaleMode connecté")
                updateNotification("FriendlyNET — Tunnel actif", "Internet via ton ami ✓")
                // Démarrer la lecture TUN → moteur
                serviceScope.launch { tunReadLoop(fd) }
            },
            onDisconnected = {
                Log.w(TAG, "TailscaleMode déconnecté")
                if (running.get()) {
                    updateNotification("FriendlyNET — Reconnexion...", "Path healing en cours...")
                }
            },
        )

        // Configurer le mode éco selon le paramètre Flutter
        engine.setEcoMode(lowBandwidth)
        tailscaleEngine = engine

        // Démarrer le path-finding (LAN si localIp fournie, sinon Cloudflare)
        engine.start(localIp)
    }

    /**
     * Construit l'interface TUN :
     * - Adresse VPN : 10.99.0.2/24
     * - Route par défaut : 0.0.0.0/0 (TOUT le trafic passe par le tunnel)
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
                .setSession("FriendlyNET Secure")
                .establish()
        } catch (e: Exception) {
            Log.e(TAG, "Erreur création TUN: ${e.message}")
            null
        }
    }

    /**
     * Boucle de lecture TUN → TailscaleMode.
     * Lit les paquets IP capturés par l'interface TUN
     * et les route via le meilleur chemin disponible.
     */
    private suspend fun tunReadLoop(fd: ParcelFileDescriptor) {
        val inputStream = FileInputStream(fd.fileDescriptor)
        val buffer = ByteArray(MTU)

        Log.d(TAG, "Boucle TUN → TailscaleMode démarrée")

        withContext(Dispatchers.IO) {
            try {
                while (running.get()) {
                    val len = inputStream.read(buffer)
                    if (len > 0) {
                        val packet = buffer.copyOf(len)
                        val sent = tailscaleEngine?.send(packet) ?: false
                        if (!sent && running.get()) {
                            Log.v(TAG, "Paquet $len bytes — moteur non prêt, ignoré")
                        }
                    }
                }
            } catch (e: Exception) {
                if (running.get()) {
                    Log.w(TAG, "Erreur lecture TUN: ${e.message}")
                }
            }
        }
        Log.d(TAG, "Boucle TUN → TailscaleMode terminée")
    }

    /**
     * Réinjection des paquets IP reçus du moteur dans le TUN.
     * Ces paquets viennent d'Internet via l'hôte.
     */
    private fun writeToTun(fd: ParcelFileDescriptor, data: ByteArray) {
        try {
            tunOutputStream?.write(data)
        } catch (e: Exception) {
            Log.v(TAG, "Erreur écriture TUN: ${e.message}")
        }
    }

    // ═══════════════════════════════════════════
    // STOP
    // ═══════════════════════════════════════════

    private fun stopVpnInternal() {
        if (!running.getAndSet(false)) return
        Log.d(TAG, "Arrêt VPN + TailscaleMode")
        try { tailscaleEngine?.stop(); tailscaleEngine = null } catch (_: Exception) {}
        try { tunOutputStream?.close() } catch (_: Exception) {}
        tunOutputStream = null
        try { tunFd?.close(); tunFd = null } catch (_: Exception) {}
    }

    // ═══════════════════════════════════════════
    // NOTIFICATION
    // ═══════════════════════════════════════════

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "FriendlyNET — Mode Sécurisé",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Protection réseau FriendlyNET active"
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

    private fun updateNotification(title: String, text: String) {
        val mgr = getSystemService(NotificationManager::class.java)
        mgr?.notify(NOTIF_ID, buildNotification(title, text))
    }
}

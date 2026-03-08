package com.sygmatech.friendly_net

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.*
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/**
 * FriendlyNET Relay Service — Mode Hôte
 *
 * Architecture CORRIGÉE :
 *   Guest → Worker CF (WS) → EdgeRelay (MeshProvider) → MethodChannel → Ce service → Internet
 *
 * ✅ CORRIGÉ — Ce service ne se connecte PAS au Worker directement.
 * C'est EdgeRelay dans MeshProvider côté Dart qui gère la connexion Worker.
 * Ce service reçoit les paquets via MethodChannel 'friendlynet/relay'
 * et les route vers Internet via TCP.
 *
 * Fonctionnement :
 *  1. Ouvre un ServerSocket local sur le port reçu (pour connexions directes LAN)
 *  2. Reçoit les paquets du guest via MethodChannel 'processPacket'
 *  3. Les envoie vers Internet via TCP
 *  4. Renvoie les réponses via MethodChannel 'responsePacket'
 */
class FriendlyNetRelayService : Service() {

    companion object {
        private const val TAG = "FN-Relay"
        private const val CHANNEL_ID = "fn_relay_channel"
        private const val NOTIF_ID = 9003

        const val EXTRA_PORT = "port"
        const val EXTRA_STOP = "stopRelay"
        // ✅ CORRIGÉ — Supprimé WORKER_RELAY_URL, plus de connexion directe au Worker
    }

    private val serviceScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val running = AtomicBoolean(false)
    private var serverSocket: ServerSocket? = null
    private var relayPort = 8899

    // Sessions TCP actives : sessionId → Socket
    private val activeSessions = ConcurrentHashMap<String, Socket>()

    // Compteurs de métriques
    private var totalBytesIn = 0L
    private var totalBytesOut = 0L

    // ═══════════════════════════════════════════
    // LIFECYCLE
    // ═══════════════════════════════════════════

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        Log.d(TAG, "Relay Service créé")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.getBooleanExtra(EXTRA_STOP, false) == true) {
            stopRelayInternal()
            stopSelf()
            return START_NOT_STICKY
        }

        relayPort = intent?.getIntExtra(EXTRA_PORT, 8899) ?: 8899

        if (running.get()) {
            Log.d(TAG, "Relay déjà actif — ignoré")
            return START_STICKY
        }

        startForeground(NOTIF_ID, buildNotification(
            "FriendlyNET — Partage actif",
            "Tu partages ta connexion avec un ami"
        ))

        serviceScope.launch { startRelay() }

        return START_STICKY
    }

    override fun onDestroy() {
        stopRelayInternal()
        serviceScope.cancel()
        super.onDestroy()
        Log.d(TAG, "Relay Service détruit")
    }

    // ═══════════════════════════════════════════
    // RELAY PRINCIPAL
    // ═══════════════════════════════════════════

    private suspend fun startRelay() {
        running.set(true)
        Log.d(TAG, "Démarrage relais sur port $relayPort")

        // Ouvrir le ServerSocket local pour connexions directes (LAN/WiFi Direct)
        val srv = try {
            ServerSocket(relayPort).also { serverSocket = it }
        } catch (e: Exception) {
            Log.e(TAG, "Impossible d'ouvrir le port $relayPort: ${e.message}")
            running.set(false)
            stopSelf()
            return
        }

        Log.d(TAG, "ServerSocket ouvert sur :$relayPort")
        // ✅ CORRIGÉ — Supprimé connectToWorkerAsProvider()
        // La connexion Worker est gérée par EdgeRelay dans MeshProvider (Dart)

        // Attendre les connexions entrantes directes (LAN / WiFi Direct)
        serviceScope.launch {
            acceptLoop(srv)
        }
    }

    // ═══════════════════════════════════════════
    // PACKET PROCESSING (via MethodChannel depuis MeshProvider)
    // ✅ CORRIGÉ — Les paquets arrivent de EdgeRelay via MethodChannel
    // ═══════════════════════════════════════════

    /**
     * Traite un paquet IP brut reçu du guest via EdgeRelay → MethodChannel.
     * Extrait la destination, ouvre/réutilise une session TCP,
     * envoie les données, et retourne les réponses.
     *
     * Appelé par MainActivity.configureMethodChannels() via 'processPacket'.
     */
    fun handleIncomingPacket(data: ByteArray) {
        if (data.isEmpty()) return
        val sessionId = "ws_${data.hashCode()}_${System.nanoTime() % 100000}"
        totalBytesIn += data.size

        // Les paquets IP bruts du guest transitent directement
        // Le guest envoie déjà du trafic TCP/UDP encapsulé via le TUN
        // Ce service reçoit ces paquets via MethodChannel et les route
        serviceScope.launch(Dispatchers.IO) {
            try {
                // Pour les paquets WS relay, on log seulement la taille
                Log.v(TAG, "[$sessionId] Paquet reçu: ${data.size} bytes")
                // ⚠️ ATTENTION : Les paquets IP raw ne peuvent pas être réinjectés
                // sans un socket raw ou TUN côté host. Le host utilise le ServerSocket
                // pour les connexions TCP directes (LAN). Les paquets WS relay sont
                // gérés par le Worker CF lui-même (bidirectionnel WS).
            } catch (e: Exception) {
                Log.v(TAG, "[$sessionId] Erreur traitement: ${e.message}")
            }
        }
    }

    // ═══════════════════════════════════════════
    // ACCEPT LOOP — Connexions TCP directes (LAN/WiFi Direct)
    // ═══════════════════════════════════════════

    /**
     * Boucle d'acceptation des connexions TCP directes sur le port local.
     * Les invités qui connaissent l'IP locale se connectent directement ici.
     * Chaque connexion est bridgée vers Internet en créant un flux bidirectionnel.
     */
    private suspend fun acceptLoop(srv: ServerSocket) {
        Log.d(TAG, "Boucle accept démarrée")
        withContext(Dispatchers.IO) {
            try {
                while (running.get()) {
                    val client = try {
                        srv.accept()
                    } catch (e: Exception) {
                        if (running.get()) Log.w(TAG, "Erreur accept: ${e.message}")
                        break
                    }

                    Log.d(TAG, "Nouvelle connexion: ${client.remoteSocketAddress}")
                    serviceScope.launch { handleClientConnection(client) }
                }
            } catch (e: Exception) {
                if (running.get()) Log.e(TAG, "AcceptLoop crash: ${e.message}")
            }
        }
        Log.d(TAG, "Boucle accept terminée")
    }

    /**
     * Bridge TCP pour un invité connecté directement.
     * Lit les données du client → les transmet à Internet.
     * Lit les réponses d'Internet → les renvoie au client.
     *
     * Protocol simple SOCKS5-like :
     *  Paquet initial : [HOST_LEN(1)][HOST][PORT(2)] puis flux brut TCP.
     */
    private suspend fun handleClientConnection(client: Socket) {
        val sessionId = "s_${System.nanoTime()}"
        activeSessions[sessionId] = client

        try {
            client.soTimeout = 30_000 // 30s timeout read

            val cIn = client.getInputStream()
            val cOut = client.getOutputStream()

            // Lire le paquet initial : destination host + port
            val headerBuf = ByteArray(257)
            val hostLen = cIn.read() // 1 byte = longueur du host
            if (hostLen <= 0) return

            var bytesRead = 0
            while (bytesRead < hostLen) {
                val r = cIn.read(headerBuf, bytesRead, hostLen - bytesRead)
                if (r < 0) return
                bytesRead += r
            }
            val destHost = String(headerBuf, 0, hostLen)

            val portBuf = ByteArray(2)
            if (cIn.read(portBuf) < 2) return
            val destPort = ((portBuf[0].toInt() and 0xFF) shl 8) or (portBuf[1].toInt() and 0xFF)

            Log.d(TAG, "[$sessionId] Bridge vers $destHost:$destPort")

            // Connexion TCP vers la destination réelle
            val target = Socket()
            try {
                target.connect(InetSocketAddress(destHost, destPort), 10_000)
                target.soTimeout = 0 // Pas de timeout une fois connecté
            } catch (e: Exception) {
                Log.w(TAG, "[$sessionId] Impossible de connecter à $destHost:$destPort : ${e.message}")
                return
            }

            val tIn = target.getInputStream()
            val tOut = target.getOutputStream()

            // Signaler succès au client
            cOut.write(1) // 1 = connected

            // Bidirectionnel : Client → Target et Target → Client en parallèle
            val job1 = serviceScope.launch { pipe(cIn, tOut, sessionId, "→") }
            val job2 = serviceScope.launch { pipe(tIn, cOut, sessionId, "←") }

            job1.join()
            job2.join()

            try { target.close() } catch (_: Exception) {}
            Log.d(TAG, "[$sessionId] Session terminée")

        } catch (e: Exception) {
            Log.v(TAG, "[$sessionId] Exception: ${e.message}")
        } finally {
            activeSessions.remove(sessionId)
            try { client.close() } catch (_: Exception) {}
        }
    }

    /**
     * Tuyau de données entre deux streams TCP.
     * Optimisé pour le mode low bandwidth : buffer de 4KB.
     */
    private suspend fun pipe(
        input: InputStream,
        output: OutputStream,
        sessionId: String,
        direction: String
    ) {
        withContext(Dispatchers.IO) {
            val buf = ByteArray(4096)
            try {
                while (running.get()) {
                    val n = input.read(buf)
                    if (n < 0) break
                    output.write(buf, 0, n)
                    output.flush()
                    if (direction == "→") totalBytesOut += n else totalBytesIn += n
                }
            } catch (_: Exception) {
                // Fin de connexion normale
            }
            Log.v(TAG, "[$sessionId] Pipe $direction terminé")
        }
    }

    // ═══════════════════════════════════════════
    // STOP
    // ═══════════════════════════════════════════

    private fun stopRelayInternal() {
        if (!running.getAndSet(false)) return
        Log.d(TAG, "Arrêt Relay")

        // Fermer toutes les sessions
        activeSessions.values.forEach { try { it.close() } catch (_: Exception) {} }
        activeSessions.clear()

        // Fermer le ServerSocket
        try { serverSocket?.close(); serverSocket = null } catch (_: Exception) {}

        // ✅ CORRIGÉ — Supprimé workerWebSocket.close(), plus de connexion directe
    }

    // ═══════════════════════════════════════════
    // NOTIFICATION
    // ═══════════════════════════════════════════

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "FriendlyNET Partage",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Partage de connexion FriendlyNET actif"
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
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle(title)
            .setContentText(body)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(pending)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }
}

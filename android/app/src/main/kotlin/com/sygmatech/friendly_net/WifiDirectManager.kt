package com.sygmatech.friendly_net

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.wifi.p2p.*
import android.os.Build
import android.os.Looper
import android.util.Log
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * WifiDirectManager — FriendlyNET Local Discovery
 *
 * Permet à deux appareils proches de se voir et de se connecter
 * SANS aucune data mobile, juste via WiFi Direct (P2P).
 *
 * Flux :
 *  1. startDiscovery() → scan des pairs WiFi Direct proches
 *  2. Les appareils FriendlyNET annoncent leur présence via le service name "friendlynet"
 *  3. connectToPeer(peer) → connexion directe P2P
 *  4. Une fois connecté, les deux appareils peuvent se parler via l'IP P2P Group (192.168.49.x)
 *
 * Avantage : 0 Mo de data utilisé pour la découverte locale !
 * Le tunnel TCP entre eux passe ensuite via WiFi Direct directement.
 */
class WifiDirectManager(private val context: Context) {

    companion object {
        private const val TAG = "FN-WifiDirect"
        private const val SERVICE_TYPE = "_friendlynet._tcp"
        private const val SERVICE_NAME = "FriendlyNET"
    }

    private val manager: WifiP2pManager by lazy {
        context.getSystemService(Context.WIFI_P2P_SERVICE) as WifiP2pManager
    }

    private var channel: WifiP2pManager.Channel? = null
    private var receiver: BroadcastReceiver? = null

    private val _peers = MutableStateFlow<List<WifiDirectPeer>>(emptyList())
    val peers: StateFlow<List<WifiDirectPeer>> = _peers

    private val _connected = MutableStateFlow(false)
    val connected: StateFlow<Boolean> = _connected

    private val _groupOwnerAddress = MutableStateFlow("")
    val groupOwnerAddress: StateFlow<String> = _groupOwnerAddress

    private var onPeersUpdated: ((List<WifiDirectPeer>) -> Unit)? = null
    private var onConnected: ((String) -> Unit)? = null
    private var onError: ((String) -> Unit)? = null

    // ═══════════════════════════════════════════
    // INIT
    // ═══════════════════════════════════════════

    fun initialize() {
        try {
            channel = manager.initialize(context, Looper.getMainLooper(), null)
            registerReceiver()
            Log.d(TAG, "WiFi Direct initialisé")
        } catch (e: Exception) {
            Log.e(TAG, "Erreur init WiFi Direct: ${e.message}")
            onError?.call("WiFi Direct non disponible: ${e.message}")
        }
    }

    fun setCallbacks(
        onPeers: (List<WifiDirectPeer>) -> Unit,
        onConn: (String) -> Unit,
        onErr: (String) -> Unit,
    ) {
        onPeersUpdated = onPeers
        onConnected = onConn
        onError = onErr
    }

    // ═══════════════════════════════════════════
    // DISCOVERY
    // ═══════════════════════════════════════════

    fun startDiscovery() {
        val ch = channel ?: return

        // Découverte standard des pairs WiFi Direct
        manager.discoverPeers(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(TAG, "Découverte WiFi Direct démarrée")
            }
            override fun onFailure(reason: Int) {
                val msg = wifiP2pErrorReason(reason)
                Log.w(TAG, "Échec découverte WiFi Direct: $msg")
                onError?.call("Découverte échouée: $msg")
            }
        })

        // Enregistrement du service DNS-SD pour que les autres FriendlyNET nous voient
        registerLocalService()

        // Découverte des services FriendlyNET sur les autres appareils
        discoverFriendlyNetServices()
    }

    fun stopDiscovery() {
        val ch = channel ?: return
        manager.stopPeerDiscovery(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() = Log.d(TAG, "Découverte arrêtée")
            override fun onFailure(r: Int) {}
        })
        try {
            manager.clearLocalServices(ch, null)
            manager.clearServiceRequests(ch, null)
        } catch (_: Exception) {}
    }

    // ═══════════════════════════════════════════
    // SERVICE DNS-SD — Annonce FriendlyNET
    // ═══════════════════════════════════════════

    /**
     * Annonce notre présence sur le réseau WiFi Direct via DNS-SD.
     * Les autres appareils FriendlyNET qui cherchent "_friendlynet._tcp"
     * nous trouveront automatiquement.
     */
    private fun registerLocalService() {
        val ch = channel ?: return
        val record = mutableMapOf(
            "app" to "FriendlyNET",
            "version" to "1.0",
            "role" to "peer",
        )

        val serviceInfo = WifiP2pDnsSdServiceInfo.newInstance(
            SERVICE_NAME, SERVICE_TYPE, record
        )

        manager.addLocalService(ch, serviceInfo, object : WifiP2pManager.ActionListener {
            override fun onSuccess() = Log.d(TAG, "Service local DNS-SD enregistré")
            override fun onFailure(r: Int) = Log.w(TAG, "Échec enregistrement service: $r")
        })
    }

    /**
     * Recherche les services "_friendlynet._tcp" sur les appareils proches.
     */
    private fun discoverFriendlyNetServices() {
        val ch = channel ?: return

        // Listener TXT record
        val txtListener = WifiP2pManager.DnsSdTxtRecordListener { fullDomain, record, device ->
            if (fullDomain.contains("friendlynet", ignoreCase = true)) {
                Log.d(TAG, "FriendlyNET trouvé via DNS-SD: ${device.deviceName}")
            }
        }

        // Listener service
        val serviceListener = WifiP2pManager.DnsSdServiceResponseListener { instanceName, registrationType, device ->
            if (registrationType.contains("friendlynet", ignoreCase = true)) {
                val peer = WifiDirectPeer(
                    mac = device.deviceAddress,
                    name = device.deviceName,
                    status = device.status,
                    wifiP2pDevice = device,
                )
                val current = _peers.value.toMutableList()
                if (current.none { it.mac == peer.mac }) {
                    current.add(peer)
                    _peers.value = current
                    onPeersUpdated?.call(current)
                    Log.d(TAG, "Nouveau pair FriendlyNET: ${peer.name}")
                }
            }
        }

        manager.setDnsSdResponseListeners(ch, serviceListener, txtListener)

        val serviceRequest = WifiP2pDnsSdServiceRequest.newInstance()
        manager.addServiceRequest(ch, serviceRequest, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                manager.discoverServices(ch, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() = Log.d(TAG, "Découverte services lancée")
                    override fun onFailure(r: Int) = Log.w(TAG, "Échec découverte services: $r")
                })
            }
            override fun onFailure(r: Int) = Log.w(TAG, "Échec ajout service request: $r")
        })
    }

    // ═══════════════════════════════════════════
    // CONNEXION
    // ═══════════════════════════════════════════

    /**
     * Se connecte directement à un pair WiFi Direct.
     * Une fois connecté, l'IP du groupe owner (l'hôte) est disponible
     * dans groupOwnerAddress — c'est là qu'on connecte le tunnel TCP.
     */
    fun connectToPeer(peer: WifiDirectPeer) {
        val ch = channel ?: return

        val config = WifiP2pConfig().apply {
            deviceAddress = peer.mac
            wps.setup = android.net.wifi.WpsInfo.PBC // Push Button Connection — aucun PIN
            groupOwnerIntent = 0 // Préférer être client (pas group owner)
        }

        manager.connect(ch, config, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(TAG, "Connexion WiFi Direct initiée vers ${peer.name}")
            }
            override fun onFailure(reason: Int) {
                val msg = wifiP2pErrorReason(reason)
                Log.w(TAG, "Échec connexion WiFi Direct: $msg")
                onError?.call("Connexion échouée: $msg")
            }
        })
    }

    fun disconnect() {
        val ch = channel ?: return
        manager.removeGroup(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                _connected.value = false
                _groupOwnerAddress.value = ""
                Log.d(TAG, "Groupe WiFi Direct dissous")
            }
            override fun onFailure(r: Int) {}
        })
    }

    // ═══════════════════════════════════════════
    // BROADCAST RECEIVER
    // ═══════════════════════════════════════════

    private fun registerReceiver() {
        val filter = IntentFilter().apply {
            addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION)
        }
        receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                when (intent.action) {
                    WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION -> {
                        val state = intent.getIntExtra(WifiP2pManager.EXTRA_WIFI_STATE, -1)
                        if (state == WifiP2pManager.WIFI_P2P_STATE_ENABLED) {
                            Log.d(TAG, "WiFi P2P activé")
                        } else {
                            Log.w(TAG, "WiFi P2P désactivé")
                            onError?.call("WiFi Direct non disponible — activez le WiFi")
                        }
                    }

                    WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION -> {
                        val ch = channel ?: return
                        manager.requestPeers(ch) { peerList ->
                            val converted = peerList.deviceList.map { dev ->
                                WifiDirectPeer(
                                    mac = dev.deviceAddress,
                                    name = dev.deviceName,
                                    status = dev.status,
                                    wifiP2pDevice = dev,
                                )
                            }
                            // Fusionner avec les découvertes DNS-SD
                            val current = _peers.value.toMutableList()
                            converted.forEach { peer ->
                                if (current.none { it.mac == peer.mac }) {
                                    current.add(peer)
                                }
                            }
                            _peers.value = current
                            onPeersUpdated?.call(current)
                        }
                    }

                    WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                        val ch = channel ?: return
                        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            intent.getParcelableExtra(
                                WifiP2pManager.EXTRA_WIFI_P2P_INFO,
                                WifiP2pInfo::class.java
                            )
                        } else {
                            @Suppress("DEPRECATION")
                            intent.getParcelableExtra(WifiP2pManager.EXTRA_WIFI_P2P_INFO)
                        }

                        if (info != null && info.groupFormed) {
                            val ownerIp = info.groupOwnerAddress?.hostAddress ?: ""
                            _connected.value = true
                            _groupOwnerAddress.value = ownerIp
                            onConnected?.call(ownerIp)
                            Log.d(TAG, "Groupe WiFi Direct formé — owner: $ownerIp, isOwner: ${info.isGroupOwner}")
                        } else {
                            _connected.value = false
                            _groupOwnerAddress.value = ""
                        }
                    }
                }
            }
        }
        context.registerReceiver(receiver, filter)
    }

    fun cleanup() {
        stopDiscovery()
        try { receiver?.let { context.unregisterReceiver(it) } } catch (_: Exception) {}
        channel?.close()
        channel = null
    }

    // ═══════════════════════════════════════════
    // UTILS
    // ═══════════════════════════════════════════

    private fun wifiP2pErrorReason(reason: Int): String = when (reason) {
        WifiP2pManager.ERROR -> "Erreur interne"
        WifiP2pManager.P2P_UNSUPPORTED -> "WiFi Direct non supporté"
        WifiP2pManager.BUSY -> "Manager occupé"
        WifiP2pManager.NO_SERVICE_REQUESTS -> "Aucune requête de service"
        else -> "Raison inconnue ($reason)"
    }
}

// ─── Modèle pair WiFi Direct ───────────────────────────────
data class WifiDirectPeer(
    val mac: String,
    val name: String,
    val status: Int,
    val wifiP2pDevice: WifiP2pDevice,
) {
    val isAvailable: Boolean get() = status == WifiP2pDevice.AVAILABLE
    val statusLabel: String get() = when (status) {
        WifiP2pDevice.AVAILABLE -> "Disponible"
        WifiP2pDevice.INVITED -> "Invité"
        WifiP2pDevice.CONNECTED -> "Connecté"
        WifiP2pDevice.FAILED -> "Échec"
        WifiP2pDevice.UNAVAILABLE -> "Non disponible"
        else -> "Inconnu"
    }
}

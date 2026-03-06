package com.sygmatech.friendly_net

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val SYSTEM_CHANNEL = "friendlynet/system"
    private val VPN_CHANNEL    = "friendlynet/vpn"
    private val RELAY_CHANNEL  = "friendlynet/relay"

    // Code de requête pour la permission VPN Android
    private val VPN_PERMISSION_REQUEST_CODE = 101

    // Callback à appeler après l'approbation de la permission VPN
    private var pendingVpnResult: MethodChannel.Result? = null
    private var pendingVpnArgs: Map<String, Any>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ─── Système ───────────────────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SYSTEM_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestBatteryOptExemption" -> {
                        requestBatteryOptimizationExemption()
                        result.success(true)
                    }
                    "isBatteryOptExempt" -> {
                        result.success(isBatteryOptExempt())
                    }
                    "requestUnrestrictedData" -> {
                        requestUnrestrictedData()
                        result.success(true)
                    }
                    "startForeground" -> {
                        val title = call.argument<String>("title") ?: "FriendlyNET"
                        val body  = call.argument<String>("body")  ?: "Actif"
                        startForegroundGuard(title, body)
                        result.success(true)
                    }
                    "stopForeground" -> {
                        stopForegroundGuard()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        // ─── VPN Service (Mode Invité) ──────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VPN_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startVpn" -> {
                        @Suppress("UNCHECKED_CAST")
                        val args = call.arguments as? Map<String, Any> ?: emptyMap()

                        // Vérifier si Android a besoin d'une permission VPN explicite
                        val intent = VpnService.prepare(this)
                        if (intent != null) {
                            // L'utilisateur doit accepter le VPN
                            pendingVpnResult = result
                            pendingVpnArgs   = args
                            startActivityForResult(intent, VPN_PERMISSION_REQUEST_CODE)
                        } else {
                            // Permission déjà accordée
                            launchVpnService(args)
                            result.success(true)
                        }
                    }
                    "stopVpn" -> {
                        val stopIntent = Intent(this, FriendlyNetVpnService::class.java).apply {
                            putExtra(FriendlyNetVpnService.EXTRA_STOP, true)
                        }
                        startService(stopIntent)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        // ─── Relay Service (Mode Hôte) ──────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, RELAY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startRelay" -> {
                        val port = call.argument<Int>("port") ?: 8899
                        val intent = Intent(this, FriendlyNetRelayService::class.java).apply {
                            putExtra(FriendlyNetRelayService.EXTRA_PORT, port)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                    }
                    "stopRelay" -> {
                        val intent = Intent(this, FriendlyNetRelayService::class.java).apply {
                            putExtra(FriendlyNetRelayService.EXTRA_STOP, true)
                        }
                        startService(intent)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ═══════════════════════════════════════════════════════════════
    // Résultat de la boîte de dialogue Android "Autoriser le VPN ?"
    // ═══════════════════════════════════════════════════════════════

    @Deprecated("Needed for VPN permission flow")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == VPN_PERMISSION_REQUEST_CODE) {
            if (resultCode == RESULT_OK) {
                val args = pendingVpnArgs ?: emptyMap()
                launchVpnService(args)
                pendingVpnResult?.success(true)
            } else {
                // L'utilisateur a refusé
                pendingVpnResult?.success(false)
            }
            pendingVpnResult = null
            pendingVpnArgs   = null
        } else {
            @Suppress("DEPRECATION")
            super.onActivityResult(requestCode, resultCode, data)
        }
    }

    /** Démarre réellement le VpnService avec les paramètres de Flutter. */
    private fun launchVpnService(args: Map<String, Any>) {
        val intent = Intent(this, FriendlyNetVpnService::class.java).apply {
            putExtra(FriendlyNetVpnService.EXTRA_NODE_ID,   args["nodeId"]  as? String ?: "")
            putExtra(FriendlyNetVpnService.EXTRA_USER_ID,   args["userId"]  as? String ?: "")
            putExtra(FriendlyNetVpnService.EXTRA_WORKER_URL,args["workerUrl"] as? String
                ?: "wss://bufferwave-tunnel.sfrfrfr.workers.dev/tunnel")
            putExtra(FriendlyNetVpnService.EXTRA_TUNNEL_KEY,args["tunnelKey"] as? String ?: "")
            putExtra(FriendlyNetVpnService.EXTRA_KEEPALIVE, (args["keepaliveInterval"] as? Int) ?: 15)
            putExtra(FriendlyNetVpnService.EXTRA_LOW_BW,    (args["lowBandwidth"] as? Boolean) ?: false)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    // ═══════════════════════════════════════════
    // BATTERY OPTIMIZATION
    // ═══════════════════════════════════════════

    private fun requestBatteryOptimizationExemption() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                    data = Uri.parse("package:$packageName")
                }
                startActivity(intent)
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

    // ═══════════════════════════════════════════
    // UNRESTRICTED DATA
    // ═══════════════════════════════════════════

    private fun requestUnrestrictedData() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                val intent = Intent(Settings.ACTION_IGNORE_BACKGROUND_DATA_RESTRICTIONS_SETTINGS).apply {
                    data = Uri.parse("package:$packageName")
                }
                startActivity(intent)
            } catch (e: Exception) {
                try {
                    val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                        data = Uri.parse("package:$packageName")
                    }
                    startActivity(intent)
                } catch (_: Exception) {}
            }
        }
    }

    // ═══════════════════════════════════════════
    // FOREGROUND GUARD (notif principale de l'app)
    // ═══════════════════════════════════════════

    private fun startForegroundGuard(title: String, body: String) {
        val intent = Intent(this, FriendlyNetForegroundService::class.java).apply {
            putExtra("title", title)
            putExtra("body", body)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun stopForegroundGuard() {
        stopService(Intent(this, FriendlyNetForegroundService::class.java))
    }
}

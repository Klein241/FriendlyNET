package com.sygmatech.friendly_net

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val SYSTEM_CHANNEL = "friendlynet/system"
    private val VPN_CHANNEL = "friendlynet/vpn"
    private val RELAY_CHANNEL = "friendlynet/relay"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ─── System Protection Channel ───
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
                        val body = call.argument<String>("body") ?: "Actif"
                        startForegroundService(title, body)
                        result.success(true)
                    }
                    "stopForeground" -> {
                        stopForegroundService()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        // ─── VPN Channel (à implémenter) ───
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VPN_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startVpn" -> {
                        // TODO: Démarrer le VPN service
                        result.success(true)
                    }
                    "stopVpn" -> {
                        // TODO: Arrêter le VPN service
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        // ─── Relay Channel (à implémenter) ───
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, RELAY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startRelay" -> {
                        val port = call.argument<Int>("port") ?: 8899
                        // TODO: Démarrer le relais TCP
                        result.success(true)
                    }
                    "stopRelay" -> {
                        // TODO: Arrêter le relais TCP
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ═══════════════════════════════════════════
    // BATTERY OPTIMIZATION EXEMPTION
    // ═══════════════════════════════════════════
    //
    // Critique pour le scénario Orange 100 Mo :
    // Quand la data est throttlée, Android veut tuer l'app
    // en arrière-plan. Cette exemption empêche ça.

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
    //
    // Ouvre les paramètres pour que l'utilisateur autorise
    // l'app à consommer des données en arrière-plan même
    // en mode "Économie de données" d'Android.

    private fun requestUnrestrictedData() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                val intent = Intent(Settings.ACTION_IGNORE_BACKGROUND_DATA_RESTRICTIONS_SETTINGS).apply {
                    data = Uri.parse("package:$packageName")
                }
                startActivity(intent)
            } catch (e: Exception) {
                // Certains appareils ne supportent pas cet intent
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
    // FOREGROUND SERVICE
    // ═══════════════════════════════════════════
    //
    // Notification persistante "FriendlyNET actif"
    // qui empêche Android de tuer le processus.
    // Essentiel quand le forfait est épuisé et que
    // le tunnel doit rester ouvert.

    private fun startForegroundService(title: String, body: String) {
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

    private fun stopForegroundService() {
        val intent = Intent(this, FriendlyNetForegroundService::class.java)
        stopService(intent)
    }
}

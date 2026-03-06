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

/**
 * FriendlyNET Foreground Service
 *
 * Maintient le processus vivant même quand :
 *  - L'utilisateur quitte l'app
 *  - Le forfait Orange est épuisé/throttlé
 *  - Android applique les restrictions batterie
 *  - Le mode "Économie de données" est activé
 *
 * Affiche une notification persistante "FriendlyNET actif"
 * qui rassure l'utilisateur et empêche le système de tuer le process.
 */
class FriendlyNetForegroundService : Service() {

    companion object {
        private const val TAG = "FN-Foreground"
        private const val CHANNEL_ID = "fn_foreground_channel"
        private const val CHANNEL_NAME = "FriendlyNET"
        private const val NOTIF_ID = 9001
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        Log.d(TAG, "Service créé")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra("title") ?: "FriendlyNET actif"
        val body = intent?.getStringExtra("body") ?: "Partage en cours"

        val notification = buildNotification(title, body)
        startForeground(NOTIF_ID, notification)

        Log.d(TAG, "Foreground démarré: $title / $body")

        // START_STICKY = Android redémarre le service si tué
        return START_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        Log.d(TAG, "Service détruit")
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW // Pas de son, pas de vibration
            ).apply {
                description = "Maintient FriendlyNET actif en arrière-plan"
                setShowBadge(false)
            }
            val mgr = getSystemService(NotificationManager::class.java)
            mgr?.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(title: String, body: String): Notification {
        // Intent pour ouvrir l'app au clic
        val openApp = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pending = PendingIntent.getActivity(
            this, 0, openApp,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth) // TODO: icône custom
            .setContentTitle(title)
            .setContentText(body)
            .setOngoing(true) // Pas supprimable
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(pending)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }
}

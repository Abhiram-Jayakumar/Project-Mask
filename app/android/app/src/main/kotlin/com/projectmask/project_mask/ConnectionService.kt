package com.projectmask.project_mask

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Generic keep-alive foreground service used by the VIEWER role. The viewer holds
 * no MediaProjection, so it can't use the mediaProjection-typed
 * [ScreenCaptureService]; this one is typed `connectedDevice` (justified by the
 * app maintaining a network connection to a remote device — its required runtime
 * permission, CHANGE_NETWORK_STATE, is already granted). It keeps the process
 * alive while a session is connected so swiping the app off recents doesn't drop
 * the control link. Declared `stopWithTask="false"` in the manifest.
 */
class ConnectionService : Service() {

    companion object {
        private const val CHANNEL_ID = "project_mask_session"
        private const val NOTIFICATION_ID = 1002
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createNotificationChannel()
        val notification = buildNotification()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Remote session",
                NotificationManager.IMPORTANCE_LOW,
            ).apply { description = "Active while you are connected to a remote device" }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Sim Tool")
            .setContentText("Connected to a remote device — tap to return")
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentIntent(MaskNotifications.relaunchIntent(this))
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    override fun onDestroy() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }
}

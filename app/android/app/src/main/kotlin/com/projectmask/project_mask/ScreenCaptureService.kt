package com.projectmask.project_mask

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Foreground service that exists so Android lets us hold a MediaProjection while
 * screen sharing. It can ALSO carry the `camera` foreground-service type so the
 * host's front camera can be opened on-demand even while the app is backgrounded
 * (Android otherwise blocks background camera access).
 *
 * Safety: the camera type is only added when the CAMERA runtime permission is
 * actually granted — otherwise `startForeground` with a camera type would throw
 * and break screen sharing. If it isn't granted we silently fall back to
 * mediaProjection-only, so the screen share is never at risk.
 *
 * Lifecycle: Dart starts this (via MethodChannel) BEFORE getDisplayMedia and
 * stops it when sharing ends. [updateCameraType] flips the camera type on/off
 * from the running instance (no fresh start, so no background-start limits).
 */
class ScreenCaptureService : Service() {

    companion object {
        private const val CHANNEL_ID = "project_mask_screen_capture"
        private const val NOTIFICATION_ID = 1001

        /** The running service, or null when not sharing. */
        @Volatile
        var instance: ScreenCaptureService? = null
    }

    private var screenOn = false
    private var cameraOn = false
    private var micOn = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        instance = this
        createNotificationChannel()
        startForegroundWithType()
        return START_NOT_STICKY
    }

    /** Add/remove the mediaProjection FGS type (screen sharing on/off). The base
     *  type is always connectedDevice, so the host can stay "online" for the
     *  session (camera/mic on-demand) without sharing the screen. */
    fun updateScreenType(on: Boolean) {
        screenOn = on
        startForegroundWithType()
    }

    /** Add/remove the camera FGS type from the already-running service. */
    fun updateCameraType(on: Boolean) {
        cameraOn = on
        startForegroundWithType()
    }

    /** Add/remove the microphone FGS type from the already-running service. */
    fun updateMicType(on: Boolean) {
        micOn = on
        startForegroundWithType()
    }

    private fun hasPermission(name: String): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            checkSelfPermission(name) == PackageManager.PERMISSION_GRANTED

    private fun startForegroundWithType() {
        val notification = buildNotification()
        when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R -> {
                // Base = connectedDevice (host keep-alive; satisfied by
                // CHANGE_NETWORK_STATE). Add other types only when active AND
                // their permission is granted, else startForeground throws.
                var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
                if (screenOn) {
                    type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                }
                if (cameraOn && hasPermission(Manifest.permission.CAMERA)) {
                    type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
                }
                if (micOn && hasPermission(Manifest.permission.RECORD_AUDIO)) {
                    type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                }
                startForeground(NOTIFICATION_ID, notification, type)
            }
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ->
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    if (screenOn) {
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                    } else {
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
                    },
                )
            else -> startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Screen sharing",
                NotificationManager.IMPORTANCE_LOW,
            ).apply { description = "Active while your screen is being shared" }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Sim Tool")
            .setContentText("Your screen is being shared — tap to return")
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentIntent(MaskNotifications.relaunchIntent(this))
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    override fun onDestroy() {
        instance = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }
}

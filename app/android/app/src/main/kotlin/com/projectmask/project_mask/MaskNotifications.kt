package com.projectmask.project_mask

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat

/** Shared helper for the foreground-service notifications. */
object MaskNotifications {

    private const val CHANNEL_RESTORE = "project_mask_restore"
    private const val NOTIF_RESTORE = 1003

    /**
     * A PendingIntent that brings the app back to the foreground, re-attaching to
     * the cached engine so the user lands on the still-live session. Uses the
     * launcher intent + SINGLE_TOP so it reuses the existing task/Activity rather
     * than starting a fresh one.
     */
    fun relaunchIntent(context: Context): PendingIntent {
        val launch = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK
        }
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = flags or PendingIntent.FLAG_IMMUTABLE
        }
        return PendingIntent.getActivity(context, 0, launch, flags)
    }

    /**
     * Shows a high-priority notification after the device reboots while anytime
     * access was armed. Tapping it brings the app to the foreground so the user
     * can accept the MediaProjection dialog (the only action Android requires
     * after a reboot — the rest is automatic).
     */
    fun showBootRestoreNotification(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val channel = NotificationChannel(
                CHANNEL_RESTORE,
                "Anytime access restore",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Shown when the device restarts while anytime access was active"
            }
            nm.createNotificationChannel(channel)
        }

        val piFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        else PendingIntent.FLAG_UPDATE_CURRENT

        // Use request code NOTIF_RESTORE (distinct from 0 used by relaunchIntent)
        // so this PendingIntent doesn't overwrite the FGS relaunch intent.
        val launchIntent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK
        }
        val pi = PendingIntent.getActivity(context, NOTIF_RESTORE, launchIntent, piFlags)

        val notification = NotificationCompat.Builder(context, CHANNEL_RESTORE)
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentTitle("Sim Tool — anytime access interrupted")
            .setContentText("Your device restarted. Tap to re-enable remote access (one tap on the dialog).")
            .setContentIntent(pi)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIF_RESTORE, notification)
    }
}

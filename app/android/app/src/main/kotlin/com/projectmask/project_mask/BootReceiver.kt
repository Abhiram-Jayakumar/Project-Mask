package com.projectmask.project_mask

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Fires on BOOT_COMPLETED. If anytime access was armed before the device shut
 * down (flag persisted by the Dart layer in FlutterSharedPreferences) this
 * receiver writes a "restore pending" flag and shows a notification so the user
 * can restore the session with a single tap + the system MediaProjection dialog.
 *
 * Android requires a fresh MediaProjection consent dialog after every reboot;
 * we cannot bypass it, so the minimum user interaction is always two taps:
 *   1. Tap this notification to bring the app to the foreground.
 *   2. Tap "Start now" on the system recording dialog.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return

        // shared_preferences stores Dart keys as "flutter.<key>" in the file
        // named "FlutterSharedPreferences".
        val prefs = context.getSharedPreferences(
            "FlutterSharedPreferences", Context.MODE_PRIVATE,
        )
        if (!prefs.getBoolean("flutter.anytime_armed", false)) return

        // Signal to the Dart layer that it should auto-arm on next resume.
        // Use commit() (synchronous) so the write is on disk before the Dart
        // SharedPreferences.reload() call reads it.
        prefs.edit().putBoolean("flutter.boot_restore_pending", true).commit()

        MaskNotifications.showBootRestoreNotification(context)
    }
}

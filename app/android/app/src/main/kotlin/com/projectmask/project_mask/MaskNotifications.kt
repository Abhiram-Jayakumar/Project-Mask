package com.projectmask.project_mask

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build

/** Shared helper for the foreground-service notifications. */
object MaskNotifications {

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
}

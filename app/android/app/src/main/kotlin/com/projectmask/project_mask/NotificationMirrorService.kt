package com.projectmask.project_mask

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * Streams the host's app notifications to Flutter via a callback set by
 * [MaskChannels]. Only social / informational notifications reach the viewer —
 * SMS, phone calls, system UI, banking, and OTP-style messages are silently
 * dropped before the callback fires.
 *
 * The user must explicitly grant notification access in
 * Settings › Apps › Special app access › Notification access before this
 * service receives any events.
 */
class NotificationMirrorService : NotificationListenerService() {

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onDestroy() {
        super.onDestroy()
        if (instance === this) instance = null
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val cb = callback ?: return
        val pkg = sbn.packageName ?: return

        if (isBlocked(pkg)) return
        // Skip persistent bars (music player, navigation, downloads…)
        if (sbn.isOngoing) return
        // Skip the single "bundle" summary notification that wraps a group.
        if (sbn.notification.flags and android.app.Notification.FLAG_GROUP_SUMMARY != 0) return

        val extras: Bundle = sbn.notification.extras
        val title = extras.getCharSequence("android.title")
            ?.toString()?.trim()?.takeIf { it.isNotEmpty() } ?: return
        val text = (extras.getCharSequence("android.bigText")
            ?: extras.getCharSequence("android.text"))
            ?.toString()?.trim() ?: ""

        // Drop anything that looks like an OTP or verification message.
        val combined = "$title $text".lowercase()
        if (OTP_KEYWORDS.any { combined.contains(it) }) return

        // Debounce: same (pkg + title + text) within 3 s → ignore duplicate.
        val key = "$pkg|$title|$text"
        val now = System.currentTimeMillis()
        val last = recentKeys[key]
        if (last != null && now - last < 3_000L) return
        recentKeys[key] = now
        if (recentKeys.size > 200) {
            val cutoff = now - 10_000L
            recentKeys.entries.removeIf { it.value < cutoff }
        }

        val appLabel = try {
            packageManager.getApplicationLabel(
                packageManager.getApplicationInfo(pkg, 0)
            ).toString()
        } catch (_: Exception) { pkg }

        val payload = mapOf(
            "app"   to appLabel,
            "pkg"   to pkg,
            "title" to title,
            "text"  to text,
            "time"  to sbn.postTime,
        )

        // The EventChannel sink must be called on the main thread.
        Handler(Looper.getMainLooper()).post { cb(payload) }
    }

    private fun isBlocked(pkg: String): Boolean {
        if (BLOCKED_EXACT.contains(pkg)) return true
        if (BLOCKED_PREFIXES.any { pkg.startsWith(it) }) return true
        if (BLOCKED_KEYWORDS.any { pkg.contains(it, ignoreCase = true) }) return true
        return false
    }

    companion object {
        var instance: NotificationMirrorService? = null
        var callback: ((Map<String, Any>) -> Unit)? = null
        private val recentKeys = HashMap<String, Long>()

        private val BLOCKED_EXACT = setOf(
            "android",
            "com.android.systemui",
            "com.android.settings",
            "com.google.android.gms",
            "com.android.mms",
            "com.google.android.apps.messaging",
            "com.samsung.android.messaging",
            "com.android.phone",
            "com.google.android.dialer",
            "com.samsung.android.dialer",
            "com.android.incallui",
        )

        private val BLOCKED_PREFIXES = listOf(
            "com.android.",
            "com.google.android.gsf",
        )

        private val BLOCKED_KEYWORDS = listOf(
            "messaging", ".sms", ".mms", "dialer", ".phone.",
            "bank", ".wallet", ".pay.",
        )

        private val OTP_KEYWORDS = listOf(
            "otp", "one-time", "one time", "verification code",
            "verify your", "auth code", "security code", "login code",
            "2fa", "two-factor", "passcode", "your code is",
            "enter code", " pin is ", "pin:", "new pin",
        )
    }
}

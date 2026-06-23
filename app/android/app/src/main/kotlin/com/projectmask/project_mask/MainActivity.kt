package com.projectmask.project_mask

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

/**
 * Attaches to the long-lived engine warmed in [MaskApplication] instead of
 * creating its own. Because the engine is cached and is NOT destroyed with this
 * host, swiping the app off recents destroys the Activity but leaves the Dart
 * isolate (WebRTC + signaling) running. Platform channels are registered on the
 * engine in [MaskChannels]; this class only handles things that genuinely need a
 * live Activity (the notification-permission prompt and moving the task to back).
 */
class MainActivity : FlutterActivity() {

    companion object {
        /** The currently-attached Activity, or null while backgrounded/destroyed. */
        @Volatile
        var current: MainActivity? = null
    }

    override fun getCachedEngineId(): String = MaskApplication.ENGINE_ID

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        current = this
        // Best-effort: ask for notification permission so the foreground-service
        // notification shows on Android 13+. The service still runs if denied.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
        }
    }

    override fun onDestroy() {
        if (current === this) current = null
        super.onDestroy()
    }
}

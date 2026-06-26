package com.projectmask.project_mask

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
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

    /** Prompt for the CAMERA permission once (at setup) so the on-demand camera
     *  never needs to disturb the host later. No-op if already granted. */
    fun requestCameraPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            checkSelfPermission(Manifest.permission.CAMERA) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.CAMERA), 1002)
        }
    }

    /** Prompt for RECORD_AUDIO once (at setup) for on-demand listen-in. */
    fun requestMicPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 1003)
        }
    }

    /**
     * Request storage read access so the host can share folders with the viewer.
     * On Android ≤ 12: standard READ_EXTERNAL_STORAGE runtime prompt.
     * On Android 13+: open the "All files access" settings page (MANAGE_EXTERNAL_STORAGE
     * cannot be requested via the normal runtime dialog).
     */
    fun requestStoragePermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Android 11+ (API 30+): MANAGE_EXTERNAL_STORAGE requires the user
            // to grant "All files access" from a dedicated system settings page.
            if (!Environment.isExternalStorageManager()) {
                try {
                    startActivity(
                        Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                            .setData(Uri.parse("package:$packageName"))
                    )
                } catch (_: Exception) {
                    startActivity(
                        Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                    )
                }
            }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            if (checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) !=
                PackageManager.PERMISSION_GRANTED
            ) {
                requestPermissions(
                    arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE), 1004
                )
            }
        }
    }

    override fun onDestroy() {
        if (current === this) current = null
        super.onDestroy()
    }
}

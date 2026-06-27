package com.projectmask.project_mask

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

/**
 * Attaches to the long-lived engine warmed in [MaskApplication] instead of
 * creating its own. Because the engine is cached and is NOT destroyed with this
 * host, swiping the app off recents destroys the Activity but leaves the Dart
 * isolate (WebRTC + signaling) running. Platform channels are registered on the
 * engine in [MaskChannels]; this class only handles things that genuinely need a
 * live Activity (permission prompts, moving the task to back, and the viewer
 * screen-capture consent dialog).
 */
class MainActivity : FlutterActivity() {

    companion object {
        /** The currently-attached Activity, or null while backgrounded/destroyed. */
        @Volatile
        var current: MainActivity? = null

        private const val VIEWER_CAPTURE_REQUEST = 2001
    }

    // ── Viewer screen-capture consent ────────────────────────────────────────
    private var pendingCaptureResult: MethodChannel.Result? = null

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

    /** Launch the Android "record your screen" consent dialog for the viewer.
     *  The service MUST already be running when this is called (MaskChannels
     *  starts it via startForegroundService just before invoking this method).
     *  [result] is resolved after the user accepts or cancels. */
    fun startScreenCaptureForViewer(result: MethodChannel.Result) {
        pendingCaptureResult = result
        val pm = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        @Suppress("DEPRECATION")
        startActivityForResult(pm.createScreenCaptureIntent(), VIEWER_CAPTURE_REQUEST)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != VIEWER_CAPTURE_REQUEST) return

        if (resultCode == Activity.RESULT_OK && data != null) {
            val pm = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            val projection = pm.getMediaProjection(resultCode, data)
            if (projection == null) {
                pendingCaptureResult?.success(false)
                pendingCaptureResult = null
                return
            }
            // Give the FGS a moment to reach onStartCommand before beginCapture.
            Handler(Looper.getMainLooper()).postDelayed({
                val svc = ViewerCaptureService.instance
                if (svc != null) {
                    svc.beginCapture(projection)
                    pendingCaptureResult?.success(true)
                } else {
                    projection.stop()
                    pendingCaptureResult?.success(false)
                }
                pendingCaptureResult = null
            }, 300)
        } else {
            // User cancelled or denied the screen-capture consent.
            ViewerCaptureService.instance?.stopCapture()
            pendingCaptureResult?.success(false)
            pendingCaptureResult = null
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

package com.projectmask.project_mask

import android.annotation.SuppressLint
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Registers all of the app's platform channels on the cached engine's messenger,
 * using the application context. Because they live on the engine (not an Activity)
 * the handlers keep working while the app is backgrounded / swiped away — in
 * particular the `gesture` path that injects remote taps via the accessibility
 * service. Only [MethodChannel] calls that truly need a foreground Activity
 * (notification permission, moving the task to back) reach into [MainActivity].
 */
object MaskChannels {

    fun register(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext

        // --- Host screen-capture foreground service ---
        MethodChannel(messenger, "project_mask/screen").setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    startFgs(app, ScreenCaptureService::class.java)
                    result.success(true)
                }
                "stopService" -> {
                    app.stopService(Intent(app, ScreenCaptureService::class.java))
                    result.success(true)
                }
                "setScreen" -> {
                    // Add/remove the mediaProjection FGS type (screen on/off)
                    // without tearing down the host keep-alive service.
                    val on = call.argument<Boolean>("on") ?: false
                    ScreenCaptureService.instance?.updateScreenType(on)
                    result.success(ScreenCaptureService.instance != null)
                }
                "setCamera" -> {
                    // Flip the camera FGS type on the running capture service so
                    // the front camera can be opened on-demand while backgrounded.
                    val on = call.argument<Boolean>("on") ?: false
                    ScreenCaptureService.instance?.updateCameraType(on)
                    result.success(ScreenCaptureService.instance != null)
                }
                "setMic" -> {
                    // Same for the microphone FGS type (background listen-in).
                    val on = call.argument<Boolean>("on") ?: false
                    ScreenCaptureService.instance?.updateMicType(on)
                    result.success(ScreenCaptureService.instance != null)
                }
                else -> result.notImplemented()
            }
        }

        // --- Generic keep-alive foreground service (viewer) ---
        MethodChannel(messenger, "project_mask/session").setMethodCallHandler { call, result ->
            when (call.method) {
                "startKeepAlive" -> {
                    startFgs(app, ConnectionService::class.java)
                    result.success(true)
                }
                "stopKeepAlive" -> {
                    app.stopService(Intent(app, ConnectionService::class.java))
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // --- System: battery-optimization exemption + send-to-background ---
        MethodChannel(messenger, "project_mask/system").setMethodCallHandler { call, result ->
            when (call.method) {
                "isIgnoringBatteryOptimizations" ->
                    result.success(isIgnoringBatteryOptimizations(app))
                "requestIgnoreBatteryOptimizations" -> {
                    requestIgnoreBatteryOptimizations(app)
                    result.success(true)
                }
                "moveTaskToBack" -> {
                    val activity = MainActivity.current
                    if (activity != null) {
                        activity.moveTaskToBack(true)
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                "requestCameraPermission" -> {
                    // Needs the Activity (foreground) to show the system dialog.
                    // Done once at setup so on-demand camera never re-prompts.
                    MainActivity.current?.requestCameraPermission()
                    result.success(MainActivity.current != null)
                }
                "requestMicPermission" -> {
                    MainActivity.current?.requestMicPermission()
                    result.success(MainActivity.current != null)
                }
                "requestStoragePermission" -> {
                    MainActivity.current?.requestStoragePermission()
                    result.success(MainActivity.current != null)
                }
                "saveToDownloads" -> {
                    val filename = call.argument<String>("filename") ?: "download"
                    val data = call.argument<ByteArray>("data")
                    if (data == null) {
                        result.error("NO_DATA", "No file data provided", null)
                    } else {
                        try {
                            val savedPath = saveToDownloads(app, filename, data)
                            result.success(savedPath)
                        } catch (e: Exception) {
                            result.error("SAVE_FAILED", e.message, null)
                        }
                    }
                }
                "isNotificationAccessGranted" ->
                    result.success(isNotificationAccessGranted(app))
                "requestNotificationAccess" -> {
                    try {
                        app.startActivity(
                            Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                "startViewerRecording" -> {
                    val activity = MainActivity.current
                    if (activity == null) {
                        result.success(false)
                    } else {
                        // Start the FGS first so it's running when the user approves.
                        startFgs(app, ViewerCaptureService::class.java)
                        activity.startScreenCaptureForViewer(result)
                    }
                }
                "stopViewerRecording" -> {
                    val svc = ViewerCaptureService.instance
                    if (svc == null) {
                        result.success("")
                    } else {
                        val srcPath = svc.stopCapture()
                        if (srcPath.isEmpty()) {
                            result.success("")
                        } else {
                            try {
                                val name = "recording_${System.currentTimeMillis()}.mp4"
                                val saved = copyFileToDownloads(app, srcPath, name)
                                result.success(saved)
                            } catch (e: Exception) {
                                result.error("SAVE_FAILED", e.message, null)
                            }
                        }
                    }
                }
                "saveImageToGallery" -> {
                    val filename = call.argument<String>("filename") ?: "screenshot.png"
                    val data = call.argument<ByteArray>("data")
                    if (data == null) {
                        result.error("NO_DATA", "No image data provided", null)
                    } else {
                        try {
                            val saved = saveImageToGallery(app, filename, data)
                            result.success(saved)
                        } catch (e: Exception) {
                            result.error("SAVE_FAILED", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        // ---- Notification mirror stream (host → Flutter) --------------------
        // The EventSink is held while Flutter is subscribed; the service posts
        // payloads on the main thread, so calling success() here is safe.
        EventChannel(messenger, "project_mask/notifications").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    NotificationMirrorService.callback = { data -> events?.success(data) }
                }
                override fun onCancel(arguments: Any?) {
                    NotificationMirrorService.callback = null
                }
            }
        )
    }

    private fun startFgs(context: Context, cls: Class<*>) {
        val intent = Intent(context, cls)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
    }

    private fun isIgnoringBatteryOptimizations(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(context.packageName)
    }

    /**
     * Save [data] as [filename] in the public Downloads folder.
     * Returns the path shown to the user.
     *
     * Android 10+ (API 29+): uses MediaStore so the file appears in the
     * system Downloads app without requiring WRITE_EXTERNAL_STORAGE.
     * Android 9 and below: writes directly via java.io.File.
     */
    private fun saveToDownloads(context: Context, filename: String, data: ByteArray): String {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, filename)
                put(MediaStore.Downloads.MIME_TYPE, "application/octet-stream")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val resolver = context.contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw Exception("Could not create Downloads entry")
            resolver.openOutputStream(uri)?.use { it.write(data) }
                ?: throw Exception("Could not open output stream")
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            "Downloads/$filename"
        } else {
            @Suppress("DEPRECATION")
            val dir = Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_DOWNLOADS
            )
            dir.mkdirs()
            val file = File(dir, filename)
            file.writeBytes(data)
            file.absolutePath
        }
    }

    /** Save [data] (PNG bytes) as [filename] in Pictures/ProjectMask. */
    private fun saveImageToGallery(context: Context, filename: String, data: ByteArray): String {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, filename)
                put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/ProjectMask")
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
            val resolver = context.contentResolver
            val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                ?: throw Exception("Could not create gallery entry")
            resolver.openOutputStream(uri)?.use { it.write(data) }
                ?: throw Exception("Could not open output stream")
            values.clear()
            values.put(MediaStore.Images.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            "Pictures/ProjectMask/$filename"
        } else {
            @Suppress("DEPRECATION")
            val dir = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
                "ProjectMask",
            )
            dir.mkdirs()
            val file = File(dir, filename)
            file.writeBytes(data)
            file.absolutePath
        }
    }

    /** Copy a temp video file to the public Downloads folder and delete the source. */
    private fun copyFileToDownloads(context: Context, srcPath: String, destName: String): String {
        val srcFile = File(srcPath)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, destName)
                put(MediaStore.Downloads.MIME_TYPE, "video/mp4")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val resolver = context.contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw Exception("Could not create Downloads entry")
            resolver.openOutputStream(uri)?.use { out ->
                srcFile.inputStream().use { it.copyTo(out) }
            } ?: throw Exception("Could not open output stream")
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            srcFile.delete()
            "Downloads/$destName"
        } else {
            @Suppress("DEPRECATION")
            val dir = Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_DOWNLOADS
            )
            dir.mkdirs()
            val dest = File(dir, destName)
            srcFile.copyTo(dest, overwrite = true)
            srcFile.delete()
            dest.absolutePath
        }
    }

    private fun isNotificationAccessGranted(context: Context): Boolean {
        val flat = android.provider.Settings.Secure.getString(
            context.contentResolver, "enabled_notification_listeners"
        ) ?: return false
        return flat.split(":").any { it.startsWith(context.packageName) }
    }

    @SuppressLint("BatteryLife")
    private fun requestIgnoreBatteryOptimizations(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        try {
            context.startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                    .setData(Uri.parse("package:${context.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        } catch (_: Exception) {
            // Some OEMs block the direct request; fall back to the settings list.
            context.startActivity(
                Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }
}

package com.projectmask.project_mask

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

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
                "setCamera" -> {
                    // Flip the camera FGS type on the running capture service so
                    // the front camera can be opened on-demand while backgrounded.
                    val on = call.argument<Boolean>("on") ?: false
                    ScreenCaptureService.instance?.updateCameraType(on)
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

        // --- Remote control (gesture injection + accessibility settings) ---
        MethodChannel(messenger, "project_mask/control").setMethodCallHandler { call, result ->
            when (call.method) {
                "gesture" -> {
                    val type = call.argument<String>("t") ?: ""
                    val x = call.argument<Double>("x") ?: 0.0
                    val y = call.argument<Double>("y") ?: 0.0
                    result.success(RemoteAccessibilityService.handleTouch(type, x, y))
                }
                "isAccessibilityEnabled" -> result.success(isAccessibilityEnabled(app))
                "openAccessibilitySettings" -> {
                    app.startActivity(
                        Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
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
                else -> result.notImplemented()
            }
        }
    }

    private fun startFgs(context: Context, cls: Class<*>) {
        val intent = Intent(context, cls)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
    }

    private fun isAccessibilityEnabled(context: Context): Boolean {
        val enabled = Settings.Secure.getString(
            context.contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
        ) ?: return false
        return enabled.split(':').any { it.contains("RemoteAccessibilityService") }
    }

    private fun isIgnoringBatteryOptimizations(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(context.packageName)
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

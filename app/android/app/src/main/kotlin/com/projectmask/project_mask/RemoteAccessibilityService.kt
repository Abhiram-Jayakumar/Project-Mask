package com.projectmask.project_mask

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.graphics.Path
import android.graphics.PointF
import android.os.Build
import android.os.SystemClock
import android.util.DisplayMetrics
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent

/**
 * Injects remote touch input onto this device. A normal app can't tap outside its
 * own window — an AccessibilityService with canPerformGestures is the only
 * sanctioned way (same approach RustDesk uses).
 *
 * Receives normalized coordinates (0.0–1.0) forwarded from the viewer via the
 * data channel → MethodChannel → [handleTouch], denormalizes them to real pixels,
 * and dispatches:
 *   - `tap`              → a quick StrokeDescription
 *   - `down`/`move`/`up` → buffered into a single swipe path dispatched on `up`
 */
class RemoteAccessibilityService : AccessibilityService() {

    companion object {
        @Volatile
        private var instance: RemoteAccessibilityService? = null

        /** True if dispatched; false if the service isn't enabled/running. */
        fun handleTouch(type: String, xNorm: Double, yNorm: Double): Boolean {
            val service = instance ?: return false
            service.onTouch(type, xNorm.toFloat(), yNorm.toFloat())
            return true
        }
    }

    private val pathPoints = mutableListOf<PointF>()
    private var gestureStart = 0L

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) { /* not used */ }

    override fun onInterrupt() { /* not used */ }

    override fun onUnbind(intent: Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    private fun screenSize(): Pair<Int, Int> {
        val wm = getSystemService(WINDOW_SERVICE) as WindowManager
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bounds = wm.currentWindowMetrics.bounds
            Pair(bounds.width(), bounds.height())
        } else {
            val metrics = DisplayMetrics()
            @Suppress("DEPRECATION")
            wm.defaultDisplay.getRealMetrics(metrics)
            Pair(metrics.widthPixels, metrics.heightPixels)
        }
    }

    private fun onTouch(type: String, xNorm: Float, yNorm: Float) {
        val (width, height) = screenSize()
        val px = (xNorm * width).coerceIn(0f, (width - 1).toFloat())
        val py = (yNorm * height).coerceIn(0f, (height - 1).toFloat())
        when (type) {
            "tap" -> dispatchTap(px, py)
            "down" -> {
                pathPoints.clear()
                pathPoints.add(PointF(px, py))
                gestureStart = SystemClock.uptimeMillis()
            }
            "move" -> pathPoints.add(PointF(px, py))
            "up" -> {
                pathPoints.add(PointF(px, py))
                dispatchSwipe()
            }
        }
    }

    private fun dispatchTap(px: Float, py: Float) {
        val path = Path().apply { moveTo(px, py) }
        val stroke = GestureDescription.StrokeDescription(path, 0, 50)
        dispatchGesture(GestureDescription.Builder().addStroke(stroke).build(), null, null)
    }

    private fun dispatchSwipe() {
        // A drag with no real movement is just a tap.
        if (pathPoints.size < 2) {
            pathPoints.firstOrNull()?.let { dispatchTap(it.x, it.y) }
            pathPoints.clear()
            return
        }
        val path = Path().apply {
            moveTo(pathPoints.first().x, pathPoints.first().y)
            for (i in 1 until pathPoints.size) {
                lineTo(pathPoints[i].x, pathPoints[i].y)
            }
        }
        val duration = (SystemClock.uptimeMillis() - gestureStart).coerceIn(50L, 2000L)
        val stroke = GestureDescription.StrokeDescription(path, 0, duration)
        dispatchGesture(GestureDescription.Builder().addStroke(stroke).build(), null, null)
        pathPoints.clear()
    }
}

package com.projectmask.project_mask

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.os.Build
import android.os.IBinder
import android.util.DisplayMetrics
import android.view.WindowManager
import androidx.core.app.NotificationCompat

/**
 * Foreground service that records the viewer's device screen to an MP4 file.
 *
 * The host must explicitly allow capture before the viewer can start. Once
 * the viewer starts recording the Android system shows its "recording your
 * screen" consent dialog. After approval [beginCapture] is called by
 * [MainActivity]'s ActivityResultLauncher to hook up the [MediaProjection].
 *
 * Lifecycle: started by [MaskChannels.startViewerRecording], stopped by
 * [MaskChannels.stopViewerRecording]. [stopCapture] returns the temp MP4
 * path; the caller copies it to Downloads via [MaskChannels.copyFileToDownloads].
 */
class ViewerCaptureService : Service() {

    private var mediaProjection: MediaProjection? = null
    private var mediaRecorder: MediaRecorder? = null
    private var virtualDisplay: VirtualDisplay? = null

    var outputPath: String = ""
        private set

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        instance = this
        createChannel()
        val notif = buildNotif()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIF_ID, notif,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } else {
            startForeground(NOTIF_ID, notif)
        }
        return START_NOT_STICKY
    }

    /** Called by [MainActivity] after the user approves the system consent dialog. */
    fun beginCapture(projection: MediaProjection) {
        val wm = getSystemService(WINDOW_SERVICE) as WindowManager
        val metrics = DisplayMetrics()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val b = wm.currentWindowMetrics.bounds
            metrics.widthPixels  = b.width()
            metrics.heightPixels = b.height()
            metrics.densityDpi   = resources.configuration.densityDpi
        } else {
            @Suppress("DEPRECATION")
            wm.defaultDisplay.getMetrics(metrics)
        }
        val w   = metrics.widthPixels
        val h   = metrics.heightPixels
        val dpi = metrics.densityDpi

        outputPath = "${externalCacheDir?.absolutePath}/capture_${System.currentTimeMillis()}.mp4"

        mediaRecorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            MediaRecorder(this)
        } else {
            @Suppress("DEPRECATION")
            MediaRecorder()
        }.also { rec ->
            rec.setVideoSource(MediaRecorder.VideoSource.SURFACE)
            rec.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            rec.setVideoEncoder(MediaRecorder.VideoEncoder.H264)
            rec.setVideoSize(w, h)
            rec.setVideoFrameRate(30)
            rec.setVideoEncodingBitRate(5_000_000)
            rec.setOutputFile(outputPath)
            rec.prepare()
        }

        virtualDisplay = projection.createVirtualDisplay(
            "ProjectMaskCapture",
            w, h, dpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            mediaRecorder!!.surface,
            null, null,
        )

        mediaProjection = projection
        mediaRecorder!!.start()
    }

    /** Stop recording and return the temp MP4 path (empty if nothing was recorded). */
    fun stopCapture(): String {
        try { mediaRecorder?.stop() } catch (_: Exception) {}
        mediaRecorder?.release()
        mediaRecorder = null
        virtualDisplay?.release()
        virtualDisplay = null
        mediaProjection?.stop()
        mediaProjection = null
        val path = outputPath
        instance = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
        return path
    }

    override fun onDestroy() {
        if (instance === this) stopCapture()
        super.onDestroy()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Session recording",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply { description = "Active while recording the session" }
            )
        }
    }

    private fun buildNotif(): Notification =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Sim Tool")
            .setContentText("Recording session — tap to return")
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentIntent(MaskNotifications.relaunchIntent(this))
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

    companion object {
        @Volatile
        var instance: ViewerCaptureService? = null

        private const val CHANNEL_ID = "project_mask_viewer_capture"
        private const val NOTIF_ID   = 1004
    }
}

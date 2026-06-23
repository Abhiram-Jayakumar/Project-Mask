package com.projectmask.project_mask

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Warms a single, long-lived [FlutterEngine] at process start and caches it under
 * [ENGINE_ID]. [MainActivity] attaches to this cached engine instead of owning
 * its own, so when the user swipes the app off the recents list the Activity is
 * destroyed but the engine — and with it the Dart isolate, the WebRTC peer
 * connection, and the signaling socket — keeps running. A foreground service
 * (ScreenCaptureService for the host, ConnectionService for the viewer) keeps the
 * process alive; together they let a connected session survive task removal until
 * the user explicitly ends it.
 */
class MaskApplication : Application() {

    companion object {
        const val ENGINE_ID = "mask_engine"
    }

    override fun onCreate() {
        super.onCreate()

        // Constructing the engine auto-initializes the Flutter loader and
        // registers GeneratedPluginRegistrant (flutter_webrtc, etc.).
        val engine = FlutterEngine(this)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault(),
        )

        // Register the platform channels on the engine itself (using the
        // application context) so they keep working while no Activity is attached.
        MaskChannels.register(this, engine.dartExecutor.binaryMessenger)

        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
    }
}

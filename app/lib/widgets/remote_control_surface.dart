import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Renders the remote (host) screen, letterboxed to its aspect ratio. View-only:
/// the app no longer injects input, so there is no touch handling here.
class RemoteControlSurface extends StatelessWidget {
  const RemoteControlSurface({super.key, required this.renderer});

  final RTCVideoRenderer renderer;

  @override
  Widget build(BuildContext context) {
    final hasVideo = renderer.srcObject != null;
    return hasVideo
        ? RTCVideoView(
            renderer,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
          )
        : const Center(
            child: Text(
              'Waiting for host screen…',
              style: TextStyle(color: Colors.white54),
            ),
          );
  }
}

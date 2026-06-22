import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Renders the remote screen and turns local touches into **normalized** (0.0–1.0)
/// coordinates relative to the actual video content — correctly accounting for
/// the letterbox bars that appear when the host's aspect ratio differs from this
/// widget's box. Touches on the black bars (outside the video) are ignored.
///
/// Tap  → emits a single `tap`.
/// Drag → emits `down`, a stream of `move`, then `up` (host builds a swipe path).
class RemoteControlSurface extends StatefulWidget {
  const RemoteControlSurface({
    super.key,
    required this.renderer,
    required this.onTouch,
  });

  final RTCVideoRenderer renderer;
  final void Function(String type, double x, double y) onTouch;

  @override
  State<RemoteControlSurface> createState() => _RemoteControlSurfaceState();
}

class _RemoteControlSurfaceState extends State<RemoteControlSurface> {
  Offset _last = Offset.zero;

  /// Map a local touch to normalized video coordinates, or null if it landed on
  /// the letterbox bars / outside the video rect.
  Offset? _normalize(Offset local, Size box) {
    final aspectRatio = widget.renderer.value.aspectRatio;
    if (aspectRatio <= 0 || box.width <= 0 || box.height <= 0) return null;

    double dispW, dispH, offX, offY;
    if (box.width / box.height > aspectRatio) {
      // Box is wider than the video → bars on left/right.
      dispH = box.height;
      dispW = dispH * aspectRatio;
      offX = (box.width - dispW) / 2;
      offY = 0;
    } else {
      // Box is taller than the video → bars on top/bottom.
      dispW = box.width;
      dispH = dispW / aspectRatio;
      offX = 0;
      offY = (box.height - dispH) / 2;
    }

    final cx = local.dx - offX;
    final cy = local.dy - offY;
    if (cx < 0 || cy < 0 || cx > dispW || cy > dispH) return null;
    return Offset(cx / dispW, cy / dispH);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = Size(constraints.maxWidth, constraints.maxHeight);
        final hasVideo = widget.renderer.srcObject != null;

        void emit(String type, Offset local) {
          final n = _normalize(local, box);
          if (n == null) return;
          _last = n;
          widget.onTouch(type, n.dx, n.dy);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => emit('tap', d.localPosition),
          onPanStart: (d) => emit('down', d.localPosition),
          onPanUpdate: (d) => emit('move', d.localPosition),
          // DragEndDetails has no position, so reuse the last known point.
          onPanEnd: (_) => widget.onTouch('up', _last.dx, _last.dy),
          child: hasVideo
              ? RTCVideoView(
                  widget.renderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                )
              : const Center(
                  child: Text(
                    'Waiting for host screen…',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
        );
      },
    );
  }
}

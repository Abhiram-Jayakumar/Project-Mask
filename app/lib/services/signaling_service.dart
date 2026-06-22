import 'package:socket_io_client/socket_io_client.dart' as io;

/// Thin wrapper around the Socket.IO connection to our signaling server.
///
/// It is intentionally "dumb": it just exposes the server's events as callbacks
/// and lets the [CallController] decide what to do. It knows nothing about WebRTC.
class SignalingService {
  io.Socket? _socket;

  /// The session id once created (host) or joined (viewer).
  String? sessionId;

  // ---- Event callbacks (wired up by the controller) ----
  void Function(bool connected)? onConnectionChange;
  void Function(String sessionId, String pin)? onSessionCreated;
  void Function(String sessionId)? onSessionJoined;
  void Function(String message)? onSessionError;
  void Function()? onViewerJoined;
  void Function(Map<String, dynamic> payload)? onSignal;
  void Function()? onPeerLeft;
  void Function(String message)? onReclaimFailed;
  void Function()? onHostDisconnected;
  void Function()? onHostReconnected;

  bool get isConnected => _socket?.connected ?? false;

  void connect(String url) {
    final socket = io.io(
      url,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .build(),
    );
    _socket = socket;

    socket.onConnect((_) => onConnectionChange?.call(true));
    socket.onDisconnect((_) => onConnectionChange?.call(false));

    socket.on('session-created', (data) {
      sessionId = data['sessionId'] as String;
      onSessionCreated?.call(sessionId!, data['pin'] as String? ?? '');
    });
    socket.on('session-joined', (data) {
      sessionId = data['sessionId'] as String;
      onSessionJoined?.call(sessionId!);
    });
    socket.on('session-error', (data) {
      onSessionError?.call(data['message'] as String? ?? 'Unknown error');
    });
    socket.on('viewer-joined', (_) => onViewerJoined?.call());
    socket.on('signal', (data) {
      onSignal?.call(Map<String, dynamic>.from(data['payload'] as Map));
    });
    socket.on('peer-left', (_) => onPeerLeft?.call());
    socket.on('reclaim-failed', (data) {
      onReclaimFailed?.call(data['message'] as String? ?? 'Reclaim failed');
    });
    socket.on('host-disconnected', (_) => onHostDisconnected?.call());
    socket.on('host-reconnected', (_) => onHostReconnected?.call());

    socket.connect();
  }

  void createSession() => _socket?.emit('create-session');

  void joinSession(String id, String pin) =>
      _socket?.emit('join-session', {'sessionId': id, 'pin': pin});

  /// Host: reclaim a previously-created session after a reconnect.
  void reclaimSession(String id, String pin) =>
      _socket?.emit('reclaim-session', {'sessionId': id, 'pin': pin});

  /// Relay an opaque WebRTC payload (offer/answer/ice) to the other peer.
  void sendSignal(Map<String, dynamic> payload) =>
      _socket?.emit('signal', {'sessionId': sessionId, 'payload': payload});

  void dispose() {
    _socket?.dispose();
    _socket = null;
  }
}

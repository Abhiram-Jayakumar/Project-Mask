# Project Mask

A free, open-source **remote screen-sharing and remote-control** app for Android —
an AnyDesk/RustDesk-style tool built entirely on free, open-source tech. One
device shares its screen; another watches it live and taps/swipes to control it,
peer-to-peer over WebRTC.

> ⚠️ **Use responsibly.** Only connect to devices you own or have explicit
> permission to access. Capture and control are consent-gated by design (system
> screen-capture dialog + a manually-enabled accessibility service, with a
> persistent "sharing" notification). Using this to access someone's device
> without consent is illegal.

## How it works

```
Host (phone)                         Signaling (Node/Socket.IO)        Viewer
  MediaProjection ──► WebRTC  ◄──── SDP offer/answer + ICE ────►  RTCVideoView
  AccessibilityService ◄── DataChannel (touch JSON) ◄────────────  GestureDetector
            video: Host ──────────► Viewer  (peer-to-peer, never via the server)
```

The signaling server only introduces the two peers and relays SDP/ICE — the
screen video and touch data flow directly between devices. See
[plan.md](plan.md) for the full architecture, design decisions, and roadmap.

## Tech stack (100% free)

Flutter · flutter_webrtc · socket_io_client · Node.js + Express + Socket.IO ·
Android MediaProjection (screen capture) · Android AccessibilityService (gesture
injection) · Google public STUN (+ optional self-host/Metered TURN).

## Repo layout

```
Project-Mask/
├── signaling-server/   Node.js + Socket.IO signaling server (+ smoke test)
├── app/                Flutter app (host + viewer, Android; web for testing)
├── docs/TURN.md        Cross-network TURN setup
└── plan.md             Master build plan, status, and roadmap
```

## Quick start

### 1. Signaling server

```bash
cd signaling-server
npm install
npm start            # listens on :3000
node test-client.js  # optional: smoke-test the handshake
```

### 2. App — host on a phone (USB)

```bash
cd app
flutter pub get
# tunnel signaling over USB so the phone reaches the PC's server:
adb reverse tcp:3000 tcp:3000
flutter run -d <phone-id>     # `flutter devices` to list ids
```

On the phone: set the server URL to `http://127.0.0.1:3000`, choose **Host**,
enable the **Project Mask Remote Control** accessibility service when prompted,
then **Start sharing**. Note the **session ID + PIN**.

### 3. App — viewer

Use a second phone (`flutter run` the same app) or, for testing, Chrome:

```bash
cd app
flutter run -d chrome --web-port=5000
```

Choose **Viewer**, enter the **session ID + PIN**, and **Connect**. You'll see the
host screen; click/drag to control it.

> The phone and the viewer must share a network path for the P2P media (same
> Wi-Fi works out of the box). For different networks, configure TURN —
> see [docs/TURN.md](docs/TURN.md).

## Building a release APK

A starter signing config is wired up via `android/key.properties` +
`android/upload-keystore.jks` (both git-ignored).

```bash
cd app
flutter build apk --release
# optional TURN baked in:
flutter build apk --release \
  --dart-define=TURN_URL=turn:your.host:3478 \
  --dart-define=TURN_USERNAME=user \
  --dart-define=TURN_CREDENTIAL=pass
```

> 🔐 The committed-out keystore here is a **starter** for local builds. For real
> distribution, generate your own keystore, set strong passwords in
> `key.properties`, and **never share or commit** the `.jks`/`key.properties`.

## Deployment

- **Server:** deploy `signaling-server/` to a free host (Render/Fly.io) — see
  [signaling-server/README.md](signaling-server/README.md).
- **App:** distribute the signed APK directly (sideload). Not aimed at the Play
  Store — using AccessibilityService for remote control violates Play policy
  (the same reason RustDesk sideloads).

## Status

Core MVP (screen share + remote control) is working and validated on-device.
Remaining work (TURN cross-network testing, more hardening, release polish) is
tracked in [plan.md](plan.md).

## License

[MIT](LICENSE)

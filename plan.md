# Project Mask — Master Build Plan

> Free, open-source remote screen-sharing **and** remote-control app for Android
> (an AnyDesk / RustDesk-style tool). 100% free stack, no paid SDKs or cloud.

**Status legend:** `[x]` done · `[~]` in progress · `[ ]` not started
**Last updated:** 2026-06-22 · **Status:** LIVE at https://project-mask.onrender.com (web app + signaling). Cross-network web↔phone confirmed. Latest changes (responsive viewer, mobile-web viewer-only fix, session history + host reclaim) are built & smoke-tested but **need a git push to redeploy**. Remaining: free TURN for cellular, optional icon/splash.

---

## 1. What We're Building

A single Android app with two roles, chosen at launch:

- **Host mode** — captures *this* phone's screen and streams it live to a remote
  viewer, and accepts remote taps/swipes injected back onto this phone.
- **Viewer mode** — shows the host's screen live, and lets the user tap/scroll on
  the video to remotely control the host device.

Devices pair using a **9-digit session ID** (like an AnyDesk number) handed out by
a signaling server. Once paired, **video and control data flow peer-to-peer** over
WebRTC — the server only introduces the two phones, it never sees the screen.

**Consent-by-design (non-negotiable):**
- Screen capture only starts after the user accepts the Android **MediaProjection**
  system dialog.
- Remote control only works after the user **manually enables** our
  AccessibilityService in system settings.
- A persistent notification is shown while sharing. No hidden icon, no silent
  capture. This is what separates a legitimate remote-desktop tool from spyware.

---

## 2. How It Works (Architecture)

```
   ┌────────────────────────┐         signaling (Socket.IO)        ┌────────────────────────┐
   │   HOST device (Flutter)│◄───────────────────────────────────►│  VIEWER device (Flutter)│
   │                        │   ▲   create/join session, SDP, ICE  │                         │
   │  MediaProjection ──► WebRTC  │                                 │   WebRTC ──► RTCVideoView│
   │  (screen capture)      │     │                                 │   (renders host screen) │
   │                        │     │                                 │                         │
   │  AccessibilityService  │     │                                 │   GestureDetector       │
   │  ◄── dispatchGesture   │     │                                 │   (captures taps/swipes)│
   └─────────▲──────────────┘     │                                 └──────────┬──────────────┘
             │                     │                                            │
             │         ┌───────────┴────────────┐                              │
             │         │  Signaling Server       │                              │
             │         │  (Node + Socket.IO)     │   relays SDP/ICE only        │
             │         └─────────────────────────┘                              │
             │                                                                  │
             └──────────────  WebRTC DataChannel (touch coords JSON)  ◄─────────┘
                              video: Host ──► Viewer (P2P, never via server)
```

**Two P2P channels over one WebRTC connection:**
1. **Media track** — H.264/VP8 video, Host → Viewer.
2. **DataChannel** — JSON touch events, Viewer → Host (low latency, ordered).

---

## 3. Technology Stack & Tools

| Layer | Tool / Library | Why | Cost |
|-------|----------------|-----|------|
| Signaling server | Node.js + Express + **Socket.IO** | Simple, reliable WS rooms | Free |
| Server hosting | **Render** free tier (or Fly.io) | Free HTTPS/WSS endpoint | Free |
| Mobile framework | **Flutter 3.44.2** (Dart 3.12) | One codebase, native APIs via channels | Free |
| P2P streaming | **flutter_webrtc** (current release) | WebRTC media + DataChannel | Free |
| Signaling client | **socket_io_client** | Talks to our server | Free |
| Screen capture | Android **MediaProjection** API (via flutter_webrtc `getDisplayMedia`) | Official capture API | Free |
| Gesture injection | Android **AccessibilityService** + `dispatchGesture()` | Only sanctioned way to tap outside own app | Free |
| Dart↔Native bridge | **MethodChannel / EventChannel** | Pass coords to native service | Free |
| NAT traversal | Google public **STUN** + free **TURN** fallback (self-host coturn / Metered free tier) | Connect across networks | Free |
| State mgmt | Flutter `ChangeNotifier` / `provider` (lightweight) | Avoid heavy deps | Free |

**Corrections to the original blueprint (already accounted for):**
- ❌ `stun:://google.com` → ✅ `stun:stun.l.google.com:19302`
- Android 14+ requires a **foreground service** typed `mediaProjection` +
  `FOREGROUND_SERVICE_MEDIA_PROJECTION` permission, else capture crashes.
- STUN alone fails on symmetric NAT (~15% of mobile networks) → TURN fallback.
- Don't pin `flutter_webrtc: ^0.12.0`; use the current release.

---

## 4. Repository Layout (target)

```
Project-Mask/
├── plan.md                     ← this file
├── signaling-server/           ← Phase 1 (DONE)
│   ├── server.js
│   ├── test-client.js
│   ├── package.json
│   └── README.md
└── app/                        ← Flutter client (Phase 2+)
    ├── lib/
    │   ├── main.dart
    │   ├── app.dart
    │   ├── screens/            home, host, viewer
    │   ├── services/           signaling_service, webrtc_service
    │   └── models/             session, touch_event
    ├── android/
    │   └── app/src/main/
    │       ├── AndroidManifest.xml          ← perms + FGS + service
    │       ├── kotlin/.../MainActivity.kt   ← MethodChannel host
    │       ├── kotlin/.../RemoteAccessibilityService.kt
    │       └── res/xml/accessibility_service_config.xml
    └── pubspec.yaml
```

---

## 5. Connection & Control Flow (sequence)

1. Host taps **Share** → app emits `create-session` → server returns `sessionId`.
2. Host shows the 9-digit ID; user reads it to the viewer.
3. Viewer enters ID → emits `join-session` → server adds viewer, tells host
   `viewer-joined`.
4. Host (offerer) creates `RTCPeerConnection`, adds the screen track + a
   DataChannel, makes an **SDP offer**, relays via `signal`.
5. Viewer sets remote desc, makes **SDP answer**, relays back; both exchange
   **ICE candidates** until connected.
6. Video appears on the viewer. Viewer touches the video → coords normalized to
   `0.0–1.0` → JSON sent over DataChannel.
7. Host receives coords → MethodChannel → AccessibilityService builds a
   `GestureDescription` → `dispatchGesture()` taps the real screen.

---

## 6. Phased Roadmap

### Phase 1 — Signaling Server ✅ (DONE)
- [x] `npm init`, install `express` + `socket.io`
- [x] Session create/join with unique 9-digit IDs
- [x] Relay SDP offer/answer + ICE between paired peers
- [x] Disconnect handling (host-leave tears down, viewer-leave frees slot)
- [x] Health endpoint for hosting platforms
- [x] Automated smoke test (`test-client.js`) — **all checks pass**
- [x] README with protocol table + Render/Fly.io deploy steps

### Phase 2 — Flutter Scaffold & WebRTC Foundation `[x]`
- [x] `flutter create` the `app/` project (Android-only platform)
- [x] Add `flutter_webrtc ^1.5.2` + `socket_io_client ^3.1.6` + `provider` to `pubspec.yaml`
- [x] Home screen: choose **Host** or **Viewer**, configurable server URL
- [x] `SignalingService` (Dart) — connect, create/join, emit/receive `signal`
- [x] `WebRtcService` (Dart) — peer connection factory, ICE config, offer/answer,
      control DataChannel, buffered ICE candidates
- [x] `CallController` orchestrator + shared `ConnectionPanel` UI (status chips + log)
- [x] Wire host=offerer / viewer=answerer handshake; viewer "test ping" over
      DataChannel to verify P2P
- [x] `flutter analyze` clean · widget test passes · **debug APK builds** (native
      WebRTC links OK)
- [x] **Checkpoint PASSED (2026-06-21):** phone (host) + Chrome web viewer reached
      ICE `connected` and the DataChannel opened, over the same Wi-Fi LAN

### Phase 3 — Host Mode (Screen Capture) `[x]`
- [x] Android manifest: `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MEDIA_PROJECTION`
      + `POST_NOTIFICATIONS` perms; declared a `mediaProjection`-typed FGS
      (verified in the merged manifest)
- [x] `ScreenCaptureService.kt` foreground service + notification channel
- [x] `MainActivity.kt` MethodChannel `project_mask/screen` (start/stop service)
      + best-effort POST_NOTIFICATIONS request
- [x] Dart `ScreenCaptureService` bridge; `startSharing()` runs FGS →
      `getDisplayMedia({video:true,audio:false})` → triggers system dialog
- [x] `WebRtcService.setLocalStream()` adds the track + renegotiates (host stays
      sole offerer → no glare); handles share-before-join and join-before-share
- [x] Host UI: Start/Stop sharing toggle
- [x] `flutter analyze` clean · debug APK builds (native Kotlin compiles)
- [x] **Checkpoint PASSED (2026-06-21):** host phone screen rendered live in the
      Chrome viewer (Android 13 device)
- [x] **Fixed:** missing `ACCESS_NETWORK_STATE` (+ `CHANGE_NETWORK_STATE`,
      `ACCESS_WIFI_STATE`) caused a native `SIGABRT` in WebRTC's NetworkMonitor —
      added to the manifest

> Android 14 note: the FGS is started *before* `getDisplayMedia`. Works on
> Android 10–13 (verified on 13). Still **verify on an Android 14+ device** since
> `getMediaProjection()` timing there is strict.

### Phase 4 — Viewer Mode (Video + Touch Capture) `[~]`
- [x] `RTCVideoRenderer` + `RTCVideoView` (objectFit contain) showing remote track
- [x] `RemoteControlSurface` widget wraps it in a `GestureDetector`
      (`onTapDown`, `onPanStart/Update/End`)
- [x] Normalize coords to `0.0–1.0` of the **actual video rect** — letterbox bars
      computed from the renderer aspect ratio; touches on bars ignored
- [x] Serialize to JSON `{"t","x","y"}` and send over the control DataChannel
- [x] `flutter analyze` clean · widget test passes
- [x] **Checkpoint PASSED (2026-06-21):** clicks/drags in the viewer reached the
      host and drove it (validated together with Phase 5)
- [ ] Polish (later): throttle high-frequency `move` events

### Phase 5 — Remote Control (AccessibilityService) `[x]`
- [x] `RemoteAccessibilityService.kt` extends `AccessibilityService` (singleton
      instance, screen-size aware)
- [x] `accessibility_service_config.xml` with `canPerformGestures="true"`
      + `strings.xml` description
- [x] Registered in manifest with `BIND_ACCESSIBILITY_SERVICE` + intent-filter
      (verified in merged manifest); `minSdk` bumped to 24
- [x] `project_mask/control` MethodChannel: gesture forward + isEnabled +
      openSettings; `CallController._injectGesture` parses DataChannel JSON →
      native (host side only; not logged to avoid flooding)
- [x] Native: denormalize → real pixels → `dispatchGesture()` — `tap` strokes and
      buffered `down`/`move`/`up` swipe paths
- [x] Host UI: "Enable remote control" prompt → opens Accessibility settings;
      auto re-checks on app resume (WidgetsBindingObserver)
- [x] `flutter analyze` clean · debug APK builds
- [x] **Checkpoint PASSED (2026-06-21):** remote taps/drags from the Chrome viewer
      actually control the host phone via `dispatchGesture()` — user-confirmed

---

## ✅ Core MVP is working end-to-end (validated on-device 2026-06-21)

Phone (Host, Android 13) shares its screen → Chrome (Viewer) renders it live →
clicking/dragging in Chrome controls the phone. Tested over USB (`adb reverse`
for signaling) + same Wi-Fi LAN (for the P2P media).

**Known open item:** video quality looked a little soft. Bitrate/degradation
tuning is now in the code (`maxVideoBitrate` 8 Mbps + `MAINTAIN_RESOLUTION` in
[config.dart](app/lib/config.dart) / [webrtc_service.dart](app/lib/services/webrtc_service.dart))
but was **not yet re-tested** — that's the first thing to check next session.

---

## 🔜 What's left to build / verify

All build work is **done** (Phases 1–8 code-complete, web hosting added). What
remains is **deployment + verification** — mostly steps only you can do (accounts):

**To get cross-network working (the current goal):**
1. **Deploy** — push the repo to GitHub, then on [render.com](https://render.com)
   New → Blueprint (uses `render.yaml`). Free, no card. Gives `https://<app>.onrender.com`
   which serves **both** the web app and signaling. (Build `./build-web.sh` first
   so `public/` is committed.)
2. **Free TURN** — sign up at ExpressTURN or Metered (no card), get URL/user/cred.
3. **Build the APK** pointed at both:
   `flutter build apk --release --dart-define=SIGNALING_URL=https://<app>.onrender.com
   --dart-define=TURN_URL=... --dart-define=TURN_USERNAME=... --dart-define=TURN_CREDENTIAL=...`
4. **Test cross-network:** open `https://<app>.onrender.com` in a browser (viewer)
   and run the APK on a phone (host) — try the phone on **mobile data**.

**Other verification (when convenient):**
5. Re-test **video quality** (drop framerate to ~15 / force H.264 if still soft).
6. **Android 14+** device check (MediaProjection FGS timing).
7. Optional polish: app **icon/splash** (needs a designed asset), `--split-per-abi`,
   throttle `move` events, remove video track + renegotiate on Stop Sharing.

---

### Phase 6 — Cross-network (public signaling + web app + TURN) `[~]`
Requirement: zero billing, works on **web AND app**, across different networks.
- [x] Add `stun:stun.l.google.com:19302` (+ extra public STUN) to ICE config
- [x] Same-Wi-Fi LAN connection proven (2026-06-21)
- [x] **Unified free deployment:** the Node server now also **serves the Flutter
      web app** from `signaling-server/public/` (one Render service = signaling +
      browser-accessible app). Health moved to `/health`; SPA fallback added.
- [x] **Web uses same-origin signaling** ([config.dart](app/lib/config.dart)
      `defaultSignalingUrl`: dart-define → web origin → local default); native
      channels `kIsWeb`-guarded so the web build never crashes (viewer fully works)
- [x] `build-web.sh` (build web → copy into `public/`); `render.yaml` blueprint;
      web app title set to "Project Mask"; root `.gitignore`
- [x] Configurable TURN via `--dart-define`; [docs/TURN.md](docs/TURN.md) updated
      to current free options (ExpressTURN 1000 GB/mo, Metered — both no card)
- [x] Verified locally: `flutter build web` ok, server serves app + assets (200)
      + `/health`, signaling smoke test still passes
- [ ] **USER STEP:** deploy to Render (free, needs GitHub+Render account) → get
      `https://<app>.onrender.com`
- [ ] **USER STEP:** sign up for free TURN (ExpressTURN/Metered) → get creds
- [ ] Build APK: `flutter build apk --release --dart-define=SIGNALING_URL=<render>
      --dart-define=TURN_URL=... --dart-define=TURN_USERNAME=... --dart-define=TURN_CREDENTIAL=...`
- [ ] **Checkpoint:** connect across different networks (e.g. phone on mobile
      data ↔ browser elsewhere)

### Phase 7 — Hardening & Security `[~]`
- [x] Session **PIN auth** — server generates a 4-digit PIN, validates on join;
      host shows ID+PIN, viewer must enter both (smoke-tested)
- [x] Auto-reconnect: Socket.IO reconnection (no duplicate sessions) +
      **ICE restart** on host when peer state → `failed`
- [x] On-host **"a viewer is connected and can control this device"** banner
- [x] Connection status chips + event log (graceful teardown via dispose)
- [~] Bitrate/resolution tuning — done in code (8 Mbps + MAINTAIN_RESOLUTION),
      **pending on-device re-test**
- [x] **Session resume:** server keeps a session for a 60s **grace period** after
      the host drops (`HOST_GRACE_MS`); host **reclaims** the same id/pin on
      reconnect; viewer gets `host-disconnected`/`host-reconnected` and re-handshakes
      (both sides `resetPeer`). Smoke-tested.
- [x] **Session history:** `SessionStore` (shared_preferences) persists viewer's
      recent sessions → one-tap rejoin; host saves its last session id/pin
- [x] **Mobile-web is viewer-only:** mobile browsers can't `getDisplayMedia`, so
      Host is disabled on mobile web (`isMobileWeb`) with guidance — fixes the
      "shares camera instead of screen" issue

### Phase 8 — Packaging & Release `[~]`
- [x] App name → "Project Mask" (launcher label)
- [x] Release signing: generated `upload-keystore.jks` + `key.properties`
      (git-ignored) + Gradle `signingConfigs`; **release APK builds & is signed
      with our key** (verified via apksigner: `CN=Project Mask`)
- [x] `flutter build apk --release` → `app-release.apk` (81.6 MB, all ABIs)
- [x] Open-source [LICENSE](LICENSE) (MIT) + top-level [README](README.md)
- [ ] App icon + splash (needs a designed asset)
- [ ] `--split-per-abi` for smaller APKs; install-test the release APK on a clean
      device; contribution guide

---

## 7. Testing Strategy

| Phase | How we verify |
|-------|---------------|
| 1 | `node test-client.js` — automated handshake/relay assertions ✅ |
| 2 | Two clients (emulators OK) reach ICE `connected`; DataChannel opens |
| 3 | Real device required (emulator MediaProjection is unreliable) |
| 4 | Log coords host-side; verify normalization across resolutions |
| 5 | **Two physical devices** — one shares, one controls |
| 6 | Switch one device to mobile data; confirm connect via STUN/TURN |

> **Hardware note:** full remote-control verification needs **two physical
> Android devices**. Emulators can validate signaling + DataChannel only.

---

## 8. Deployment

- **Signaling server:** push `signaling-server/` to GitHub → Render free web
  service (`npm install` / `npm start`; `PORT` auto-injected). WSS over the
  given HTTPS host. (Free tier sleeps when idle — first connect ~30s.)
- **App:** distribute the signed APK directly (sideload). Not aimed at Play
  Store because AccessibilityService for control violates Play policy — fine for
  an open-source sideloaded tool, same as RustDesk.

---

## 9. Security, Privacy & Legal

- Consent-gated capture + control (system dialog + manual service enable).
- Visible, persistent "sharing active" notification; easy stop.
- Add session PIN before any real-world use (Phase 7) — IDs alone are guessable.
- Intended use: controlling **your own** devices or with explicit permission.
  Using it to access someone's device without consent is illegal — don't.

---

## 10. Known Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Symmetric NAT blocks P2P | TURN relay fallback (Phase 6) |
| Android 14+ FGS rules crash capture | Declare typed FGS + perms (Phase 3) |
| AccessibilityService disabled by user | In-app prompt + deep link to settings |
| Coordinate drift across resolutions | Normalize 0–1, denormalize on host |
| Render free tier cold start | Accept ~30s wake, or move to Fly.io |
| Latency on cellular | Tune bitrate/resolution, prefer VP8/H264 hw |

---

## 11. Progress Log

- **2026-06-21** — Phase 1 complete: signaling server built, smoke-tested (all
  checks pass), documented. Plan authored.
- **2026-06-21** — Phase 2 code complete: Flutter app scaffolded (Android-only),
  signaling + WebRTC services + controller + UI built. `flutter analyze` clean,
  widget test passes, debug APK builds (native WebRTC linking verified). Only the
  on-device ICE checkpoint remains (no Android device/emulator attached yet —
  connected "devices" are Windows/Chrome/Edge).
- **2026-06-21** — Phase 3 code complete: native `ScreenCaptureService` (typed
  mediaProjection FGS) + MethodChannel in MainActivity; Dart `startSharing`/
  `stopSharing` with getDisplayMedia + renegotiation; host Start/Stop toggle.
  analyze clean, debug APK builds, merged manifest verified (FGS perm + service +
  type all present). On-device render checkpoint pending.
- **2026-06-21** — Phase 4 code complete: `RemoteControlSurface` captures
  taps/drags, normalizes to 0–1 against the real (letterbox-aware) video rect,
  sends JSON over the DataChannel via `sendTouch`. Wired into the viewer screen.
  analyze clean, widget test passes. On-device touch-log checkpoint pending.
- **2026-06-21** — Phase 5 code complete: `RemoteAccessibilityService` injects
  taps + swipe paths via `dispatchGesture`; `project_mask/control` channel wires
  DataChannel JSON → native; host UI prompts to enable Accessibility + re-checks
  on resume; minSdk→24. analyze clean, APK builds, merged manifest verified.
  **Core MVP (Phases 1–5) is now code-complete end-to-end.**
- **2026-06-21 (on-device test session)** — Ran on a real phone (M2101K7BI,
  Android 13) as Host + Chrome web viewer (added `web` platform for this).
  - **Fixed a crash:** missing `ACCESS_NETWORK_STATE` → native `SIGABRT` in
    WebRTC NetworkMonitor. Added network-state perms to the manifest.
  - **Full loop verified:** screen streams phone→Chrome and clicks/drags in
    Chrome control the phone. 🎉
  - Changed dev default server URL to `http://127.0.0.1:3000` (works for Chrome +
    USB phone via `adb reverse`).
  - **Open:** quality looked a bit soft → added 8 Mbps + `MAINTAIN_RESOLUTION`
    encoder tuning; **needs re-test next session.**
- **2026-06-22** — Built out Phases 6–8 (code-complete):
  - **Phase 7:** session **PIN auth** (server + client + UI, smoke-tested);
    **ICE-restart** reconnect on `failed` + no duplicate sessions on socket
    reconnect; host **"being controlled"** banner.
  - **Phase 6:** **configurable TURN** via `--dart-define` + [docs/TURN.md](docs/TURN.md).
  - **Phase 8:** app name "Project Mask"; **release signing** (keystore +
    key.properties + Gradle) — signed `app-release.apk` built & verified
    (`CN=Project Mask` via apksigner); MIT [LICENSE](LICENSE) + [README](README.md).
  - Verified: `flutter analyze` clean, server PIN smoke test passes, release APK
    builds (81.6 MB). Remaining is on-device verification + optional icon/splash.
  - Note: viewer now needs a **PIN** as well as the session ID when testing.
- **2026-06-22 (cross-network + web hosting)** — Goal: free, works on web AND app,
  across networks. Architecture: **one free service serves signaling AND the
  Flutter web app**.
  - Node server serves `signaling-server/public/` (the web build) + SPA fallback;
    health moved to `/health`. Web app connects to its **own origin** for
    signaling ([config.dart](app/lib/config.dart)).
  - Native MethodChannels `kIsWeb`-guarded → web build can't crash; web viewer
    fully works (web host = browser screen share, no remote-control injection).
  - Added [build-web.sh](build-web.sh), [render.yaml](render.yaml), root
    `.gitignore`; web title "Project Mask"; updated [docs/TURN.md](docs/TURN.md)
    to current free TURN (ExpressTURN 1000 GB/mo, Metered — no card).
  - Verified locally: web builds, server serves app bundle (200) + `/health`,
    signaling smoke test passes, `flutter analyze` clean.
  - **Next (user steps):** push to GitHub → deploy on Render (free) → sign up for
    free TURN → build APK with `--dart-define=SIGNALING_URL=<render>` + TURN. Then
    cross-network works for both the web app and the APK.
- **2026-06-22 (DEPLOYED + UX fixes)** — Live at **https://project-mask.onrender.com**
  (serves web app + signaling). Verified `/health` + assets. Built + installed the
  release APK on the phone with `--dart-define=SIGNALING_URL=https://project-mask.onrender.com`;
  **cross-network web-viewer ↔ phone-host confirmed working** by the user.
  - **Responsive viewer:** remote screen now in a centered **phone-shaped frame**,
    sized to the device aspect + capped height, whole page scrollable + width-capped
    (fixes desktop-browser full-width stretch). Home screen width-capped too.
  - **Fix — mobile web shared camera not screen:** mobile browsers can't
    `getDisplayMedia`; Host is now disabled on mobile web (`isMobileWeb`) with a
    note to use the app. Web on phones = viewer-only.
  - **Session history + reconnect:** `SessionStore` (shared_preferences) keeps
    viewer history (one-tap rejoin) + host's last session; server **grace period
    (60s) + reclaim** lets a dropped host resume the same id (viewer waits via
    `host-disconnected`/`host-reconnected`). Smoke test extended + passing.
  - Verified: analyze clean, server smoke test (incl. reclaim) passes, web rebuilt.
    **Not yet pushed/redeployed** — these changes need a `git push` to go live.

---

## 12. How to resume the test rig (next session)

1. **Signaling server:** `cd signaling-server && npm start` (listens on :3000).
2. **Phone over USB:** plug in, then
   `adb reverse tcp:3000 tcp:3000` (adb is at
   `~/AppData/Local/Android/Sdk/platform-tools/adb.exe`).
   Phone uses server URL `http://127.0.0.1:3000`.
3. **Run host on phone:** `cd app && flutter run -d <phone-id>` (`flutter devices`
   for the id). Accessibility stays enabled across installs.
4. **Run viewer in Chrome:** `cd app && flutter run -d chrome --web-port=5000`.
   Server URL is pre-filled to `127.0.0.1:3000`.
5. Phone must be on the **same Wi-Fi as the PC** for the P2P media (USB only
   tunnels signaling).
6. Test: phone → Host → Start sharing (note the **ID + PIN**); Chrome → Viewer →
   enter **both ID and PIN** → Connect. Watch the quality with the new tuning.

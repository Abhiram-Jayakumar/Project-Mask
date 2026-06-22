# Project Mask — Signaling Server

Lightweight WebRTC signaling server. It **never** handles video/audio — those flow
peer-to-peer over WebRTC. This server hands out session IDs (+ PINs) and relays the
SDP offer/answer + ICE candidates between a **host** (screen being shared) and a
**viewer** (the one watching and controlling).

It **also serves the Flutter web app** from `./public/` — so one free deployment
gives you both the signaling endpoint and a browser-accessible version of the app
(open the URL → use it, no install). The web app connects to its own origin for
signaling. Build it first with `../build-web.sh`.

## Run locally

```bash
npm install
npm start          # listens on :3000 (override with PORT env var)
npm run dev        # auto-restart on file changes
```

Smoke-test the handshake without any Flutter app:

```bash
node test-client.js   # spins up a fake host + viewer, asserts the full flow
```

## Socket.IO protocol

| Direction | Event | Payload | Meaning |
|-----------|-------|---------|---------|
| host → server | `create-session` | — | Ask for a new session ID |
| server → host | `session-created` | `{ sessionId, pin }` | 9-digit ID + 4-digit PIN |
| viewer → server | `join-session` | `{ sessionId, pin }` | Join (PIN must match) |
| server → viewer | `session-joined` | `{ sessionId }` | Join succeeded |
| server → viewer | `session-error` | `{ message }` | Not found / wrong PIN / full |
| server → host | `viewer-joined` | — | A viewer arrived → host should create the WebRTC **offer** |
| either → server | `signal` | `{ sessionId, payload }` | Relay SDP/ICE to the other peer |
| server → peer | `signal` | `{ payload }` | Relayed message from the other peer |
| server → peer | `peer-left` | — | The other peer disconnected |

`payload` is opaque to the server — the clients decide its shape (e.g.
`{ kind: 'offer'|'answer'|'ice', ... }`). One host + one viewer per session.

## Free deployment

**Render** (free, no credit card) — there's a `render.yaml` blueprint at the repo
root:
1. **Build the web app first:** from the repo root run `./build-web.sh` (this
   populates `signaling-server/public/`). Commit it.
2. Push the repo to GitHub.
3. render.com → New → **Blueprint** → pick the repo (uses `render.yaml`), or New →
   Web Service with root dir `signaling-server`, build `npm install`, start
   `npm start`.
4. Render injects `PORT` automatically and pings `/health`.
5. Open `https://<app>.onrender.com` in a browser to use the **web app**; use the
   same URL as the signaling server in the **Android** build:
   `flutter build apk --release --dart-define=SIGNALING_URL=https://<app>.onrender.com`.

> Note: Render's free tier sleeps after inactivity; the first connection may take
> ~30s to wake it. Fly.io's free allowance keeps a small VM warm if that matters.

## What this server intentionally does NOT do

- No TURN relaying — TURN is configured on the **clients** via `--dart-define`
  (see [../docs/TURN.md](../docs/TURN.md)).
- PIN auth gates joins, but session IDs/PINs are short — fine for personal use,
  not a substitute for real auth at scale.

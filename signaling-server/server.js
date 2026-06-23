/**
 * Project Mask — WebRTC Signaling Server
 * --------------------------------------
 * This server NEVER touches video/audio data. WebRTC streams flow peer-to-peer.
 * The server only does three things:
 *   1. Hands out unique session IDs (like an AnyDesk number).
 *   2. Puts the host and the viewer into the same "room".
 *   3. Relays signaling payloads (SDP offer/answer + ICE candidates) between them.
 *
 * Protocol (all over Socket.IO):
 *   Host:   emit "create-session"            -> recv "session-created" { sessionId }
 *   Viewer: emit "join-session" { sessionId } -> recv "session-joined"  { sessionId }
 *                                            or recv "session-error"   { message }
 *   When a viewer joins, the host receives "viewer-joined".
 *   Either peer: emit "signal" { sessionId, payload } -> the OTHER peer receives "signal" { payload }
 *   On disconnect, the remaining peer receives "peer-left".
 *
 *   Anytime access (permanent PIN, Chrome-Remote-Desktop style):
 *   Host:   emit "arm-device" { deviceId, salt, pinHash } -> recv "device-armed" { deviceId }
 *                                                          or recv "device-arm-failed" { reason }
 *           emit "disarm-device"                           -> recv "device-disarmed"
 *   Viewer: joins an armed device with the same "join-session" { sessionId: deviceId, pin };
 *           the server validates pin against the stored salted hash.
 */

const express = require('express');
const http = require('http');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const { Server } = require('socket.io');

const PORT = process.env.PORT || 3000;

// How long a session survives after the HOST drops, so the host can reconnect
// and reclaim the same ID instead of the session dying instantly.
const HOST_GRACE_MS = Number(process.env.HOST_GRACE_MS) || 60000;

// "Anytime access": after this many wrong PINs on an armed (permanent) device,
// reject joins for a cooldown so a permanent PIN can't be brute-forced.
const MAX_PIN_FAILS = Number(process.env.MAX_PIN_FAILS) || 5;
const LOCKOUT_MS = Number(process.env.LOCKOUT_MS) || 30000;

/** Salted SHA-256 of a PIN, matching the host's pin_crypto.dart. The server
 *  never sees or stores the canonical PIN — only this hash (supplied at arm
 *  time) and the viewer's plaintext attempt in transit. */
function hashPin(salt, pin) {
  return crypto.createHash('sha256').update(String(salt) + String(pin)).digest('hex');
}

const app = express();
const server = http.createServer(app);

// CORS is wide-open because the web client may be served from this same origin
// and native apps have no fixed origin. Tighten if you lock down to a domain.
const io = new Server(server, {
  cors: { origin: '*', methods: ['GET', 'POST'] },
});

// Health check (Render/Fly.io ping this). Lives at /health so "/" can serve the
// web app.
app.get('/health', (_req, res) => {
  res.json({ status: 'ok', service: 'project-mask-signaling', sessions: sessions.size });
});

// --- Serve the Flutter web app (built into ./public) -----------------------
// The same free deployment hosts both signaling AND the web app, so users can
// open the URL in a browser to use it with no install. Socket.IO handles its own
// /socket.io/ path before Express, so static serving doesn't interfere.
const publicDir = path.join(__dirname, 'public');
app.use(express.static(publicDir));
// SPA fallback so any non-API route loads index.html (if the web app is built).
// A final middleware (no path) is used instead of app.get('*') so it works on
// both Express 4 and 5 (Express 5 changed wildcard path syntax).
app.use((_req, res) => {
  const indexPath = path.join(publicDir, 'index.html');
  if (fs.existsSync(indexPath)) {
    res.sendFile(indexPath);
  } else {
    res.status(404).json({ error: 'Web app not built. Run build-web.sh.' });
  }
});

// ---------------------------------------------------------------------------
// Session bookkeeping
// ---------------------------------------------------------------------------
// sessions: Map<sessionId, { host: socketId, viewer: socketId | null }>
const sessions = new Map();

/** Generate a 9-digit session id that isn't already taken (AnyDesk-style). */
function generateSessionId() {
  let id;
  do {
    id = String(Math.floor(100000000 + Math.random() * 900000000));
  } while (sessions.has(id));
  return id;
}

/** Find which session a socket belongs to and whether it was host or viewer. */
function findSessionBySocket(socketId) {
  for (const [sessionId, peers] of sessions) {
    if (peers.host === socketId) return { sessionId, peers, role: 'host' };
    if (peers.viewer === socketId) return { sessionId, peers, role: 'viewer' };
  }
  return null;
}

/** Generate a 4-digit PIN the viewer must supply to join (defense in depth on
 *  top of the 9-digit session id). */
function generatePin() {
  return String(Math.floor(1000 + Math.random() * 9000));
}

io.on('connection', (socket) => {
  console.log(`[+] connected: ${socket.id}`);

  // --- Host opens a session ------------------------------------------------
  socket.on('create-session', () => {
    const sessionId = generateSessionId();
    const pin = generatePin();
    sessions.set(sessionId, { host: socket.id, viewer: null, pin });
    socket.join(sessionId);
    socket.emit('session-created', { sessionId, pin });
    console.log(`[session] ${sessionId} created by host ${socket.id}`);
  });

  // --- Host arms a PERMANENT device for "anytime access" -------------------
  // The session is keyed by the host's STABLE device id and validated against a
  // salted PIN hash. While armed, any viewer with the device id + PIN connects
  // with no further host taps.
  socket.on('arm-device', ({ deviceId, salt, pinHash } = {}) => {
    if (!deviceId || !salt || !pinHash) {
      socket.emit('device-arm-failed', { reason: 'invalid' });
      return;
    }
    const existing = sessions.get(deviceId);
    if (existing) {
      // A different socket claiming this id is a real COLLISION only if its PIN
      // hash differs. A MATCHING hash means it's the same device reconnecting
      // (e.g. after a Wi-Fi <-> mobile-data switch) before its old socket has
      // timed out — let it reclaim its own session and keep the same id instead
      // of being forced onto a new one.
      if (existing.host &&
          existing.host !== socket.id &&
          existing.pinHash !== pinHash) {
        socket.emit('device-arm-failed', { reason: 'id-taken' });
        console.log(`[anytime] ${deviceId} arm rejected — id used by another device`);
        return;
      }
      // Same device returning (reconnect / re-arm) — re-attach + refresh,
      // replacing any stale previous host socket.
      if (existing.graceTimer) {
        clearTimeout(existing.graceTimer);
        existing.graceTimer = null;
      }
      Object.assign(existing, {
        host: socket.id, salt, pinHash, permanent: true, armed: true, fails: 0,
        lockedUntil: 0,
      });
      socket.join(deviceId);
      socket.emit('device-armed', { deviceId });
      if (existing.viewer) {
        io.to(existing.viewer).emit('host-reconnected');
        io.to(socket.id).emit('viewer-joined'); // prompt host to re-offer
      }
      console.log(`[anytime] ${deviceId} re-armed by host ${socket.id}`);
      return;
    }
    sessions.set(deviceId, {
      host: socket.id, viewer: null, salt, pinHash,
      permanent: true, armed: true, fails: 0, lockedUntil: 0,
    });
    socket.join(deviceId);
    socket.emit('device-armed', { deviceId });
    console.log(`[anytime] ${deviceId} armed by host ${socket.id}`);
  });

  // --- Host disarms its permanent device -----------------------------------
  socket.on('disarm-device', () => {
    const found = findSessionBySocket(socket.id);
    if (!found || found.role !== 'host') return;
    const { sessionId, peers } = found;
    if (peers.viewer) io.to(peers.viewer).emit('peer-left');
    if (peers.graceTimer) clearTimeout(peers.graceTimer);
    sessions.delete(sessionId);
    socket.emit('device-disarmed', { deviceId: sessionId });
    console.log(`[anytime] ${sessionId} disarmed by host ${socket.id}`);
  });

  // --- Viewer joins an existing session ------------------------------------
  socket.on('join-session', ({ sessionId, pin } = {}) => {
    const peers = sessions.get(sessionId);
    if (!peers) {
      socket.emit('session-error', { message: 'Session not found.' });
      return;
    }
    if (peers.permanent) {
      // Anytime-access device: must be armed + online, PIN validated by hash,
      // with lockout after too many wrong attempts.
      if (!peers.armed || !peers.host) {
        socket.emit('session-error', { message: 'Device is not accepting connections.' });
        return;
      }
      if (peers.lockedUntil && Date.now() < peers.lockedUntil) {
        socket.emit('session-error', { message: 'Too many attempts — try again later.' });
        return;
      }
      if (hashPin(peers.salt, String(pin)) !== peers.pinHash) {
        peers.fails = (peers.fails || 0) + 1;
        if (peers.fails >= MAX_PIN_FAILS) {
          peers.lockedUntil = Date.now() + LOCKOUT_MS;
          peers.fails = 0;
          console.log(`[anytime] ${sessionId} locked — too many bad PINs`);
        }
        socket.emit('session-error', { message: 'Incorrect PIN.' });
        return;
      }
      peers.fails = 0;
      peers.lockedUntil = 0;
    } else if (peers.pin && String(pin) !== peers.pin) {
      socket.emit('session-error', { message: 'Incorrect PIN.' });
      console.log(`[session] ${sessionId} rejected viewer ${socket.id} (bad PIN)`);
      return;
    }
    if (peers.viewer) {
      socket.emit('session-error', { message: 'Session already has a viewer.' });
      return;
    }
    peers.viewer = socket.id;
    socket.join(sessionId);
    socket.emit('session-joined', { sessionId });
    // Tell the host a viewer arrived so it can create the WebRTC offer.
    io.to(peers.host).emit('viewer-joined');
    console.log(`[session] ${sessionId} joined by viewer ${socket.id}`);
  });

  // --- Host reconnects and reclaims its session after a drop ---------------
  socket.on('reclaim-session', ({ sessionId, pin } = {}) => {
    const peers = sessions.get(sessionId);
    if (!peers) {
      socket.emit('reclaim-failed', { message: 'Session expired.' });
      return;
    }
    if (peers.pin && String(pin) !== peers.pin) {
      socket.emit('reclaim-failed', { message: 'Incorrect PIN.' });
      return;
    }
    if (peers.host) {
      socket.emit('reclaim-failed', { message: 'Session already active.' });
      return;
    }
    // Cancel the grace timer and re-attach this socket as the host.
    if (peers.graceTimer) {
      clearTimeout(peers.graceTimer);
      peers.graceTimer = null;
    }
    peers.host = socket.id;
    socket.join(sessionId);
    // Re-use the same id + pin so the viewer can stay/rejoin seamlessly.
    socket.emit('session-created', { sessionId, pin: peers.pin });
    if (peers.viewer) {
      io.to(peers.viewer).emit('host-reconnected');
      io.to(socket.id).emit('viewer-joined'); // prompt host to re-offer
    }
    console.log(`[session] ${sessionId} reclaimed by host ${socket.id}`);
  });

  // --- Relay signaling to the other peer in the room -----------------------
  socket.on('signal', ({ sessionId, payload } = {}) => {
    const peers = sessions.get(sessionId);
    if (!peers) return;
    const targetId = socket.id === peers.host ? peers.viewer : peers.host;
    if (targetId) {
      io.to(targetId).emit('signal', { payload });
    }
  });

  // --- Cleanup on disconnect ----------------------------------------------
  socket.on('disconnect', () => {
    console.log(`[-] disconnected: ${socket.id}`);
    const found = findSessionBySocket(socket.id);
    if (!found) return;
    const { sessionId, peers, role } = found;

    if (role === 'host') {
      // Host dropped -> keep the session alive for a grace period so the host
      // can reconnect and reclaim it. Tell the viewer to wait, not give up.
      peers.host = null;
      if (peers.viewer) io.to(peers.viewer).emit('host-disconnected');
      peers.graceTimer = setTimeout(() => {
        if (peers.viewer) io.to(peers.viewer).emit('peer-left');
        sessions.delete(sessionId);
        console.log(`[session] ${sessionId} expired (host didn't return)`);
      }, HOST_GRACE_MS);
      console.log(`[session] ${sessionId} host dropped — ${HOST_GRACE_MS}ms grace`);
    } else {
      // Viewer left -> keep session open, free the viewer slot, notify host.
      peers.viewer = null;
      if (peers.host) io.to(peers.host).emit('peer-left');
      console.log(`[session] ${sessionId} viewer left (session stays open)`);
    }
  });
});

server.listen(PORT, () => {
  console.log(`Project Mask signaling server listening on :${PORT}`);
});

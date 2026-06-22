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
 */

const express = require('express');
const http = require('http');
const path = require('path');
const fs = require('fs');
const { Server } = require('socket.io');

const PORT = process.env.PORT || 3000;

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

  // --- Viewer joins an existing session ------------------------------------
  socket.on('join-session', ({ sessionId, pin } = {}) => {
    const peers = sessions.get(sessionId);
    if (!peers) {
      socket.emit('session-error', { message: 'Session not found.' });
      return;
    }
    if (peers.pin && String(pin) !== peers.pin) {
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
      // Host left -> tear down the whole session, notify the viewer.
      if (peers.viewer) io.to(peers.viewer).emit('peer-left');
      sessions.delete(sessionId);
      console.log(`[session] ${sessionId} closed (host left)`);
    } else {
      // Viewer left -> keep session open, free the viewer slot, notify host.
      peers.viewer = null;
      io.to(peers.host).emit('peer-left');
      console.log(`[session] ${sessionId} viewer left (session stays open)`);
    }
  });
});

server.listen(PORT, () => {
  console.log(`Project Mask signaling server listening on :${PORT}`);
});

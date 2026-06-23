/**
 * Smoke test for the signaling server. Spins up two Socket.IO clients (a fake
 * host and a fake viewer), runs the full handshake, and checks signal relay.
 * Run the server first (`npm start`), then `node test-client.js`.
 */
const { io } = require('socket.io-client');
const crypto = require('crypto');

const URL = process.env.SIGNAL_URL || 'http://localhost:3000';
const log = (who, ...m) => console.log(`  [${who}]`, ...m);

let failed = false;
const fail = (msg) => { failed = true; console.error('  ✗ FAIL:', msg); };

(async () => {
  const host = io(URL, { transports: ['websocket'] });
  const viewer = io(URL, { transports: ['websocket'] });

  // Socket.IO buffers outgoing emits until the connection is ready, so we can
  // emit immediately without waiting for a 'connect' event (avoids a race where
  // the event fires before its handler is registered).
  let sessionPin;
  const sessionId = await new Promise((resolve) => {
    host.on('session-created', ({ sessionId, pin }) => {
      sessionPin = pin;
      log('host', 'session created:', sessionId, 'pin:', pin);
      if (!/^\d{4}$/.test(String(pin))) fail('pin is not 4 digits');
      resolve(sessionId);
    });
    host.emit('create-session');
  });

  // Wrong PIN must be rejected before a correct join is attempted.
  await new Promise((resolve) => {
    const badPinClient = io(URL, { transports: ['websocket'] });
    badPinClient.emit('join-session', { sessionId, pin: '0000' });
    badPinClient.on('session-error', ({ message }) => {
      log('badpin', 'correctly rejected wrong PIN ✓ —', message);
      badPinClient.close();
      resolve();
    });
    badPinClient.on('session-joined', () => fail('wrong PIN was accepted'));
  });

  // Host should be told when the viewer joins.
  const hostGotViewer = new Promise((resolve) => host.on('viewer-joined', resolve));

  await new Promise((resolve) => {
    viewer.on('session-joined', ({ sessionId: id }) => {
      if (id !== sessionId) fail('viewer joined wrong session');
      log('viewer', 'joined session:', id);
      resolve();
    });
    viewer.on('session-error', ({ message }) => fail('viewer join error: ' + message));
    viewer.emit('join-session', { sessionId, pin: sessionPin });
  });

  await hostGotViewer;
  log('host', 'received viewer-joined ✓');

  // Relay test: host -> viewer
  const viewerGotSignal = new Promise((resolve) => {
    viewer.on('signal', ({ payload }) => {
      if (payload?.kind === 'offer') log('viewer', 'received relayed offer ✓');
      else fail('viewer got unexpected signal');
      resolve();
    });
  });
  host.emit('signal', { sessionId, payload: { kind: 'offer', sdp: 'fake-sdp' } });
  await viewerGotSignal;

  // Relay test: viewer -> host
  const hostGotSignal = new Promise((resolve) => {
    host.on('signal', ({ payload }) => {
      if (payload?.kind === 'answer') log('host', 'received relayed answer ✓');
      else fail('host got unexpected signal');
      resolve();
    });
  });
  viewer.emit('signal', { sessionId, payload: { kind: 'answer', sdp: 'fake-sdp' } });
  await hostGotSignal;

  // Reclaim test: host drops, the viewer is held, a new host reclaims the id.
  const viewerSawHostGone = new Promise((r) => viewer.once('host-disconnected', r));
  const viewerSawHostBack = new Promise((r) => viewer.once('host-reconnected', r));
  host.close(); // simulate the host dropping
  await viewerSawHostGone;
  log('viewer', 'saw host-disconnected (session held) ✓');

  const host2 = io(URL, { transports: ['websocket'] });
  const reclaimedId = await new Promise((resolve) => {
    host2.on('session-created', ({ sessionId: id }) => resolve(id));
    host2.on('reclaim-failed', ({ message }) => fail('reclaim failed: ' + message));
    host2.emit('reclaim-session', { sessionId, pin: sessionPin });
  });
  if (reclaimedId !== sessionId) fail('reclaimed a different session id');
  else log('host2', 'reclaimed same session ✓:', reclaimedId);
  await viewerSawHostBack;
  log('viewer', 'saw host-reconnected ✓');
  host2.close();

  // Error path: joining a bogus session.
  await new Promise((resolve) => {
    const stray = io(URL, { transports: ['websocket'] });
    stray.emit('join-session', { sessionId: '000000000' });
    stray.on('session-error', ({ message }) => {
      log('stray', 'correctly rejected bad session ✓ —', message);
      stray.close();
      resolve();
    });
  });

  // --- Anytime access: arm a permanent device + PIN-hash validation --------
  const deviceId = '987654321';
  const salt = crypto.randomBytes(8).toString('hex');
  const permPin = '135790';
  const pinHash = crypto.createHash('sha256').update(salt + permPin).digest('hex');

  const armHost = io(URL, { transports: ['websocket'] });
  await new Promise((resolve) => {
    armHost.on('device-armed', ({ deviceId: id }) => {
      if (id !== deviceId) fail('armed a different device id');
      else log('arm-host', 'device armed ✓:', id);
      resolve();
    });
    armHost.on('device-arm-failed', ({ reason }) => fail('arm failed: ' + reason));
    armHost.emit('arm-device', { deviceId, salt, pinHash });
  });

  // Wrong permanent PIN is rejected.
  await new Promise((resolve) => {
    const badPerm = io(URL, { transports: ['websocket'] });
    badPerm.emit('join-session', { sessionId: deviceId, pin: '000000' });
    badPerm.on('session-error', ({ message }) => {
      log('badperm', 'wrong permanent PIN rejected ✓ —', message);
      badPerm.close();
      resolve();
    });
    badPerm.on('session-joined', () => fail('wrong permanent PIN accepted'));
  });

  // Correct permanent PIN connects, and the armed host is notified.
  const armHostGotViewer = new Promise((r) => armHost.on('viewer-joined', r));
  const permViewer = io(URL, { transports: ['websocket'] });
  await new Promise((resolve) => {
    permViewer.on('session-joined', ({ sessionId: id }) => {
      if (id !== deviceId) fail('permanent viewer joined wrong device');
      else log('perm-viewer', 'joined armed device ✓:', id);
      resolve();
    });
    permViewer.on('session-error', ({ message }) => fail('permanent join error: ' + message));
    permViewer.emit('join-session', { sessionId: deviceId, pin: permPin });
  });
  await armHostGotViewer;
  log('arm-host', 'received viewer-joined ✓');

  // Rate-limit: a separate armed device locks out after MAX_PIN_FAILS wrong PINs.
  const lockId = '987600000';
  const lockHost = io(URL, { transports: ['websocket'] });
  await new Promise((resolve) => {
    lockHost.on('device-armed', resolve);
    lockHost.emit('arm-device', { deviceId: lockId, salt, pinHash });
  });
  await new Promise((resolve) => {
    const attacker = io(URL, { transports: ['websocket'] });
    let tries = 0;
    let locked = false;
    attacker.on('session-error', ({ message }) => {
      tries += 1;
      if (/too many/i.test(message)) locked = true;
      if (tries >= 6) {
        if (locked) log('attacker', 'locked out after repeated wrong PINs ✓');
        else fail('device was not locked out after repeated wrong PINs');
        attacker.close();
        resolve();
      } else {
        attacker.emit('join-session', { sessionId: lockId, pin: '111111' });
      }
    });
    attacker.emit('join-session', { sessionId: lockId, pin: '111111' });
  });
  permViewer.close();
  armHost.close();
  lockHost.close();

  host.close();
  viewer.close();
  console.log(failed ? '\nRESULT: FAILED' : '\nRESULT: ALL CHECKS PASSED');
  process.exit(failed ? 1 : 0);
})();

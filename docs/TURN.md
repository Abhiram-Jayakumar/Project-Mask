# TURN setup (cross-network connectivity)

WebRTC connects peer-to-peer. On the **same Wi-Fi** that works directly. Across
different networks (Wi-Fi ↔ mobile data, or behind a **symmetric NAT** common on
carrier networks), the two phones often can't reach each other directly and need
a **TURN relay** to forward the media.

STUN (already configured) is enough for most home/office NATs. TURN is the
fallback for the ~15% of networks STUN can't punch through.

The app reads TURN config from `--dart-define` at build time (no code edits):

```bash
flutter build apk --release \
  --dart-define=TURN_URL=turn:your.host:3478 \
  --dart-define=TURN_USERNAME=user \
  --dart-define=TURN_CREDENTIAL=pass
```

Pick **one** of the free options below.

---

## Option A — Free hosted TURN (easiest, no server to run)

A short free signup gets you credentials (no credit card). As of 2026:

- **ExpressTURN** ([expressturn.com](https://www.expressturn.com/)) — free plan
  with **1000 GB/month**, TCP+UDP on 3478. Most generous; good default choice.
- **Metered** ([metered.ca/stun-turn](https://www.metered.ca/stun-turn)) — free
  tier with unlimited STUN, no credit card.

Sign up, copy the TURN URL + username + credential into the build:

```bash
flutter build apk --release \
  --dart-define=TURN_URL=turn:relay.expressturn.com:3478 \
  --dart-define=TURN_USERNAME=<your-username> \
  --dart-define=TURN_CREDENTIAL=<your-credential>
```

> Note: the old no-signup "Open Relay" static credentials
> (`openrelay.metered.ca` / `openrelayproject`) have been **retired** — Open Relay
> now requires a free account + API key. Use one of the above instead.

---

## Option B — Self-host coturn (free, your own VPS)

On any small Linux VPS with a public IP (Oracle Cloud / Google Cloud free tier,
etc.):

```bash
sudo apt-get update && sudo apt-get install -y coturn
```

Edit `/etc/turnserver.conf`:

```conf
listening-port=3478
fingerprint
lt-cred-mech
user=user:pass                 # username:password
realm=your.host
# Replace with your VPS public IP:
external-ip=YOUR_PUBLIC_IP
min-port=49152
max-port=65535
log-file=/var/log/turnserver.log
```

Enable + start:

```bash
sudo sed -i 's/#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/' /etc/default/coturn
sudo systemctl enable --now coturn
```

Open UDP/TCP **3478** and UDP **49152–65535** in the VPS firewall, then build:

```bash
flutter build apk --release \
  --dart-define=TURN_URL=turn:YOUR_PUBLIC_IP:3478 \
  --dart-define=TURN_USERNAME=user \
  --dart-define=TURN_CREDENTIAL=pass
```

---

## Verifying TURN is used

Force a relay-only connection to confirm TURN works: temporarily set the peer
connection's `iceTransportPolicy` to `relay` in
[webrtc_service.dart](../app/lib/services/webrtc_service.dart) and check the
connection still establishes across two different networks. Revert to the default
(`all`) afterwards so direct paths are preferred when available.

> Security: TURN credentials in `--dart-define` are baked into the APK. For
> production, issue **short-lived TURN credentials** from the signaling server
> (coturn `use-auth-secret` / time-limited HMAC credentials) instead of static
> ones.

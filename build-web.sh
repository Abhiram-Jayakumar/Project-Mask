#!/usr/bin/env bash
# Build the Flutter web app and copy it into the signaling server's public/ dir
# so one deployment serves both the web app and the signaling endpoint.
#
# Usage:
#   ./build-web.sh
#   ./build-web.sh --dart-define=TURN_URL=turn:host:3478 \
#                  --dart-define=TURN_USERNAME=u --dart-define=TURN_CREDENTIAL=p
#
# Any extra args are passed straight to `flutter build web` (e.g. TURN config).
# The web app connects to its own origin for signaling, so no SIGNALING_URL is
# needed for the production web build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PUBLIC="$ROOT/signaling-server/public"

echo "==> flutter build web --release $*"
cd "$ROOT/app"
flutter build web --release "$@"

echo "==> copying build/web -> signaling-server/public"
rm -rf "$PUBLIC"
mkdir -p "$PUBLIC"
cp -r build/web/. "$PUBLIC/"

echo "Done. Start the server (npm start in signaling-server) and open it in a browser."

#!/usr/bin/env bash
# live-host.sh — Host view: tail the real vsock_relay log written by
# jni-offload-demo/setup.sh (the relay runs on the host and forwards CID3→CID4).
# Run setup.sh first so the relay is up and its log exists.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"

# Locate the jni-offload-demo repo: use $REPO_DIR if set, else this dir if it is
# the repo, else the sibling jni-offload-demo/ next to this script.
if [ -n "${REPO_DIR:-}" ]; then
    :
elif [ -f "$HERE/setup.sh" ] && [ -d "$HERE/host" ]; then
    REPO_DIR="$HERE"
else
    REPO_DIR="$(cd "$HERE/.." && pwd)/jni-offload-demo"
fi

LOG="$REPO_DIR/logs/relay.log"
[ -f "$LOG" ] || { echo "FATAL: $LOG not found — run jni-offload-demo/setup.sh first." >&2; exit 1; }

# Show the relay pid setup.sh recorded, if available.
RELAY_PID="?"
[ -f "$REPO_DIR/.relay.pid" ] && RELAY_PID=$(cat "$REPO_DIR/.relay.pid")

echo " [live-host] tailing $LOG  (relay pid $RELAY_PID, Ctrl-C to stop)"
echo
exec tail -F "$LOG"

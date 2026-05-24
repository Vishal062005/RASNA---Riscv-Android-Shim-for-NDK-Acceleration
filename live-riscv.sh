#!/usr/bin/env bash
# live-riscv.sh — RISC-V VM view + driver.  Runs HelloJNI on the real RISC-V64
# Cuttlefish guest and streams its JNI_SHIM logcat live in this terminal.
#
# Pairs with jni-offload-demo/setup.sh, which must have been run first (it boots
# both VMs, pushes classes.dex + libhello.so to the RISC-V guest, starts the ARM
# dispatcher, and starts the host vsock_relay).  Watch the ARM dispatcher and the
# host relay in the other two terminals via live-arm.sh and live-host.sh.
#
# This is jni-offload-demo/run.sh's core, presented as a live terminal: the
# JNI_SHIM stream shows here, while JNI_DISPATCHER and [relay] light up next door.
# Re-run as many times as you like — the other two terminals keep streaming.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"

# Locate the jni-offload-demo repo (see live-host.sh for the same logic).
if [ -n "${REPO_DIR:-}" ]; then
    :
elif [ -f "$HERE/setup.sh" ] && [ -d "$HERE/host" ]; then
    REPO_DIR="$HERE"
else
    REPO_DIR="$(cd "$HERE/.." && pwd)/jni-offload-demo"
fi

ADB="${ADB:-adb}"
ADB_ARM_SERIAL="${ADB_ARM_SERIAL:-0.0.0.0:6521}"
ADB_RISCV_SERIAL="${ADB_RISCV_SERIAL:-0.0.0.0:6520}"
ARM_ADB=("$ADB" -s "$ADB_ARM_SERIAL")
RISCV_ADB=("$ADB" -s "$ADB_RISCV_SERIAL")

log() { printf '[run] %s\n' "$*"; }
die() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

[ -d "$REPO_DIR" ] || die "jni-offload-demo not found at $REPO_DIR (set REPO_DIR=...)"

# ── Preflight: dispatcher (ARM) + relay (host) must be alive (from setup.sh) ──
DISP_PID=$("${ARM_ADB[@]}" shell "pgrep -f dispatcher" 2>/dev/null | tr -d '\r' | head -1 || true)
[ -n "$DISP_PID" ] || die "Dispatcher not running on ARM ($ADB_ARM_SERIAL). Run jni-offload-demo/setup.sh first."
log "Dispatcher ok on ARM (pid $DISP_PID)"

RELAY_PID=""
[ -f "$REPO_DIR/.relay.pid" ] && RELAY_PID=$(cat "$REPO_DIR/.relay.pid")
if [ -n "$RELAY_PID" ] && kill -0 "$RELAY_PID" 2>/dev/null; then
    log "Relay ok (pid $RELAY_PID)"
else
    die "Host relay is not running. Run jni-offload-demo/setup.sh first."
fi

"${RISCV_ADB[@]}" shell "ls /data/local/tmp/classes.dex /data/local/tmp/libhello.so" >/dev/null 2>&1 \
    || die "classes.dex or libhello.so missing on RISC-V guest ($ADB_RISCV_SERIAL). Re-run setup.sh."
log "classes.dex + libhello.so present on RISC-V guest"

# ── Stream this guest's JNI_SHIM logcat live in this terminal ──
"${RISCV_ADB[@]}" logcat -c 2>/dev/null || true
"${RISCV_ADB[@]}" logcat -s JNI_SHIM:V &
LC_PID=$!
trap 'kill "$LC_PID" 2>/dev/null || true' EXIT
sleep 1

# ── Invoke HelloJNI via app_process (ART); fall back to dalvikvm if it fails ──
# CLASSPATH points at the dex; LD_LIBRARY_PATH lets the JVM find libhello.so
# (the vsock shim) when it runs System.loadLibrary("hello").
log "Running HelloJNI on RISC-V"
APP_CMD='CLASSPATH=/data/local/tmp/classes.dex LD_LIBRARY_PATH=/data/local/tmp app_process -Djava.library.path=/data/local/tmp / HelloJNI'
printf '  adb -s %s shell %s\n' "$ADB_RISCV_SERIAL" "$APP_CMD"

"${RISCV_ADB[@]}" shell "$APP_CMD"
RC=$?
if [ "$RC" -ne 0 ]; then
    log "app_process exited $RC — trying dalvikvm fallback"
    DALVIK_CMD='CLASSPATH=/data/local/tmp/classes.dex LD_LIBRARY_PATH=/data/local/tmp dalvikvm -Djava.library.path=/data/local/tmp HelloJNI'
    "${RISCV_ADB[@]}" shell "$DALVIK_CMD"
    RC=$?
fi

sleep 1   # let the JNI_SHIM logcat finish draining to this terminal
printf '\n'
log "app_process exited rc=$RC"

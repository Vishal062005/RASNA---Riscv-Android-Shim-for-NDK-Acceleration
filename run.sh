#!/usr/bin/env bash
# run.sh — Execute HelloJNI on the RISC-V64 Cuttlefish guest and collect logs
# from all three hops (RISC-V app/shim, host relay, ARM dispatcher).
#
# Requires ./setup.sh to have been run first (dispatcher + relay must be up).
#
# Environment overrides (must match what setup.sh used):
#   ADB_ARM_SERIAL    adb serial for the ARM64 guest    (default: 0.0.0.0:6521)
#   ADB_RISCV_SERIAL  adb serial for the RISC-V guest   (default: 0.0.0.0:6520)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
LOGS="$REPO_DIR/logs"
mkdir -p "$LOGS"

ADB_ARM_SERIAL="${ADB_ARM_SERIAL:-0.0.0.0:6521}"
ADB_RISCV_SERIAL="${ADB_RISCV_SERIAL:-0.0.0.0:6520}"
ARM_ADB=(adb -s "$ADB_ARM_SERIAL")
RISCV_ADB=(adb -s "$ADB_RISCV_SERIAL")

log() { printf '[run] %s\n' "$*"; }
die() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

# ──────────────────────────────────────────────────────────────────────────────
# Preflight: dispatcher + relay must be alive.
# ──────────────────────────────────────────────────────────────────────────────
DISP_PID=$("${ARM_ADB[@]}" shell "pgrep -f dispatcher" 2>/dev/null | tr -d '\r' | head -1 || true)
if [ -z "$DISP_PID" ]; then
    log "Dispatcher not running on ARM — restarting"
    "${ARM_ADB[@]}" shell "nohup env LD_LIBRARY_PATH=/data/local/tmp /data/local/tmp/dispatcher > /data/local/tmp/dispatcher.log 2>&1 &"
    sleep 1
    DISP_PID=$("${ARM_ADB[@]}" shell "pgrep -f dispatcher" 2>/dev/null | tr -d '\r' | head -1 || true)
    [ -n "$DISP_PID" ] || die "Dispatcher failed to start. Re-run ./setup.sh."
fi
log "Dispatcher ok on ARM (pid $DISP_PID)"

RELAY_PID=""
[ -f "$REPO_DIR/.relay.pid" ] && RELAY_PID=$(cat "$REPO_DIR/.relay.pid")
if [ -n "$RELAY_PID" ] && kill -0 "$RELAY_PID" 2>/dev/null; then
    log "Relay ok (pid $RELAY_PID)"
else
    die "Host relay is not running. Run ./setup.sh first."
fi

# Verify pushed files are still on the RISC-V guest.
"${RISCV_ADB[@]}" shell "ls /data/local/tmp/classes.dex /data/local/tmp/libhello.so" >/dev/null \
    || die "classes.dex or libhello.so missing on RISC-V guest. Re-run ./setup.sh."

# ──────────────────────────────────────────────────────────────────────────────
# Clear old per-run logs and start logcat collectors.
# ──────────────────────────────────────────────────────────────────────────────
: > "$LOGS/riscv_logcat.log"
: > "$LOGS/arm_logcat.log"
: > "$LOGS/riscv_stdout.log"
# The relay prints its own "──── new session ───" separator on each accept,
# so we no longer inject a run marker here (it would duplicate that line).

"${ARM_ADB[@]}"   shell logcat -c 2>/dev/null || true
"${RISCV_ADB[@]}" shell logcat -c 2>/dev/null || true

"${ARM_ADB[@]}"   logcat -s JNI_DISPATCHER:V > "$LOGS/arm_logcat.log"   2>&1 &
ARM_LC_PID=$!
"${RISCV_ADB[@]}" logcat -s JNI_SHIM:V       > "$LOGS/riscv_logcat.log" 2>&1 &
RISCV_LC_PID=$!
trap 'kill $ARM_LC_PID $RISCV_LC_PID 2>/dev/null || true' EXIT
sleep 1

# ──────────────────────────────────────────────────────────────────────────────
# Invoke HelloJNI on the RISC-V guest via app_process (ART), falling back to
# dalvikvm if app_process fails. CLASSPATH points at the dex; LD_LIBRARY_PATH
# lets the JVM find libhello.so when it executes System.loadLibrary("hello").
# ──────────────────────────────────────────────────────────────────────────────
log "Running HelloJNI on RISC-V"
APP_CMD='CLASSPATH=/data/local/tmp/classes.dex LD_LIBRARY_PATH=/data/local/tmp app_process -Djava.library.path=/data/local/tmp / HelloJNI'

set +e
"${RISCV_ADB[@]}" shell "$APP_CMD" > "$LOGS/riscv_stdout.log" 2>&1
RC=$?
set -e

if [ $RC -ne 0 ]; then
    log "app_process exited $RC — trying dalvikvm fallback"
    DALVIK_CMD='CLASSPATH=/data/local/tmp/classes.dex LD_LIBRARY_PATH=/data/local/tmp dalvikvm -Djava.library.path=/data/local/tmp HelloJNI'
    set +e
    "${RISCV_ADB[@]}" shell "$DALVIK_CMD" >> "$LOGS/riscv_stdout.log" 2>&1
    RC=$?
    set -e
fi
echo "app_process_rc=$RC" >> "$LOGS/riscv_stdout.log"

sleep 2  # let logcat drain
"${ARM_ADB[@]}" pull /data/local/tmp/dispatcher.log "$LOGS/arm_dispatcher.log" 2>/dev/null || true

# ──────────────────────────────────────────────────────────────────────────────
# Print collected logs.
# ──────────────────────────────────────────────────────────────────────────────
section() { printf '\n════════════════════════════════════════\n  %s\n════════════════════════════════════════\n' "$1"; }
section "Host relay log (tail)";     tail -20 "$LOGS/relay.log"
section "ARM dispatcher logcat";     tail -20 "$LOGS/arm_logcat.log"
section "RISC-V shim logcat";        tail -20 "$LOGS/riscv_logcat.log"
section "RISC-V stdout";             cat        "$LOGS/riscv_stdout.log"

# ──────────────────────────────────────────────────────────────────────────────
# Success criteria.
# ──────────────────────────────────────────────────────────────────────────────
PASS=1
check() {
    local label="$1" file="$2" pattern="$3"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        echo "  PASS  $label"
    else
        echo "  FAIL  $label"
        PASS=0
    fi
}

echo
echo "=== Success criteria ==="
check "Relay saw INVOKE frame"        "$LOGS/relay.log"        "Java_HelloJNI_sayHello"
check "Relay saw reply frame"         "$LOGS/relay.log"        "REPLY"
check "ARM dispatcher dlopen'd lib"   "$LOGS/arm_logcat.log"   "dlopen"
check "ARM captured Hello World"      "$LOGS/arm_logcat.log"   "Hello World"
check "RISC-V shim got OK reply"      "$LOGS/riscv_logcat.log" "RECV REPLY"
check "RISC-V app exited cleanly"     "$LOGS/riscv_stdout.log" "app_process_rc=0"

echo
[ $PASS -eq 1 ] && echo "ALL CHECKS PASSED" || { echo "SOME CHECKS FAILED — review logs above"; exit 1; }

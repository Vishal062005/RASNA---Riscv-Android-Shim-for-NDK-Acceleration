#!/usr/bin/env bash
# setup.sh — Build and deploy the heterogeneous-ISA JNI offloading demo.
#
# Host-side steps (run on the Linux host where Cuttlefish is installed):
#   1. Build (or reuse pre-built) artifacts:
#        - host/vsock_relay            (x86_64 host binary)
#        - arm/dispatcher              (aarch64 Android executable)
#        - arm/libhello_arm.so         (aarch64 Android shared library)
#        - riscv/libhello.so           (riscv64 Android shared library)
#        - java/classes.dex            (ART-loadable DEX of HelloJNI)
#   2. Root both Cuttlefish guests and put SELinux in permissive mode so the
#      shell domain may open AF_VSOCK sockets.
#   3. Push the ARM artifacts to /data/local/tmp on the ARM64 guest and start
#      the dispatcher.
#   4. Push the RISC-V artifacts to /data/local/tmp on the RISC-V64 guest.
#   5. Launch the host-side vsock_relay.
#
# After setup.sh completes successfully, run ./run.sh to execute the demo.
#
# Required tools on the host:
#   - bash, gcc, javac        (always)
#   - Android NDK r27+        (only if rebuilding from source — set
#                              $ANDROID_NDK_HOME; otherwise the pre-built
#                              binaries shipped in this repo are used)
#   - Android SDK build-tools (provides d8; only if rebuilding classes.dex)
#   - adb                     (in $PATH)
#
# Environment overrides (all optional):
#   ADB_ARM_SERIAL    adb serial for the ARM64 guest    (default: 0.0.0.0:6521)
#   ADB_RISCV_SERIAL  adb serial for the RISC-V guest   (default: 0.0.0.0:6520)
#   EXPECTED_ARM_CID  expected vsock CID of ARM guest   (default: 4)
#   EXPECTED_RISCV_CID expected vsock CID of RISC-V     (default: 3)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
LOGS="$REPO_DIR/logs"
mkdir -p "$LOGS"

ADB_ARM_SERIAL="${ADB_ARM_SERIAL:-0.0.0.0:6521}"
ADB_RISCV_SERIAL="${ADB_RISCV_SERIAL:-0.0.0.0:6520}"
EXPECTED_ARM_CID="${EXPECTED_ARM_CID:-4}"
EXPECTED_RISCV_CID="${EXPECTED_RISCV_CID:-3}"

ARM_ADB=(adb -s "$ADB_ARM_SERIAL")
RISCV_ADB=(adb -s "$ADB_RISCV_SERIAL")

log()  { printf '[setup] %s\n' "$*"; }
die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

# ──────────────────────────────────────────────────────────────────────────────
# 1. Build artifacts (or skip if pre-built binaries are already present).
# ──────────────────────────────────────────────────────────────────────────────
PREBUILT=(
    "$REPO_DIR/host/vsock_relay"
    "$REPO_DIR/arm/dispatcher"
    "$REPO_DIR/arm/libhello_arm.so"
    "$REPO_DIR/riscv/libhello.so"
    "$REPO_DIR/java/classes.dex"
)

BUILD=1
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    log "ANDROID_NDK_HOME is not set — checking for pre-built artifacts"
    MISSING=""
    for f in "${PREBUILT[@]}"; do
        [ -f "$f" ] || MISSING="$MISSING\n  - $f"
    done
    if [ -n "$MISSING" ]; then
        die "Cannot build (NDK absent) and pre-built artifacts are missing:$(printf '%b' "$MISSING")

Set ANDROID_NDK_HOME to rebuild, or ship pre-built binaries with the repo."
    fi
    log "All pre-built artifacts present — skipping build"
    BUILD=0
fi

if [ "$BUILD" -eq 1 ]; then
    NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
    NDK_SYSROOT="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
    AARCH64_CC="$NDK_BIN/aarch64-linux-android34-clang"
    RISCV64_CC="$NDK_BIN/riscv64-linux-android35-clang"
    [ -x "$AARCH64_CC" ] || die "aarch64 clang not found at $AARCH64_CC (need NDK r27+)"
    [ -x "$RISCV64_CC" ] || die "riscv64 clang not found at $RISCV64_CC (need NDK r27+ with riscv64 support)"

    D8=""
    for c in \
        "${ANDROID_HOME:-$HOME/Android/Sdk}/build-tools/36.0.0/d8" \
        "${ANDROID_HOME:-$HOME/Android/Sdk}/build-tools/35.0.0/d8" \
        $(find "${ANDROID_HOME:-$HOME/Android/Sdk}/build-tools" -name d8 2>/dev/null | sort -V | tail -1); do
        [ -x "$c" ] && D8="$c" && break
    done
    [ -n "$D8" ] || die "d8 not found. Install Android SDK build-tools (any version ≥ 28)."

    log "Toolchain:"
    log "  AARCH64_CC = $AARCH64_CC"
    log "  RISCV64_CC = $RISCV64_CC"
    log "  D8         = $D8"

    log "Building host vsock_relay"
    gcc -O2 -Wall -Wextra -I"$REPO_DIR" \
        -o "$REPO_DIR/host/vsock_relay" "$REPO_DIR/host/vsock_relay.c"

    log "Building ARM dispatcher (aarch64 Android)"
    "$AARCH64_CC" -O2 -Wall -fPIE -pie --sysroot="$NDK_SYSROOT" -I"$REPO_DIR" \
        -o "$REPO_DIR/arm/dispatcher" "$REPO_DIR/arm/dispatcher.c" -ldl -llog

    log "Building libhello_arm.so (aarch64 Android)"
    "$AARCH64_CC" -O2 -Wall -fPIC -shared --sysroot="$NDK_SYSROOT" -I"$REPO_DIR/java" \
        -o "$REPO_DIR/arm/libhello_arm.so" "$REPO_DIR/java/HelloJNI.c"

    log "Building libhello.so (riscv64 Android shim)"
    "$RISCV64_CC" -O2 -Wall -fPIC -shared --sysroot="$NDK_SYSROOT" -I"$REPO_DIR" \
        -o "$REPO_DIR/riscv/libhello.so" "$REPO_DIR/riscv/libhello_shim.c" -llog -ldl

    log "Compiling HelloJNI.java"
    javac -d "$REPO_DIR/java" "$REPO_DIR/java/HelloJNI.java"

    log "Dexing HelloJNI.class → classes.dex"
    "$D8" --output "$REPO_DIR/java" "$REPO_DIR/java/HelloJNI.class"
    [ -f "$REPO_DIR/java/classes.dex" ] || die "d8 did not produce classes.dex"

    log "Build complete."
fi

# ──────────────────────────────────────────────────────────────────────────────
# 2. Sanity-check VMs and their VSOCK CIDs.
# ──────────────────────────────────────────────────────────────────────────────
command -v adb >/dev/null || die "adb not found in PATH"

adb devices | grep -q "^$ADB_ARM_SERIAL"   || die "ARM64 guest ($ADB_ARM_SERIAL) not visible in 'adb devices'. Is the VM running?"
adb devices | grep -q "^$ADB_RISCV_SERIAL" || die "RISC-V guest ($ADB_RISCV_SERIAL) not visible in 'adb devices'. Is the VM running?"
log "Both guests visible: ARM=$ADB_ARM_SERIAL  RISC-V=$ADB_RISCV_SERIAL"

# ──────────────────────────────────────────────────────────────────────────────
# 3. Root guests + disable SELinux enforcement (vsock denied to shell domain).
# ──────────────────────────────────────────────────────────────────────────────
for label in ARM RISC-V; do
    if [ "$label" = "ARM" ]; then SERIAL="$ADB_ARM_SERIAL"; else SERIAL="$ADB_RISCV_SERIAL"; fi
    log "Rooting $label guest and setting SELinux permissive"
    adb -s "$SERIAL" root >/dev/null 2>&1 || die "adb root failed on $label — userdebug build required"
    sleep 2
    adb -s "$SERIAL" wait-for-device
    adb -s "$SERIAL" shell setenforce 0
    adb -s "$SERIAL" shell chmod 666 /dev/vsock 2>/dev/null || true
    MODE=$(adb -s "$SERIAL" shell getenforce | tr -d '\r')
    log "  $label SELinux: $MODE"
    [ "$MODE" = "Permissive" ] || die "$label not Permissive after setenforce 0"
done

# ──────────────────────────────────────────────────────────────────────────────
# 4. Push ARM artifacts and start the dispatcher.
# ──────────────────────────────────────────────────────────────────────────────
STALE=$("${ARM_ADB[@]}" shell "pgrep -f dispatcher" 2>/dev/null | tr -d '\r' || true)
if [ -n "$STALE" ]; then
    log "Killing stale dispatcher (pids: $STALE)"
    "${ARM_ADB[@]}" shell "kill $STALE" 2>/dev/null || true
    sleep 1
fi

log "Pushing dispatcher + libhello_arm.so to ARM guest"
"${ARM_ADB[@]}" push "$REPO_DIR/arm/dispatcher"      /data/local/tmp/dispatcher       >/dev/null
"${ARM_ADB[@]}" push "$REPO_DIR/arm/libhello_arm.so" /data/local/tmp/libhello_arm.so  >/dev/null
"${ARM_ADB[@]}" shell chmod 755 /data/local/tmp/dispatcher

log "Starting dispatcher on ARM guest"
"${ARM_ADB[@]}" shell "nohup env LD_LIBRARY_PATH=/data/local/tmp /data/local/tmp/dispatcher > /data/local/tmp/dispatcher.log 2>&1 &"
sleep 1
DISP_PID=$("${ARM_ADB[@]}" shell "pgrep -f dispatcher" 2>/dev/null | tr -d '\r' | head -1 || true)
[ -n "$DISP_PID" ] || die "Dispatcher did not start. Check: adb -s $ADB_ARM_SERIAL shell cat /data/local/tmp/dispatcher.log"
log "Dispatcher running on ARM (pid $DISP_PID)"

# ──────────────────────────────────────────────────────────────────────────────
# 5. Push RISC-V artifacts.
# ──────────────────────────────────────────────────────────────────────────────
log "Pushing libhello.so + classes.dex to RISC-V guest"
"${RISCV_ADB[@]}" push "$REPO_DIR/riscv/libhello.so" /data/local/tmp/libhello.so >/dev/null
"${RISCV_ADB[@]}" push "$REPO_DIR/java/classes.dex"  /data/local/tmp/classes.dex >/dev/null

# ──────────────────────────────────────────────────────────────────────────────
# 6. Start host vsock_relay.
# ──────────────────────────────────────────────────────────────────────────────
STALE_RELAY=$(pgrep -f "$REPO_DIR/host/vsock_relay" 2>/dev/null || true)
if [ -n "$STALE_RELAY" ]; then
    log "Killing stale relay (pids: $STALE_RELAY)"
    # shellcheck disable=SC2086
    kill $STALE_RELAY 2>/dev/null || true
    sleep 1
fi

log "Starting host vsock_relay"
"$REPO_DIR/host/vsock_relay" > "$LOGS/relay.log" 2>&1 &
RELAY_PID=$!
sleep 1
kill -0 "$RELAY_PID" 2>/dev/null || die "vsock_relay exited immediately — check $LOGS/relay.log"
log "Relay running (pid $RELAY_PID) → $LOGS/relay.log"

echo "$RELAY_PID" > "$REPO_DIR/.relay.pid"
echo "$DISP_PID"  > "$REPO_DIR/.dispatcher.pid"

cat <<EOF

Setup complete.

  ARM dispatcher pid : $DISP_PID  (on guest $ADB_ARM_SERIAL)
  Host relay pid     : $RELAY_PID (log: $LOGS/relay.log)

Run ./run.sh to execute HelloJNI on the RISC-V guest.
EOF

#!/usr/bin/env bash
# live-arm.sh — ARM VM view: stream the real JNI_DISPATCHER logcat from the
# ARM64 Cuttlefish guest.  Pairs with jni-offload-demo/setup.sh, which must have
# been run first to boot the VMs and start the dispatcher on the ARM guest.
#
# The dispatcher's buffered history shows immediately, then new RECV INVOKE / dlopen / SEND REPLY lines
# stream in each time live-riscv.sh fires a call.
set -u

ADB="${ADB:-adb}"
ADB_ARM_SERIAL="${ADB_ARM_SERIAL:-0.0.0.0:6521}"

echo " [live-arm]  ARM VM — JNI_DISPATCHER logcat  (adb $ADB_ARM_SERIAL)"
echo

# -s JNI_DISPATCHER:V == silence everything, show JNI_DISPATCHER at Verbose.
exec "$ADB" -s "$ADB_ARM_SERIAL" logcat -s JNI_DISPATCHER:V

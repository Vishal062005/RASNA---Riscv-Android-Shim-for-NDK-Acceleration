# Heterogeneous-ISA JNI Offloading Demo

A reproducible proof-of-concept that transparently executes a Java Native
Interface (JNI) call on a CPU of a **different instruction-set architecture**
than the one running the JVM. A `HelloJNI.sayHello()` invocation on a riscv64
Android virtual device is forwarded over `AF_VSOCK` to an ARM64 Android virtual
device, where the real native code runs, and the captured result is returned
to the original riscv process — all without modifying the Java application.

## Overview

A textbook Java program (`HelloJNI.java`) calls a native method through
`System.loadLibrary("hello")`. The library it loads on the riscv guest is
**not** the implementation of the native method — it is a *shim* that
serialises the call (library name, symbol name, JNI signature) onto a vsock
stream. A relay on the Linux host forwards the request to an ARM64 guest,
where a dispatcher process performs the actual `dlopen` + `dlsym` on the
genuine ARM-compiled `libhello_arm.so`, invokes the function, captures its
standard output, and replies. The shim hands the captured bytes back to the
JVM as the method's return value.

The Java code is unmodified between an ordinary in-process JNI run and this
cross-ISA setup; the redirection happens entirely inside the shim that the
JVM dynamically loads. This makes the demo a minimal but complete example of
heterogeneous-ISA function offloading using only stock Android, the standard
JNI ABI, and Linux AF_VSOCK.

## Architecture

```mermaid
flowchart LR
    subgraph RV["riscv64 Cuttlefish Guest"]
        APP["HelloJNI.java<br/>(app_process / ART)"]
        SHIM["libhello.so<br/>(JNI shim)"]
        APP -- "System.loadLibrary + sayHello()" --> SHIM
    end

    subgraph HOST["Linux Host"]
        RELAY["vsock_relay<br/>(AF_VSOCK :9999)"]
    end

    subgraph ARM["ARM64 Cuttlefish Guest"]
        DISP["dispatcher<br/>(AF_VSOCK :9999)"]
        LIB["libhello_arm.so<br/>(real native code)"]
        DISP -- "dlopen + dlsym + invoke" --> LIB
    end

    SHIM -- "VSOCK<br/>req (lib,sym,sig)" --> RELAY
    RELAY -- "VSOCK<br/>forward" --> DISP
    DISP -- "VSOCK<br/>reply (captured stdout)" --> RELAY
    RELAY -- "VSOCK<br/>return bytes" --> SHIM
```

The wire protocol (`proto/wire.h`) is a small framed format: a fixed header
(`magic | version | req_id | op | flags`), three length-prefixed strings
(`lib`, `sym`, `sig`), and a length-prefixed argument blob. Replies carry
`req_id | status | retdesc | ret_len + payload`. v1 only supports native
functions that do **not** dereference `JNIEnv*` or `jobject` — `sayHello()`
just calls `printf`, so passing `NULL` for both is safe.

## Repository Layout

```
.
├── README.md                  This file
├── .gitignore                 Excludes build artifacts and logs
├── setup.sh                   Builds, deploys, and starts the dispatcher + relay
├── run.sh                     Executes HelloJNI on riscv and collects logs
├── host/
│   └── vsock_relay.c          Host-side AF_VSOCK relay (forwards CID 3 → CID 4)
├── arm/
│   ├── dispatcher.c           ARM64 dispatcher: accepts requests, dlopens libs,
│   │                          invokes symbols, captures stdout, replies
│   └── libhello_arm.so        Rebuildable: ARM64 implementation of
│                              Java_HelloJNI_sayHello (built by setup.sh)
├── riscv/
│   ├── libhello_shim.c        riscv shim: provides Java_HelloJNI_sayHello,
│   │                          which actually forwards over vsock
│   └── libhello.so            Rebuildable: riscv shim loaded by the JVM
│                              (built by setup.sh)
├── java/
│   ├── HelloJNI.java          Java entry point (unmodified textbook JNI demo)
│   ├── HelloJNI.c             Reference native implementation (also baked
│   │                          into libhello_arm.so for the ARM side)
│   ├── HelloJNI.h             JNI header
│   └── classes.dex            Rebuildable: ART-loadable DEX (built by setup.sh)
├── proto/
│   └── wire.h                 Shared wire-protocol header
└── .github/workflows/ci.yml   CI: structure + shellcheck + C syntax checks
```

`*.so`, `dispatcher`, `vsock_relay`, `classes.dex`, and `*.class` are
**rebuildable artifacts** produced by `setup.sh` (see *Building the Demo*
below). They are included in the repository as a checked-in cache so a
freshly-cloned tree contains a complete, runnable demo; the build pipeline
regenerates them deterministically from the source in this repository.

## Prerequisites

The demo targets **Ubuntu 22.04 LTS or later** on an x86_64 host with KVM
enabled (Intel VT-x or AMD-V). Every other dependency is installed by the
steps that follow. Start from a clean machine with only the operating system
installed.

Install the base toolchain — Git, adb, KVM/QEMU, and the C/C++ build tools:

```bash
sudo apt update && sudo apt install -y \
    git curl unzip wget build-essential clang make \
    qemu-kvm bridge-utils \
    android-sdk-platform-tools-common adb
```

Verify the install:

```bash
git --version
adb --version
kvm-ok            # "KVM acceleration can be used"
```

If `kvm-ok` is not present, install it with `sudo apt install -y cpu-checker`
and rerun.

## Installing the Android NDK

The Android NDK provides the cross-compilers used to build the ARM64 and
riscv64 native components in this repository. Download the latest NDK
release as a `.zip` from either of:

- <https://github.com/android/ndk/releases>
- <https://developer.android.com/ndk/downloads>

Either source publishes the same artifact. Save the file to `$HOME` (e.g.
`$HOME/android-ndk-r27c-linux.zip`), then unpack it and export the toolchain
paths:

```bash
cd $HOME
unzip android-ndk-*.zip -d $HOME
export ANDROID_NDK_HOME=$HOME/android-ndk-<version>
export PATH=$ANDROID_NDK_HOME:$PATH
```

Replace `<version>` with the directory name produced by `unzip` (e.g.
`android-ndk-r27c`). Make the two `export` lines permanent by appending them
to your shell startup file:

```bash
cat >> ~/.bashrc <<'EOF'
export ANDROID_NDK_HOME=$HOME/android-ndk-<version>
export PATH=$ANDROID_NDK_HOME:$PATH
EOF
source ~/.bashrc
```

Adjust the `<version>` string to match the file you downloaded. Confirm the
NDK is reachable:

```bash
ls $ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android34-clang
ls $ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/riscv64-linux-android35-clang
```

Both binaries must exist. The riscv cross-compiler is present only in NDK
r27 and later, so use a recent release.

## Installing Android Cuttlefish

[Cuttlefish](https://source.android.com/docs/devices/cuttlefish) is Google's
official virtual-device platform for running full Android system images on
Linux under KVM. It is built from source on the host and exposes each guest
over `adb`, `vsock`, and a WebRTC console.

**Step 1 — Verify virtualization support.** KVM must be enabled in BIOS/UEFI
and visible to the host kernel:

```bash
grep -cE 'vmx|svm' /proc/cpuinfo
```

This must return a non-zero value. If it returns `0`, enable VT-x (Intel) or
AMD-V (AMD) in BIOS/UEFI and re-check.

**Step 2 — Install Cuttlefish build dependencies:**

```bash
sudo apt update
sudo apt install -y \
    git devscripts equivs config-package-dev debhelper-compat \
    golang curl
```

**Step 3 — Build and install the Cuttlefish host packages:**

```bash
git clone https://github.com/google/android-cuttlefish
cd android-cuttlefish
tools/buildutils/build_packages.sh
sudo dpkg -i ./cuttlefish-base_*_*64.deb || sudo apt-get install -f
sudo dpkg -i ./cuttlefish-user_*_*64.deb || sudo apt-get install -f
sudo usermod -aG kvm,cvdnetwork,render $USER
sudo reboot
```

> **NOTE — RAM-shortage workaround.** `tools/buildutils/build_packages.sh`
> is RAM-heavy (peak ~16–20 GB) and may OOM-kill on smaller machines. On
> such systems, build each Debian package individually instead. From inside
> each of the `base/`, `frontend/`, and `user/` package folders run:
>
> ```bash
> debuild -i -us -uc -b
> ```
>
> Then `sudo dpkg -i` the resulting `.deb` files in the same order
> (`base` → `user` → `frontend`).

After the reboot, confirm group membership took effect:

```bash
id $USER     # must list kvm, cvdnetwork, render
```

**Step 4 — Download Cuttlefish images.** Cuttlefish needs two artifacts per
target ISA: the AOSP system image archive and the Cuttlefish host package
archive. Obtain them for the **riscv64** and **ARM64** Android targets
from <http://ci.android.com/>:

1. Pick a recent successful build of `aosp-main` (or the most recent
   release branch you want to track).
2. From the **Artifacts** section of that build, download:
   - `cvd-host_package.tar.gz` — host-side tooling (`launch_cvd`, `cvd`,
     `adb`, etc.)
   - `aosp_cf_arm64_only_phone-img-xxxxxxx.zip` — ARM64 system image
   - `aosp_cf_riscv64_phone-img-xxxxxxx.zip` — riscv64 system image
3. Decompress each archive into its own per-ISA directory. The directory
   layout below is what the launch commands in the next section assume:

```bash
mkdir -p ~/img_files/arm ~/img_files/riscv

# riscv image set
cd ~/img_files/riscv
unzip ~/Downloads/aosp_cf_riscv64_phone-img-*.zip
tar xf ~/Downloads/cvd-host_package.tar.gz     # extracts bin/, etc/, lib64/, ...

# ARM image set
cd ~/img_files/arm
unzip ~/Downloads/aosp_cf_arm64_only_phone-img-*.zip
tar xf ~/Downloads/cvd-host_package.tar.gz
```

Use the host package from the same build number as the matching image
archive. As an alternative to ci.android.com you may follow the official
documentation at
<https://source.android.com/docs/devices/cuttlefish/get-started>.

## Creating and Launching riscv64 and ARM64 Virtual Devices

Each guest is launched from inside its own extracted Cuttlefish host package
directory (the directory that contains `bin/launch_cvd`), with its system
image files placed alongside in the same directory. The two VMs run as
separate Cuttlefish instances using `CUTTLEFISH_INSTANCE=1` for the riscv
guest and `CUTTLEFISH_INSTANCE=2` for the ARM guest, so they coexist on the
same host without colliding over ports or VSOCK CIDs.

**On the host — launch the riscv64 guest:**

```bash
cd /path/to/img_files/riscv
HOME=$(pwd) \
PWD=/path/to/img_files/riscv \
CUTTLEFISH_INSTANCE=1 \
./bin/launch_cvd \
    --daemon \
    --config=phone \
    --vm_manager=qemu_cli
```

**On the host — launch the ARM64 guest:**

```bash
cd /path/to/img_files/arm
HOME=$(pwd) \
PWD=/path/to/img_files/arm \
CUTTLEFISH_INSTANCE=2 \
./bin/launch_cvd \
    --daemon \
    --config=phone \
    --vm_manager=qemu_cli
```

Replace `/path/to/img_files/...` with the actual directories where you
extracted the respective image and host-package archives. The flags mean:

| Flag                     | Meaning                                              |
|--------------------------|------------------------------------------------------|
| `--daemon`               | Run the VM in the background; return control after boot |
| `--config=phone`         | Use the standard Cuttlefish *phone* device profile   |
| `--vm_manager=qemu_cli`  | Back the guest with QEMU (the form that supports cross-ISA targets out of the box) |

`HOME=$(pwd)` and `PWD=...` ensure Cuttlefish creates its `cuttlefish/`
runtime tree inside the image directory rather than inside the calling
user's `$HOME`, which keeps the two instances cleanly separated.

Boot typically takes 30–90 seconds per instance. Once both guests are up,
identify their VSOCK CIDs and adb serials:

```bash
# CIDs assigned by Cuttlefish (read from each instance's config)
jq '.instances[] | {name: .instance_name, cid: .vsock_guest_cid}' \
    /path/to/img_files/riscv/cuttlefish_runtime/cuttlefish_config.json
jq '.instances[] | {name: .instance_name, cid: .vsock_guest_cid}' \
    /path/to/img_files/arm/cuttlefish_runtime/cuttlefish_config.json

# adb serials — instance 1 → 0.0.0.0:6520, instance 2 → 0.0.0.0:6521
adb devices
```

The demo assumes riscv CID = 3 and ARM CID = 4 (these are the defaults for
instances 1 and 2). Connect to each guest individually:

```bash
adb -s 0.0.0.0:6520 shell getprop ro.product.cpu.abi   # → riscv64
adb -s 0.0.0.0:6521 shell getprop ro.product.cpu.abi   # → arm64-v8a
```

If your installation produces different serials, export them so the demo
scripts pick them up:

```bash
export ADB_RISCV_SERIAL=0.0.0.0:6520
export ADB_ARM_SERIAL=0.0.0.0:6521
```

## Building the Demo

With `ANDROID_NDK_HOME` set from the *Installing the Android NDK* section,
clone the repository (if you haven't already) and run `setup.sh`. It builds
every native component using the NDK cross-compilers and produces the DEX
artifact with `d8` from the Android SDK build-tools.

```bash
git clone <this-repo-url> jni-offload-demo
cd jni-offload-demo
./setup.sh
```

`setup.sh` produces, in order:

| Artifact                | Toolchain                                  | Target          |
|-------------------------|--------------------------------------------|-----------------|
| `host/vsock_relay`      | host `gcc`                                 | x86_64 Linux    |
| `arm/dispatcher`        | `aarch64-linux-android34-clang` (NDK)      | ARM64 Android   |
| `arm/libhello_arm.so`   | `aarch64-linux-android34-clang` (NDK)      | ARM64 Android   |
| `riscv/libhello.so`     | `riscv64-linux-android35-clang` (NDK r27+) | riscv64 Android|
| `java/HelloJNI.class`   | host `javac`                               | JVM bytecode    |
| `java/classes.dex`      | `d8` from SDK build-tools                  | ART DEX         |

If `d8` is not yet installed, fetch the Android SDK command-line tools and
use them to install build-tools:

```bash
mkdir -p $HOME/Android/Sdk/cmdline-tools
cd $HOME/Android/Sdk/cmdline-tools
curl -O https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
unzip commandlinetools-linux-*.zip
mv cmdline-tools latest
export ANDROID_HOME=$HOME/Android/Sdk
yes | $ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager --licenses
$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager "build-tools;36.0.0"
echo 'export ANDROID_HOME=$HOME/Android/Sdk' >> ~/.bashrc
source ~/.bashrc
```

After `setup.sh` finishes, every file in the *Repository Layout* table
marked **Rebuildable** has been regenerated in place from this repository's
source.

## Running the Demo

The end-to-end procedure is three commands on the host. Both Cuttlefish VMs
must already be running (see *Creating and Launching riscv64 and ARM64
Virtual Devices*).

```bash
# On the host — confirm both guests are visible
adb devices

# On the host — build, deploy, start dispatcher + relay
./setup.sh

# On the host — invoke the Java app on the riscv guest, collect logs
./run.sh
```

What each phase does:

- **`./setup.sh`** rebuilds all artifacts via the NDK; roots both guests
  and switches SELinux to permissive (the shell domain is otherwise denied
  `AF_VSOCK`); pushes `dispatcher` + `libhello_arm.so` to
  `/data/local/tmp/` on the ARM guest and starts the dispatcher; pushes
  `libhello.so` + `classes.dex` to `/data/local/tmp/` on the riscv guest;
  launches the host-side `vsock_relay`.
- **`./run.sh`** tails `JNI_DISPATCHER` logcat on ARM and `JNI_SHIM` logcat
  on riscv, then invokes the Java app inside the riscv guest:

  ```bash
  # Executed by run.sh on the riscv guest (shown for reference)
  CLASSPATH=/data/local/tmp/classes.dex \
  LD_LIBRARY_PATH=/data/local/tmp \
  app_process -Djava.library.path=/data/local/tmp / HelloJNI
  ```

  `app_process` is the standard ART entry point. Loading `HelloJNI`
  triggers `System.loadLibrary("hello")` → `dlopen("libhello.so")` → the
  shim. The shim then issues the cross-ISA JNI call. `run.sh` prints the
  three collected log streams and then checks that every required line
  appears (relay INVOKE/REPLY frames, ARM `dlopen` + captured payload,
  riscv shim ack, clean exit).

## Expected Output

When the demo succeeds, `run.sh` prints all three log streams and ends with
`ALL CHECKS PASSED`. A condensed, idealised trace looks like this:

```
[riscv JVM]        Invoking HelloJNI.sayHello()
[riscv Shim]       Forwarding request over VSOCK
[Host Relay]        Forwarding to ARM guest
[ARM Dispatcher]    Loading libhello_arm.so
[ARM Native]        Hello from ARM64!
[riscv JVM]        Result: Hello from ARM64!
```

The actual collected logs in `logs/` contain the framed wire details —
request IDs, library and symbol names, captured byte counts — for example:

```
[relay] INVOKE req_id=1  lib=libhello_arm.so  sym=Java_HelloJNI_sayHello  sig=()V  arg_len=0  (CID3→CID4)
[relay] REPLY  req_id=1  status=0  retdesc='s'  ret_len=13  (CID4→CID3)
JNI_DISPATCHER: dlopen(libhello_arm.so) ok
JNI_DISPATCHER: dlsym(Java_HelloJNI_sayHello) ok, invoking with NULL JNIEnv/jobject
JNI_DISPATCHER: captured 13 bytes of stdout: Hello World!
JNI_SHIM:       reply ok req_id=1 retdesc='s' ret_len=13 payload: Hello World!
```

## Cleaning Up

Stop the host-side daemons and on-guest dispatcher:

```bash
# Kill the host vsock_relay
kill "$(cat .relay.pid)" 2>/dev/null || true
rm -f .relay.pid .dispatcher.pid

# Kill the on-guest dispatcher
adb -s "${ADB_ARM_SERIAL:-0.0.0.0:6521}" shell pkill -f dispatcher || true
```

Stop both Cuttlefish instances. Run each command from the same directory
the instance was launched in:

```bash
# riscv guest (instance 1)
cd /path/to/img_files/riscv
HOME=$(pwd) CUTTLEFISH_INSTANCE=1 ./bin/stop_cvd

# ARM guest (instance 2)
cd /path/to/img_files/arm
HOME=$(pwd) CUTTLEFISH_INSTANCE=2 ./bin/stop_cvd
```

Remove the per-instance runtime trees if you want a fully clean restart:

```bash
rm -rf /path/to/img_files/riscv/cuttlefish_runtime*
rm -rf /path/to/img_files/arm/cuttlefish_runtime*
cvd remove --all 2>/dev/null || true
```

Remove the rebuildable artifacts and per-run logs from this repository:

```bash
rm -f host/vsock_relay arm/dispatcher \
      arm/libhello_arm.so riscv/libhello.so \
      java/HelloJNI.class java/classes.dex
rm -rf logs/
```

## Future Work

- **Real JNI arguments.** v1 passes `NULL` for `JNIEnv*` and `jobject`,
  which is safe only for functions that don't touch them. A v2 bridge could
  marshal primitive arguments and synthesise an in-dispatcher `JNIEnv*`
  using a hosted JVM on the ARM side.
- **String and object return values.** The wire format already carries a
  `retdesc` byte (`'V'` for void, `'s'` for byte blob). Adding `'I'`/`'J'`
  for ints/longs and `'L'` for full Java objects (with a per-call
  serialiser) is a straightforward extension.
- **Syscall servicing from the ARM guest** — Forward system calls made
  by offloaded ARM native code back to the RISCV guest, so the ARM VM
  can transparently service syscalls in the original process context.

  ## Presentation and Report links

- [Presentation link](https://drive.google.com/file/d/1j5iQn5HDWRX5N41c-xOY4RwuvElE-cQ2/view)
- [Presentation_slides](https://drive.google.com/file/d/1Uc8ciAYkJ2ZMRZX_LX1eDB0dvYtpmcmA/view?usp=sharing)
- [Report](https://drive.google.com/file/d/1J2xDphsbzw3tQUT-TT8PyvIrMO1nRapJ/view?usp=sharing)

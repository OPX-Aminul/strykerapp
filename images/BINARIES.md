# The binaries Stryker executes

An audit of every native artifact the app ships or downloads, what the app
expects from it (exact argv, streams and markers), and how each one is built.
Everything below was measured on the artifacts themselves — `readelf -h/-l/-d/-p
.comment/-n`, `strings`, and a byte comparison against the published releases —
not read off a build log. Where a claim is an inference it says so.

The build scripts in `images/tools/` are written from this file. Three binaries
(`passt`, `umnet` + the harness `stub`, and `qemu` + `libslirp`) had no script
here at all before; `build-umusb.sh` and `build-bash.sh` already existed and are
the model the new ones follow.

## 1. What the APK carries and runs

The app may only exec from `ApplicationInfo.nativeLibraryDir`, and that
directory only keeps files matching `lib*.so` — which is why every executable is
named `lib<thing>.so`.

| file in the APK | what it is | ELF facts (measured) | size | sha256 | built by |
|---|---|---|---|---|---|
| `libuml.so` | the UML kernel, run as the guest | ET_EXEC, static (no `PT_INTERP`), no dynamic symbols, `LOAD` align `0x10000`, NDK note: API 30 / **r27c**, `.comment`: clang 18.0.3 | 19,395,040 | `fab7a2b6…` | `kernel/build-uml.sh` |
| `libstub.so` | the UML address-space stub (`stub_exe=`) | ET_EXEC, static, 7 sections, `LOAD` align `0x8` | 1,928 | `fa83d4c9…` | `kernel/build-uml.sh` (`arch/um/kernel/skas/stub_exe`) |
| `libumnet.so` | UML launcher: starts the kernel and supervises `passt` | ET_EXEC, static, **DWARF + symtab kept**, align `0x4000`, clang 18.0.0/18.0.3 (NDK r27) | 2,230,040 | `a6e1af39…` | `tools/build-umnet.sh` (new) |
| `libpasst.so` | `passt`, the userspace network stack the UML guest dials out through | ET_EXEC, static, **DWARF + symtab kept**, align `0x4000`, clang 18.0.0/18.0.3, strings: `Copyright Red Hat` | 2,763,568 | `4747d22d…` | `tools/build-passt.sh` (new) |
| `libumusb.so` | USB/IP server for passthrough into the UML guest | ET_EXEC, static, stripped (no `.comment`, no DWARF), align `0x4000` | 459,224 | `7e394b59…` | `tools/build-umusb.sh` (existing) |
| `libqemu.so` | **QEMU 11.0.2**, `-M virt` aarch64 TCG machine | `DYN` (PIE), `PT_INTERP = /system/bin/linker64` → normal Android bionic binary; `NEEDED`: `libslirp.so`, `libz.so`, `libm.so`, `libdl.so`, `libc.so`; align `0x4000`/`0x10000`; clang 21.0.0 (Android r563880c); **no debug info** | 43,800,304 | `2a87f531…` | `tools/build-qemu.sh` (new) |
| `libslirp.so` | libslirp, the user-net backend `libqemu.so` links against | `DYN`, `SONAME libslirp.so`, `NEEDED`: `libc.so` only, align `0x4000`/`0x10000`, clang 21.0.0 | 1,145,496 | `22637242…` | `tools/build-qemu.sh` (new) |
| `libbash.so` | GNU bash 5.2.37 for the terminal | ET_EXEC, static, stripped, align `0x4000` | 1,598,552 | `c5bdf70f…` | `tools/build-bash.sh` (existing) |

Inference worth stating: `libqemu.so` needs `libslirp/libz/libm/libdl/libc` and
nothing else, and `libslirp.so` needs only `libc`, so **glib, pixman and libusb
are linked statically into `libqemu.so`**. `usr/local/sbin` build paths in its
strings are `/qemu-11.0.2/…` (`include/hw/...`, `hw/usb/hcd-ehci.h`), i.e. the
release tarball unpacked at `/qemu-11.0.2`, and it carries
`wrap_sys_device`/`/dev/fdset/` — the libusb `usb-host` backend the app drives
for USB passthrough (`--enable-libusb`).

## 2. What is downloaded at install time, and how it compares

`StrykerEndpoints` reads `stryker_manifest.json` and pulls binaries from this
repository's release tags. The UML kernel and `stub_exe` ship *inside the APK*
(`UML engine: the kernel ships in the app, only the disk image is needed`); the
rest is downloaded.

| release asset | tag | size | sha256 | vs the APK copy |
|---|---|---|---|---|
| `qemu-system-aarch64` | `rootless-main` | 43,800,304 | `2a87f531…` | **identical** to `libqemu.so` |
| `libslirp.so` | `rootless-main` | 1,145,496 | `22637242…` | **identical** to `libslirp.so` |
| `Image` | `rootless-650` | 28,676,104 | — | VM kernel (not in the APK) |
| `initrd.img` | `rootless-650` | 16,308,339 | — | VM initrd (not in the APK) |
| `rootfs.imgz` | `rootless-650` | 321,664,844 | — | VM disk (not in the APK) |
| `linux-uml` | `rootless-650` | 19,763,856 | `c091ecda…` | **different** from `libuml.so` |
| `stub_exe` | `rootless-650` | 1,920 | `83f51f7c…` | **different** from `libstub.so` |
| `Image.config` | `rootless-650` | 145,516 | — | VM kernel config |
| `chroot64-debian.tar.gz` | `chroot-main` | 237,502,035 | — | chroot engine |

The two UML divergences are real and worth knowing before rebuilding: the APK's
kernel reports `Linux version 7.2.0-rc4-g8897487c5223-dirty` against the
release's `…g8897487c5223` (clean), and its string set differs (the APK build has
`fuse`, `nfs`, `usbip`, `overlay`, `cfg80211` present in greater number and no
`btusb`), so the APK's kernel was built from a **modified tree and a different
config** than the published `linux-uml`. A rebuild therefore has to decide which
copy is canonical; the APK's is the one users execute.

## 3. The guest payload

`assets/rootless/stryker-guest-core.tar.enc` — `STRKCORE` magic, version 1,
16-byte salt, 12-byte IV, AES-256-GCM, key = 50,000 rounds of
`SHA-256(key ‖ salt)` seeded with `SHA-256(salt ‖ "strykertop")`
(`GuestCorePackage.java`). Extracted, it is a plain tar (296,960 bytes) whose
`CORE/.version` is `7`, which is what `GuestCore.VERSION` checks before it
skips a redeploy.

The two files the app calls "the agent" are **shell/python scripts, not
binaries**:

- `usr/local/sbin/stryker-agentd` (1,060 B, `#!/bin/sh`) — needs `socat` in the
  guest; opens `TCP-LISTEN:1050` (`EXEC:/bin/sh`), `1051` (`bash -il` on a pty)
  and starts `stryker-ptyd` for `1052`, writing progress to
  `/tmp/stryker-ptyd.status` — which the app reads back as
  `guestAgentPortReason()`.
- `usr/local/sbin/stryker-ptyd` (6,335 B, `#!/usr/bin/env python3`) — the
  resizable PTY on port 1052; swallows in-band `\x00WINCH:<rows>:<cols>\x00`
  frames and applies them with `TIOCSWINSZ` + `SIGWINCH`.

So the guest side of the "binary" contract is `socat`, `python3` and `bash`
being present in the rootfs (`rootfs/packages.list`), not a compiled agent.
`CORE/.version` must be bumped whenever the tar is repacked, or phones keep the
old deploy.

## 4. The contract the app relies on

Flags the app passes, taken from the Java that starts each process.

### UML engine — `UmlEngine.buildCommand()`

```
libumnet.so --passt <nativeDir>/libpasst.so
            --fwd 127.0.0.1/2222:22
            --
            libuml.so mem=<Mb>M panic=-1 con=null con0=fd:0,fd:1
                      stub_exe=<nativeDir>/libstub.so seccomp=auto|off
                      ncpus=<N> ubd0=<files>/rootless/rootfs.img root=/dev/ubda rw
                      init=/stryker-init stryker.share=<share>
                      firmware_class.path=/host/firmware
```

- Environment: `TMPDIR` (a writable dir, or the guest memory file lands in the
  app's own `uml/tmp`) and `HOME` (UML's `umid` directory) — set by `UmlEngine`.
- The console the app reads is the kernel's stdout: `con0=fd:0,fd:1`, merged
  stderr. `VmBootStage` keys off `STRYKER_BOOT` / `STRYKER_INIT`, and
  `BootDiagnosis` reads the tail of `console.log`.
- Required in the console: nothing. Required for success: `sshd` reachable on
  22, `GuestSsh.ping` (an `exec` channel running `echo __STRYKER_PONG__`) and
  `guestShellReady()` (`id -un`/`hostname` answering `root@…`).
- `seccomp=off` is the only lever the app has if a device's seccomp policy
  rejects the guest (see the `SIGSYS`/`close_range` case in `BootDiagnosis`).
- Exit status: 128 + signal, reported as such (`159` = SIGSYS). `libumnet.so`
  strings show it also logs `umnet: passt exited %d`, `umnet: kernel killed by
  signal %d (%s)`, `umnet: bad frame length %u` — those are what a UML boot
  failure looks like on the console.

### QEMU engine — `RootlessEngine.buildCommand()`

Full argv as recorded in a live log (`ok.txt`), shortened to one line:

```
libqemu.so -nodefaults -M virt,gic-version=3 -cpu max,sve=off,pmu=off,pauth=off
  -accel tcg,thread=multi,tb-size=512 -smp 4,sockets=1,cores=4,threads=1 -m 4096
  -kernel …/Image -initrd …/initrd.img -append root=/dev/vda rw rootwait
  rootflags=noatime console=ttyAMA0 … stryker.rootless=1 …
  -drive file=…/rootfs.img,if=none,id=drive0,format=raw,cache=writeback,aio=threads,…
  -object iothread,id=io0 -device virtio-blk-pci,drive=drive0,iothread=io0
  -netdev user,id=net0,ipv6=off,hostfwd=tcp:127.0.0.1:2222-:22
  -device virtio-net-pci,netdev=net0,romfile=
  -device qemu-xhci,id=usbhc0,p2=8,p3=8 -device virtio-rng-pci
  -fsdev local,id=fsdev0,security_model=none,path=<share> -device virtio-9p-pci,fsdev=fsdev0,mount_tag=strykershare
  -chardev socket,id=serial0,path=…/serial.sock,server=on,wait=off,logfile=…/serial.log
  -serial chardev:serial0 -device virtio-serial-pci
  -chardev socket,id=term0,path=…/term.sock,server=on,wait=off
  -device virtconsole,chardev=term0,name=org.stryker.term -display none
  -qmp unix:…/qmp.sock,server,nowait
```

- Environment: `LD_LIBRARY_PATH=<nativeDir>:<base>:/system/lib64:/vendor/lib64`
  — `libslirp.so` must sit next to `libqemu.so` or the process never starts.
- Devices the app needs by name: `virtio-blk-pci`, `virtio-net-pci` + `-netdev
  user` with `hostfwd`, `qemu-xhci` (USB passthrough target), `virtio-rng-pci`
  (the safe profile drops it), `virtio-9p-pci` with `mount_tag=strykershare`,
  `virtio-serial-pci` + `virtconsole`, and the QMP monitor on a unix socket.
- USB passthrough, QEMU side (`UsbPassthroughManager`): the app takes the
  descriptor Android hands it for the device, passes it to QEMU with QMP
  `add-fd`, then `device_add {"driver":"usb-host",
  "hostdevice":"/dev/fdset/<id>", …}`, and `device_del` + `remove-fd` on detach.
  That is the libusb `usb-host` path with `libusb_wrap_sys_device`, so the QEMU
  build must have libusb available **statically** (nothing else is `NEEDED`).
- Console: `console=ttyAMA0` + `loglevel=4`; `VmBootStage`/`BootDiagnosis` read
  `serial.log` (`-chardev … logfile=`). Port mirroring for the guest agent is
  done with QMP `hostfwd_add`.
- Safe profile (`VmSpecs.safeBoot`): `aio=threads, cache=writeback`, legacy CPU
  (`pauth-impdef=on`), no `virtio-rng`, no iothread, no fast-boot flags.

### UML engine — USB, `UmlUsb`

```
libumusb.so --usbsock <name> --listen 127.0.0.1:<port> --no-cmdline --verbose
```

The guest dials out to `10.0.2.2` (passt maps that to the phone's loopback) and
attaches with `bash /host/usb-attach.sh --connect … [--speed …] [--devid …]`;
`--detach <vhciPort>` releases it. `libumusb.so` logs lines prefixed `umusb: `,
which the app mirrors into the log store.

### The Xiaomi/MIUI USB fix — every engine, two layers

Xiaomi/MIUI's host stack reports a full-speed USB device as *low-speed* while
the device's own descriptor still says its ep0 maxpacket is 64. A low-speed
device may not have that (USB 2.0 section 5.5.3, table 5-6), so the guest
refuses to enumerate it:

```
usb 1-1: Invalid ep0 maxpacket: 64
usb usb1-port1: unable to enumerate USB device
```

Podroid fixes that in two layers, and so does this repo: `images/usb-quirks.py`
applies the same fix, in the same two layers, to every engine that can hand a
USB device to a guest — the *host* side corrects the speed before the guest
reads the descriptor, and the *guest kernel* keeps a safety net for what the
guest has already latched.

| layer | source | engine | string in the shipped binary |
|---|---|---|---|
| host | `hw/usb/host-libusb.c` | QEMU engine (`usb-host` over libusb) | `Xiaomi/MIUI: low speed reported for a device whose ep0 maxpacket is 64; telling the guest it is full speed` |
| host | `harness/umusb.c` | UML engine (`libumusb.so`, USB/IP → `vhci_hcd`) | same string |
| guest | `drivers/usb/core/hub.c` | both guest kernels (`libuml.so`/`linux-uml`, `Image`) | `Xiaomi/MIUI: low speed reported with ep0 maxpacket 64; believing the device is full speed` |

Two shapes of the kernel's ep0 check are known (6.12/6.18/7.x, and 5.x through
6.1) and both are handled; a tree with neither, or a QEMU whose completion
handler has moved, stops the build with exit 2 instead of shipping a binary
without the fix. Each of `build-qemu.sh`, `build-umusb.sh`, `build-uml.sh` and
`build-vm.sh` applies its layer before it compiles and checks the string in the
artifact it is about to ship, and `.github/workflows/binaries.yml` re-checks all
of them together before anything is published.

On a phone the fix says so: the QEMU engine logs a `warn_report` line, the UML
engine a `umusb: ` line, and the guest kernel a `dev_info` line in `dmesg` —
and the device enumerates instead of failing.

### Terminal — `libbash.so`

`terminal/…/component/config/exec.kt` copies the executable out of
`nativeLibraryDir` (`NeoTermActivity` sets `.executablePath("<BIN_PATH>/bash")`),
so `libbash.so` must be a static ET_EXEC with no `PT_INTERP` — the same
requirement `build-bash.sh` already enforces.

## 5. Toolchains, as measured

| binary | `.comment` / NDK note | reading |
|---|---|---|
| `libuml.so`, `linux-uml` | API 30, `r27c`, clang 18.0.3 (r522817c) | built with **NDK r27c** |
| `libumnet.so`, `libpasst.so` | clang 18.0.0 (r510928) *and* 18.0.3 (r522817c) | NDK r27 series; two entries because objects came from two compilers |
| `libqemu.so`, `libslirp.so` | clang 21.0.0 (r563880c, +pgo/+bolt/+lto/+mlgo), LLD 21.0.0 | a **newer NDK/clang than the rest** |
| `libumusb.so`, `libbash.so` | stripped, no `.comment` | toolchain not recoverable from the file; scripts here use the NDK in `$NDK` |

Page size: every binary the *app* execs is linked for **16 KB pages**
(`LOAD` align `0x4000` or higher): measured `0x4000` for `libumnet.so`,
`libpasst.so`, `libumusb.so`, `libbash.so`, `libqemu.so` and `libslirp.so`, and
`0x10000` for `libuml.so`. The one exception is `libstub.so`, aligned `0x8`:
the app does not exec it — `libuml.so` hands it to the kernel as `stub_exe=`,
and the kernel maps it itself, so an alignment below the page size is legal
there (and would not be for anything the linker loads). The checks in
`lib/common.sh` are applied to the binaries the app does exec, and the new
scripts keep 16 KB pages. `build-umnet.sh` and `build-passt.sh` also keep debug
info, matching what ships, which is what `keepDebugSymbols` is for — but it only
applies to those two, as the next paragraph explains.

One correction to an earlier note in this repository: `libqemu.so` carries **no**
`.debug_info`/`.symtab` — 43.8 MB is QEMU's own code. The `keepDebugSymbols`
list in `app/build.gradle` is therefore only meaningful for `libumnet.so` and
`libpasst.so`, which do ship with full DWARF (that is most of their 2–3 MB).

## 6. What the new scripts build, and what still needs a run to prove

| script | produces | status |
|---|---|---|
| `tools/build-umnet.sh` | `umnet` → `libumnet.so` | new |
| `tools/build-passt.sh` | `passt` → `libpasst.so` | new |
| `tools/build-qemu.sh` | `qemu-system-aarch64` → `libqemu.so`, `libslirp.so` | new, heaviest |
| `tools/build-umusb.sh` | `umusb` → `libumusb.so` | existing |
| `tools/build-bash.sh` | `bash` → `libbash.so` | existing |
| `build-binaries.sh` | runs the four above for the APK, verifies, records hashes | new |
| `kernel/build-uml.sh` | `Image`, `initrd.img`, `linux-uml` (→ `libuml.so`), `stub_exe` (→ `libstub.so`) | existing |

Caveats to carry forward: the QEMU script vendors glib, pixman and libusb
statically, which is where a first CI run is most likely to need iteration; the
Xiaomi/MIUI USB fix is applied by `tools/build-qemu.sh`, `tools/build-umusb.sh`,
`kernel/build-uml.sh` and `kernel/build-vm.sh` through `images/usb-quirks.py`,
which is the one file to update if any of those sources changes shape; the
`umnet` source lives in the UML port tree that `build-uml.sh` and
`build-umusb.sh` already take as `TREE=` (the port is not a public repository,
so CI needs it handed to it as a repository or a tarball); and none of these
scripts can be executed in a workspace without an NDK and network access — they
are run by `.github/workflows/binaries.yml`, which then verifies the outputs and
hands the new hashes to the release workflow.

What *could* be checked here was: the shared checks in `images/lib/common.sh`
(`check_static_exec`, `check_android_pie`, `check_load_align`, `check_marker`,
`check_no_build_paths`, `check_needed_absent`) were run against all eight shipped
binaries, 20 cases including the negative ones (QEMU must fail the static check,
`libumusb.so` must not match umnet's markers, and so on). All 20 behave as
tabulated above. The build recipes themselves have not been executed — that is
what the workflow run is for.

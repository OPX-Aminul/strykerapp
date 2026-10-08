# The kernels and root filesystems Stryker runs

Everything the app downloads at install time is built by the scripts in this
directory. Issue #79 asked for these; this is them, and the same scripts are
what produce the published releases, not a cleaned-up approximation of them.

```sh
sudo images/build-all.sh                  # everything, in dependency order
images/publish.sh https://github.com/zalexdev/strykerapp/releases/download
```

Nothing here knows what machine it is on, and nothing here needs a machine
that has been set up in a particular way beyond the packages listed below.

## What it makes

| file | engine | what it is |
|---|---|---|
| `Image` | rootless VM | arm64 kernel for `qemu-system-aarch64 -M virt` |
| `initrd.img` | rootless VM | initramfs for that kernel |
| `rootfs.imgz` | rootless VM | Debian arm64, ext4, gzipped |
| `linux-uml`, `stub_exe` | UML | the same kernel as an Android executable |
| `umusb` | UML | the USB/IP server, shipped in the APK as `libumusb.so` |
| `chroot64-debian.tar.gz` | chroot | the same Debian, as a tarball |
| `stryker-driver-*.deb` | either | out-of-tree WiFi drivers, installed on demand |

**One kernel source, one Debian tree.** Both kernels are built from the arm64
UML port's checkout — `ARCH=um SUBARCH=arm64` for one, `ARCH=arm64` for the
other — and both engines then run the same userspace, packed twice. That is
deliberate: when the two are built from different releases they differ in which
drivers they have, which mac80211 they have and which bugs, and "works in the
VM, not in UML" becomes a week of bisecting. Built this way the only difference
between the engines is how the kernel is executed.

The port's changes outside `arch/um` are two added `#include` lines, in
`arch/arm64/kernel/module-plts.c` and `arch/arm64/lib/insn.c`, both so the UML
build can see declarations it otherwise misses. An `ARCH=arm64` build from that
tree is therefore the upstream kernel of whatever it is based on.

If the tree is sitting on a release candidate and you want a released kernel for
the VM, `KVER=6.18.49 images/kernel/build-vm.sh` downloads and verifies a
tarball from kernel.org instead.

## Requirements

```sh
apt install debootstrap qemu-user-static binfmt-support e2fsprogs \
            gcc-aarch64-linux-gnu bc flex bison libssl-dev dpkg-dev
```

Root, because the rootfs build mounts a loop device and makes device nodes.
The UML kernel additionally needs an Android NDK — `build-uml.sh` looks in the
usual places and says where it looked if it finds none.

## The three things this changed, and why

### Drivers are in the kernel, not in a module tree

Four issues in the tracker are one arrangement failing four ways. The shipped
`Image` was Debian's own package and the drivers were modules in
`/lib/modules`, so a working adapter depended on that tree being present, on
it matching the running kernel, and on `depmod` having been run — three things
that can each fail independently on a phone, silently, after the dongle is
already plugged in. The app grew code to unpack modules out of the initrd at
runtime to cope with it.

`kernel/config/wireless.config` builds every USB adapter's driver in, `=y`. A
built-in driver cannot be missing. It costs about 6 MB of `Image`, once.

That fixes the driver half. The firmware half was a separate gap: in trixie the
ath9k_htc and MediaTek firmware moved into packages of their own, so an image
built without naming them has a working `ath9k_htc` driver and no firmware for
it — the AR9271 enumerates and then reports "Target is unresponsive". Both are
in `rootfs/packages.list` now, along with `wireless-regdb`, whose absence
leaves the kernel on the most restrictive regulatory domain and silently
removes channels 12–14 and all of 5 GHz.

| issue | adapter | what was actually wrong |
|---|---|---|
| #73 | RTL8192EU (TL-WN821N v5/v6) | no injection-capable driver; now built in, and `rtl8192eu` is a package |
| #82 | RTL8812AU (ALFA) | `rtw88_8812au` was not in Debian's module set, though its firmware was |
| #83 | AR9271 | driver present, `firmware-ath9k-htc` absent |
| #86 | MT7610U | driver present, `firmware-mediatek` absent |

Rarer chips, and the forks that inject where the in-tree driver only
associates, are `.deb` packages built by `drivers/add-driver.sh` — installed
with `apt install stryker-driver-rtl8812au`, not carried by everyone.

### SSH is the transport

Both engines used to be reached the same way:

```
socat TCP-LISTEN:1050,fork EXEC:/bin/sh
```

A root shell, no authentication, and the phone forwards a loopback port to it —
so any other app on the device had root in the guest. The image also carried a
root password hash in `/etc/shadow`, the same one in every copy anybody ever
downloaded, with `PasswordAuthentication yes`.

Now: `sshd`, key only, root password locked. The app generates a keypair on the
phone and drops the public half into the share; `stryker-guest-init` installs
it before sshd starts. Host keys are generated on first boot — never shipped,
because an image containing host keys means every install answers with the same
key — and the fingerprint is written back into the share so the app can pin the
real one instead of trusting whatever answers first.

`rootfs/audit.sh` fails a build that reintroduces any of this.

### Nothing from the build machine

`rootfs/scrub.sh` removes it, `rootfs/audit.sh` looks for what is left, and the
audit runs as the last step of `build-all.sh` so a release cannot be cut
without it. Kernel builds get `KBUILD_BUILD_USER`/`HOST`/`TIMESTAMP` pinned in
`lib/common.sh`, because otherwise the builder's login and hostname are in
`/proc/version` on every install for the life of that image — and with them
pinned, two builds of the same commit produce the same bytes, so anyone can
check that a published `Image` is what these scripts make of that source.

The audit cannot prove an image is clean. It checks the places where things of
this kind have actually turned up, and it is written to be read and added to.

## Layout

```
images/
  BINARIES.md           what every native artifact is, how it was built, and the
                        flags/protocol the app drives it with — read it first
  build-all.sh          everything, in dependency order
  build-binaries.sh     just the binaries the APK carries (jniLibs)
  update-manifest.py    refresh sha256/size in stryker_manifest.json after a rebuild
  publish.sh            checksums + the stryker_manifest.json block
  lib/common.sh         identity pinning, deterministic tar/gzip
  kernel/
    build-vm.sh         arm64 Image for qemu -M virt
    build-uml.sh        ARCH=um SUBARCH=arm64, against bionic, static
    config/
      vm.config         what -M virt needs, and what to leave out
      uml.config        what a kernel with no hardware needs
      usb.config        what a passed-through device becomes -- shared
      wireless.config   every USB adapter -- shared by both kernels
  tools/
    build-umnet.sh      the UML launcher (libumnet.so), bionic + static
    build-passt.sh      passt (libpasst.so), the UML guest's network stack
    build-qemu.sh       QEMU 11 + libslirp for the VM (libqemu.so, libslirp.so);
                        glib, pcre2, libffi, pixman and libusb are built static
    build-umusb.sh      the USB/IP server, bionic + static, for the app
  rootfs/
    build.sh            debootstrap -> tarball + ext4 + initrd
    packages.list       what goes in, with the reason for each addition
    guest/              the guest's own init, sshd config, systemd unit
    scrub.sh / audit.sh
  drivers/
    add-driver.sh       out-of-tree driver -> .deb
    drivers.list        the ones it knows about
```

### USB passthrough is two halves, and only one of them differs

A device plugged into the phone reaches either guest, and the app asks for it
the same way in both: an app may not open `/dev/bus/usb`, so it asks the user
and is handed a descriptor that is already open. What happens to that descriptor
afterwards is where the engines part.

The VM hands it straight to QEMU, which builds a `usb-host` device on its
emulated xHCI controller. UML has no emulated hardware and so no controller to
attach anything to; its only USB transport is USB/IP, where `vhci-hcd` is a root
hub whose wire is a socket. `umusb` is the server on the other end of that
socket, driving the real device through `USBDEVFS_*` ioctls on the descriptor
the app was given. The guest dials *out* to reach it — 10.0.2.2, which passt
maps onto the phone's loopback — because `attach_store()` looks the socket up in
the file table of whoever writes to sysfs, so it has to be a socket the guest
itself owns. An inherited descriptor is simpler and cannot work.

Once the device has enumerated, the two are the same question again, which is
what `usb.config` is for: it holds the class drivers — serial, storage, HID,
bluetooth — and `vhci-hcd` itself, and both kernels merge it. They did not
always. The device half was written out in `vm.config` and repeated, shorter, in
`uml.config`, so an FTDI cable or a flash drive passed into the VM came up and
the same device passed into UML enumerated and bound nothing. Not by any
decision — the second list was just written later.

A device that binds no driver is still not a failure: both guests give it a
`/dev/bus/usb` node, which is what libusb opens and what `docker run --device`
takes.

## Order matters

`build-all.sh` runs the parts in the order they depend on: the rootfs needs the
VM kernel's modules to build an initrd against, and the driver packages need
that kernel's *build tree* — headers of the same version are not enough, and a
mismatch surfaces as "invalid module format" after the user has already
installed the package. Run by hand in another order you get an image with no
`/lib/modules`, which is exactly the state issue #82 describes.

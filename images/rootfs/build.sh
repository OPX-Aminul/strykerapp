#!/bin/bash
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../lib/common.sh"

SUITE=${SUITE:-trixie}
MIRROR=${MIRROR:-http://deb.debian.org/debian}
SIZE_MB=${SIZE_MB:-6144}
TREE=${TREE:-$WORK_DIR/rootfs/tree}
MNT=$WORK_DIR/rootfs/mnt
VMOUT=$OUT_DIR/vm

need_root
need debootstrap mkfs.ext4 resize2fs e2fsck gzip tar chroot
QEMU=$(command -v qemu-aarch64-static || true)
[ -n "$QEMU" ] || die "missing qemu-aarch64-static (apt install qemu-user-static)"
grep -q enabled /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null || die \
"qemu-aarch64 binfmt is not registered, so the arm64 chroot cannot run.
  systemctl restart binfmt-support
  or: docker run --privileged --rm tonistiigi/binfmt --install arm64"

mkdir -p "$WORK_DIR/rootfs" "$OUT_DIR" "$VMOUT" "$MNT"

APT_CACHE=${APT_CACHE:-$WORK_DIR/apt-cache}
mkdir -p "$APT_CACHE"

cleanup() {
	umount -l "$MNT" 2>/dev/null || true
	umount -l "$TREE/var/cache/apt/archives" 2>/dev/null || true
	for m in dev/pts dev proc sys; do
		umount -l "$TREE/$m" 2>/dev/null || true
	done
}
trap cleanup EXIT

REUSE=0
if [ "${KEEP_TREE:-0}" = 1 ] && [ -s "$TREE/var/lib/dpkg/status" ]; then
	REUSE=1
	say "reusing the tree at $TREE"
else
	say "debootstrap $SUITE (stage 1)"
	rm -rf "$TREE"
	mkdir -p "$TREE/usr/bin"
	debootstrap --arch=arm64 --foreign --variant=minbase \
		--cache-dir="$APT_CACHE" "$SUITE" "$TREE" "$MIRROR"
fi

cp -f "$QEMU" "$TREE/usr/bin/"

if [ "$REUSE" = 0 ]; then
	say "debootstrap (stage 2, under qemu)"
	chroot "$TREE" /debootstrap/debootstrap --second-stage

	say "installing packages"
	mkdir -p "$TREE"/{proc,sys,dev,dev/pts}
	mount -t proc proc "$TREE/proc"
	mount --rbind /sys "$TREE/sys"
	mount --rbind /dev "$TREE/dev"
	printf 'nameserver 1.1.1.1\n' > "$TREE/etc/resolv.conf"

	cat > "$TREE/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main contrib non-free non-free-firmware
deb $MIRROR ${SUITE}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${SUITE}-security main contrib non-free non-free-firmware
EOF

	printf '#!/bin/sh\nexit 101\n' > "$TREE/usr/sbin/policy-rc.d"
	chmod +x "$TREE/usr/sbin/policy-rc.d"

	mkdir -p "$TREE/var/cache/apt/archives"
	mount --bind "$APT_CACHE" "$TREE/var/cache/apt/archives"

	PKGS=$(grep -vE '^\s*(#|$)' "$HERE/packages.list" | tr '\n' ' ')
	chroot "$TREE" /bin/bash -c "
		set -e
		export DEBIAN_FRONTEND=noninteractive
		apt-get update -qq
		apt-get install -y --no-install-recommends $PKGS
	"

	cleanup
fi

say "checking every command the guest calls is present"
missing=
for c in sshd ssh-keygen resize2fs e2fsck ps ip iw iptables mount sed grep \
         hostname aircrack-ng airodump-ng aireplay-ng airmon-ng reaver wash \
         bully pixiewps mdk4 hydra nmap macchanger hcxdumptool hcxpcapngtool \
         tcpdump socat python3 depmod modprobe; do
	found=
	for d in usr/sbin usr/bin sbin bin; do
		[ -x "$TREE/$d/$c" ] && { found=1; break; }
	done
	[ -n "$found" ] || missing="$missing $c"
done
[ -z "$missing" ] || die "the image would be missing:$missing
  Each of these is called by the guest's init or by a screen in the app, so an
  image without one boots and then fails at the moment a user presses a
  button. Add the package that carries it to packages.list."
info "all present"

say "configuring"

install -m 755 "$HERE/guest/stryker-guest-init" "$TREE/usr/local/sbin/stryker-guest-init"
install -m 755 "$HERE/guest/stryker-init"       "$TREE/stryker-init"
install -d -m 755 "$TREE/etc/ssh/sshd_config.d"
install -m 644 "$HERE/guest/sshd_stryker.conf"  "$TREE/etc/ssh/sshd_config.d/10-stryker.conf"
install -m 644 "$HERE/guest/stryker-guest.service" \
               "$TREE/etc/systemd/system/stryker-guest.service"
mkdir -p "$TREE/etc/systemd/system/multi-user.target.wants"
ln -sf ../stryker-guest.service \
	"$TREE/etc/systemd/system/multi-user.target.wants/stryker-guest.service"

rm -f "$TREE/etc/systemd/system/stryker-agent.service" \
      "$TREE/etc/systemd/system/multi-user.target.wants/stryker-agent.service" \
      "$TREE/etc/systemd/system/stryker-sshkeys.service" \
      "$TREE/etc/systemd/system/multi-user.target.wants/stryker-sshkeys.service" \
      "$TREE/usr/local/sbin/stryker-agentd"

install -d -m 755 "$TREE/usr/local/lib/stryker"
install -m 755 "$HERE/guest/systemctl-shim" "$TREE/usr/local/lib/stryker/systemctl"

install -m 644 "$HERE/guest/stryker_profile.sh" "$TREE/etc/stryker_profile.sh"
for rc in "$TREE/etc/profile" "$TREE/root/.bashrc"; do
	grep -q stryker_profile "$rc" 2>/dev/null && continue
	printf '\n[ -f /etc/stryker_profile.sh ] && . /etc/stryker_profile.sh\n' >> "$rc"
done

printf 'stryker\n' > "$TREE/etc/hostname"
printf '127.0.0.1\tlocalhost stryker\n::1\t\tlocalhost\n' > "$TREE/etc/hosts"

cat > "$TREE/etc/fstab" <<'EOF'
LABEL=stryker / ext4 defaults,noatime,errors=remount-ro 0 1
strykershare /sdcard/Stryker 9p trans=virtio,version=9p2000.L,msize=262144,nofail,x-systemd.device-timeout=5 0 0
EOF
mkdir -p "$TREE/sdcard/Stryker" "$TREE/host" "$TREE/root/.ssh"
chmod 700 "$TREE/root/.ssh"

mkdir -p "$TREE/etc/systemd/network"
cat > "$TREE/etc/systemd/network/10-eth.network" <<'EOF'
[Match]
Name=eth0 en*

[Network]
DHCP=yes
EOF
chroot "$TREE" systemctl enable systemd-networkd.service >/dev/null 2>&1 || true

chroot "$TREE" systemctl disable systemd-networkd-wait-online.service >/dev/null 2>&1 || true
chroot "$TREE" systemctl mask   systemd-networkd-wait-online.service >/dev/null 2>&1 || true
chroot "$TREE" systemctl mask   NetworkManager-wait-online.service   >/dev/null 2>&1 || true
chroot "$TREE" systemctl enable ssh.service                          >/dev/null 2>&1 || true

mkdir -p "$TREE/etc/systemd/system/serial-getty@ttyAMA0.service.d"
cat > "$TREE/etc/systemd/system/serial-getty@ttyAMA0.service.d/autologin.conf" <<'EOF'
[Service]
# The app drives this console over the serial socket to start the guest agent when ssh
# is not usable yet, so it has to be a shell and not a login prompt: the guest locks the
# root password (stryker-guest-init runs 'passwd -l root'), so a prompt could never be
# answered and every command typed at it is swallowed as a user name.
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud 115200,57600,38400,9600 %I $TERM
EOF

KREL=
if [ -f "$VMOUT/kernel.release" ]; then
	KREL=$(cat "$VMOUT/kernel.release")
fi

if [ -n "$KREL" ] && [ -d "$VMOUT/modules/lib/modules/$KREL" ]; then
	bash "$HERE/prune-firmware.sh" "$TREE" "$VMOUT/modules/lib/modules/$KREL"
else
	warn "no module tree staged, so firmware cannot be pruned against it."
	warn "The images will carry every firmware package in full (~190 MB)."
fi

bash "$HERE/scrub.sh" "$TREE"

say "packing the chroot tarball"
rm -f "$OUT_DIR/chroot64-debian.tar.gz"
tar --create --directory="$TREE" \
    --owner=root --group=root --numeric-owner \
    --mtime="@$SOURCE_DATE_EPOCH" --sort=name --format=gnu \
    --transform='s,^\./,release/,' --transform='s,^\.$,release,' \
    . | gz > "$OUT_DIR/chroot64-debian.tar.gz"
first=$( { tar tzf "$OUT_DIR/chroot64-debian.tar.gz" || true; } | head -1 )
case "$first" in
	release/*|release) info "tarball root: $first" ;;
	*) die "the tarball starts with '$first', not 'release/'. The app unpacks to
  /data/local/stryker and then looks for release/usr inside it." ;;
esac
record_artifact "$OUT_DIR/chroot64-debian.tar.gz"

if [ -n "$KREL" ] && [ -d "$VMOUT/modules/lib/modules/$KREL" ]; then
	say "installing kernel modules ($KREL)"
	mkdir -p "$TREE/lib/modules"
	rm -rf "$TREE"/lib/modules/*
	cp -a "$VMOUT/modules/lib/modules/$KREL" "$TREE/lib/modules/"
	rm -f "$TREE"/boot/initrd.img-* "$TREE"/boot/config-*
	mount -t proc proc "$TREE/proc" 2>/dev/null || true
	chroot "$TREE" depmod -a "$KREL"

	say "building the initrd"
	install -m 644 "$VMOUT/Image.config" "$TREE/boot/config-$KREL"

	mkdir -p "$TREE/etc/initramfs-tools"
	cat > "$TREE/etc/initramfs-tools/initramfs.conf" <<'EOF'
MODULES=list
BUSYBOX=auto
COMPRESS=zstd
DEVICE=
NFS=no
RUNSIZE=10%
EOF
	: > "$TREE/etc/initramfs-tools/modules"
	mount -t sysfs sysfs "$TREE/sys" 2>/dev/null || true
	chroot "$TREE" update-initramfs -c -k "$KREL" 2>&1 | sed 's/^/   /' \
		|| chroot "$TREE" mkinitramfs -o "/boot/initrd.img-$KREL" "$KREL"
	umount -l "$TREE/sys" 2>/dev/null || true
	[ -f "$TREE/boot/initrd.img-$KREL" ] || die "no initrd was produced for $KREL"
	cp -f "$TREE/boot/initrd.img-$KREL" "$VMOUT/initrd.img"
	record_artifact "$VMOUT/initrd.img"
	umount -l "$TREE/proc" 2>/dev/null || true
	info "initrd: $(human "$(stat -c%s "$VMOUT/initrd.img")")"
else
	warn "no kernel modules staged at $VMOUT/modules -- run images/kernel/build-vm.sh first."
	warn "The VM image will be built without /lib/modules and without an initrd,"
	warn "which is exactly the state that produced issue #82."
fi

say "packing the VM image (${SIZE_MB} MB, then shrunk)"
IMG=$VMOUT/rootfs.img
rm -f "$IMG" "$IMG.gz"
truncate -s "${SIZE_MB}M" "$IMG"
mkfs.ext4 -q -F -L stryker -U "$(cat /proc/sys/kernel/random/uuid)" "$IMG"
mount -o loop "$IMG" "$MNT"
cp -a "$TREE"/. "$MNT"/
mkdir -p "$MNT"/{dev,proc,sys,tmp,host,sdcard/Stryker}
chmod 1777 "$MNT/tmp"
mknod "$MNT/dev/console" c 5 1 2>/dev/null || true
mknod "$MNT/dev/null"    c 1 3 2>/dev/null || true
mknod "$MNT/dev/tty"     c 5 0 2>/dev/null || true
sync
umount "$MNT"

before=$(stat -c%s "$IMG")
e2fsck -fp "$IMG" >/dev/null 2>&1 || true
resize2fs -M "$IMG" >/dev/null 2>&1
blocks=$(dumpe2fs -h "$IMG" 2>/dev/null | awk -F: '/Block count/ {print $2+0}')
bs=$(dumpe2fs -h "$IMG" 2>/dev/null | awk -F: '/Block size/ {print $2+0}')
truncate -s $((blocks * bs)) "$IMG"
e2fsck -fp "$IMG" >/dev/null 2>&1 || true

say "compressing"
gz -c "$IMG" > "$VMOUT/rootfs.imgz"
record_artifact "$VMOUT/rootfs.imgz"

cleanup
trap - EXIT

printf '\n'
printf '%-26s %s\n' "chroot tarball:" "$(human "$(stat -c%s "$OUT_DIR/chroot64-debian.tar.gz")")"
printf '%-26s %s\n' "vm image, unshrunk:" "$(human "$before")"
printf '%-26s %s\n' "vm image, shrunk:" "$(human "$(stat -c%s "$IMG")")"
printf '%-26s %s\n' "vm image, compressed:" "$(human "$(stat -c%s "$VMOUT/rootfs.imgz")")"
[ -f "$VMOUT/initrd.img" ] && printf '%-26s %s\n' "initrd:" "$(human "$(stat -c%s "$VMOUT/initrd.img")")"
printf '\n%s\n' "check it before publishing:  sudo images/rootfs/audit.sh $IMG"

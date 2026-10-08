#!/bin/bash
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../lib/common.sh"

KVER=${KVER:-6.18.49}
JOBS=${JOBS:-$(nproc)}
ARCH_DIR=$WORK_DIR/vm
O=$ARCH_DIR/build
DEST=$OUT_DIR/vm

if [ -z "${TREE:-}" ] && [ -z "${KVER_FORCED:-}" ]; then
	for c in "$IMAGES_DIR/../../linux-um-arm64" "$IMAGES_DIR/../../mlu-arm64" \
	         "$HOME/linux-um-arm64" "$HOME/mlu-arm64"; do
		[ -f "$c/Makefile" ] && { TREE=$c; break; }
		[ -f "$c/linux/Makefile" ] && { TREE=$c/linux; break; }
	done
fi
if [ -n "${TREE:-}" ]; then
	[ -f "$TREE/Makefile" ] || die "no kernel tree at $TREE"
	SRC=$(cd "$TREE" && pwd)
else
	SRC=$ARCH_DIR/linux-$KVER
fi

CROSS_BARE=${CROSS_COMPILE:-aarch64-linux-gnu-}
CROSS=$CROSS_BARE
export ARCH=arm64
export CROSS_COMPILE=$CROSS

if command -v ccache >/dev/null 2>&1 && [ "${CCACHE:-1}" = 1 ]; then
	export CCACHE_DIR=${CCACHE_DIR:-$WORK_DIR/ccache}
	export CCACHE_MAXSIZE=${CCACHE_MAXSIZE:-20G}
	export CCACHE_SLOPPINESS=time_macros,include_file_mtime,include_file_ctime
	mkdir -p "$CCACHE_DIR"
	CROSS="ccache $CROSS"
	export CROSS_COMPILE=$CROSS
fi

need make curl xz tar bc flex bison sha256sum python3
command -v "${CROSS_BARE}gcc" >/dev/null \
	|| die "no ${CROSS_BARE}gcc (apt install gcc-aarch64-linux-gnu), or set CROSS_COMPILE="

mkdir -p "$ARCH_DIR" "$DEST"

series=v${KVER%%.*}.x
tarball=linux-$KVER.tar.xz
base=https://cdn.kernel.org/pub/linux/kernel/$series

if [ -n "${TREE:-}" ]; then
	say "source: $SRC"
	info "$(git -C "$SRC" log --oneline -1 2>/dev/null || echo 'not a git checkout')"
	info "kernel: $(make -C "$SRC" -s kernelversion 2>/dev/null)"
	if [ -n "$(git -C "$SRC" status --porcelain 2>/dev/null | head -1)" ]; then
		warn "the tree has uncommitted changes; this build is not reproducible"
		warn "  (the Xiaomi/MIUI USB patch this repo applies to hub.c is one of"
		warn "  them, so a rerun of an already-patched tree always reports this)"
	fi
elif [ ! -d "$SRC" ]; then
	if [ ! -f "$ARCH_DIR/$tarball" ]; then
		say "fetching $tarball"
		curl -fL --progress-bar -o "$ARCH_DIR/$tarball.part" "$base/$tarball"
		mv "$ARCH_DIR/$tarball.part" "$ARCH_DIR/$tarball"
	fi
	say "verifying $tarball"
	curl -fsL -o "$ARCH_DIR/sha256sums.asc" "$base/sha256sums.asc" || true
	if [ -s "$ARCH_DIR/sha256sums.asc" ]; then
		want=$(grep " $tarball\$" "$ARCH_DIR/sha256sums.asc" | awk '{print $1}' | head -1)
		got=$(sha256_of "$ARCH_DIR/$tarball")
		[ -n "$want" ] || die "kernel.org's sha256sums.asc does not list $tarball"
		[ "$want" = "$got" ] || die "checksum mismatch for $tarball
  published $want
  got       $got"
		info "sha256 matches kernel.org: $got"
		if command -v gpg >/dev/null && gpg --verify "$ARCH_DIR/sha256sums.asc" \
				>/dev/null 2>&1; then
			info "sha256sums.asc signature verified"
		else
			warn "sha256sums.asc signature NOT checked (no gpg, or kernel.org"
			warn "keys not in the keyring). The checksum above still binds the"
			warn "tarball to that file; import the keys to bind the file too."
		fi
	else
		warn "could not fetch sha256sums.asc -- tarball NOT verified"
	fi
	say "unpacking"
	tar -C "$ARCH_DIR" -xf "$ARCH_DIR/$tarball"
fi
[ -f "$SRC/Makefile" ] || die "no kernel source at $SRC"

# layer 2 of the Xiaomi/MIUI USB fix (images/usb-quirks.py): the guest kernel's
# own safety net in hub_port_init(). The host layer (QEMU's usb-host) corrects
# the speed before the guest sees it; this catches what the guest latched before
# that correction existed. Both kernels this repo ships carry it: this one and
# build-uml.sh's. Old kernel shapes (5.x through 6.1) are handled too.
QUIRKS=$HERE/../usb-quirks.py
[ -f "$QUIRKS" ] || die "no images/usb-quirks.py — the Xiaomi/MIUI USB fix is applied from there"
HUB=$SRC/drivers/usb/core/hub.c
[ -f "$HUB" ] || die "no drivers/usb/core/hub.c under $SRC"
python3 "$QUIRKS" kernel-hub "$HUB"

mkdir -p "$O"

stamp="$SRC@$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo "$KVER")"
had=$(cat "$O/.stryker-source" 2>/dev/null || true)
if [ -e "$O/.config" ] || [ -n "$(ls -A "$O" 2>/dev/null)" ]; then
	if [ "$had" != "$stamp" ]; then
		say "output directory holds objects from another source -- starting clean"
		info "was ${had:-unknown}"
		info "now $stamp"
		rm -rf "$O"
		mkdir -p "$O"
	fi
fi
printf '%s\n' "$stamp" > "$O/.stryker-source"

say "configuring ($(make -C "$SRC" -s kernelversion))"
make -C "$SRC" O="$O" -j"$JOBS" defconfig >/dev/null

FRAGMENTS=("$HERE/config/vm.config" "$HERE/config/wireless.config")
[ "${TRIM:-1}" = 1 ] && FRAGMENTS+=("$HERE/config/vm-trim.config")
for extra in ${EXTRA_CONFIG:-}; do
	[ -f "$extra" ] || die "no such config fragment: $extra"
	FRAGMENTS+=("$extra")
done
"$SRC"/scripts/kconfig/merge_config.sh -m -O "$O" "$O/.config" "${FRAGMENTS[@]}" >/dev/null
make -C "$SRC" O="$O" -j"$JOBS" olddefconfig >/dev/null

say "checking the configuration took"
required=(
	VIRTIO_BLK VIRTIO_NET VIRTIO_CONSOLE NET_9P_VIRTIO 9P_FS
	SERIAL_AMBA_PL011_CONSOLE USB_XHCI_PCI USBIP_VHCI_HCD BLK_DEV_LOOP
	PACKET CFG80211 MAC80211
	RTL8XXXU RTW88_8812AU RTW88_8821AU ATH9K_HTC CARL9170 MT7601U MT76x0U
	MT76x2U RT2800USB RTL8187
)
missing=
for sym in "${required[@]}"; do
	grep -qx "CONFIG_$sym=y" "$O/.config" || missing="$missing $sym"
done
if [ -n "$missing" ]; then
	die "these did not survive olddefconfig:$missing
  Almost always an unmet dependency -- run
    make -C $SRC O=$O ARCH=arm64 menuconfig
  and search (/) for one of them to see what it now wants. Do not just drop
  it from the check: every symbol in that list is something an install fails
  on rather than fails to build."
fi
info "all ${#required[@]} required symbols are built in"

say "building Image and modules with $JOBS jobs"
make -C "$SRC" O="$O" -j"$JOBS" Image modules

release=$(make -C "$SRC" O="$O" -s kernelrelease)
info "kernel release: $release"

say "collecting"
rm -rf "$DEST/modules"
make -C "$SRC" O="$O" -j"$JOBS" INSTALL_MOD_PATH="$DEST/modules" \
	INSTALL_MOD_STRIP=1 modules_install >/dev/null
rm -f "$DEST/modules/lib/modules/$release/build" \
      "$DEST/modules/lib/modules/$release/source"

cp -f "$O/arch/arm64/boot/Image" "$DEST/Image"
cp -f "$O/.config" "$DEST/Image.config"

# The guest safety net has to be in the kernel we ship, not only in the source
# it was meant to come from (the dev_info string survives the strip: .rodata).
check_marker "$DEST/Image" "$(python3 "$QUIRKS" kernel-hub --marker)"
printf '%s\n' "$release" > "$DEST/kernel.release"
printf '%s\n' "$stamp" > "$DEST/kernel.source"
record_artifact "$DEST/Image"

printf '\n'
printf '%-22s %s\n' "Image:"   "$(human "$(stat -c%s "$DEST/Image")")"
printf '%-22s %s\n' "modules:" "$(du -sh "$DEST/modules" | cut -f1)"
printf '%-22s %s\n' "release:" "$release"
printf '%-22s %s\n' "config:"  "$DEST/Image.config"
printf '\n%s\n' "next: images/rootfs/build.sh (it installs these modules and builds the initrd)"

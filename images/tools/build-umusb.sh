#!/bin/bash
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../lib/common.sh"

if [ -z "${TREE:-}" ]; then
	for c in "$IMAGES_DIR/../../linux-um-arm64" "$IMAGES_DIR/../../mlu-arm64" \
	         "$HOME/linux-um-arm64" "$HOME/mlu-arm64"; do
		[ -f "$c/tools/um-arm64/harness/umusb.c" ] && { TREE=$c; break; }
		[ -f "$c/harness/umusb.c" ] && { TREE=$c; break; }
	done
fi
[ -n "${TREE:-}" ] || die "no tree with harness/umusb.c found. Point at the UML port:
    TREE=/path/to/linux-um-arm64 $0"
TREE=$(cd "$TREE" && pwd)

SRC=$TREE/tools/um-arm64/harness/umusb.c
[ -f "$SRC" ] || SRC=$TREE/harness/umusb.c
[ -f "$SRC" ] || die "no umusb.c under $TREE"

# The Xiaomi/MIUI USB fix, UML engine's host layer (images/usb-quirks.py).
# umusb is the USB/IP server behind the UML engine, so the speed it announces is
# the speed the guest's vhci_hcd hands to the guest's hub: the same wrong speed
# QEMU's usb-host reports on MIUI arrives here by a different road, and gets the
# same correction. The guest kernel's own safety net is kernel/build-uml.sh.
QUIRKS=$HERE/../usb-quirks.py
[ -f "$QUIRKS" ] || die "no images/usb-quirks.py — the Xiaomi/MIUI USB fix is applied from there"
need python3
python3 "$QUIRKS" umusb "$SRC"

API=${API:-30}
PAGE=${PAGE:-16384}
O=${O:-$WORK_DIR/umusb}
DEST=$OUT_DIR/uml
QEMU=${QEMU:-qemu-aarch64-static}

if [ -z "${NDK:-}" ]; then
	for c in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}" \
	         "$HOME"/Android/Sdk/ndk/* "$HOME"/Library/Android/sdk/ndk/* \
	         /usr/lib/android-ndk /opt/android-ndk* \
	         "${TMPDIR:-/tmp}"/ndk/android-ndk-*; do
		[ -n "$c" ] && [ -x "$c/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" ] && NDK=$c
	done
fi
TOOL=${NDK:-}/toolchains/llvm/prebuilt/linux-x86_64/bin
[ -x "$TOOL/clang" ] || die "no Android NDK found. Set NDK=/path/to/android-ndk-rXX"

mkdir -p "$O" "$DEST"

say "umusb (USB/IP server, bionic static)"
info "source  $SRC"
info "ndk     $NDK (API $API)"

"$TOOL/clang" --target=aarch64-linux-android$API \
	-O2 -Wall -Wextra -static \
	-ffile-prefix-map="$TREE=." \
	-Wl,-z,max-page-size="$PAGE" \
	-o "$O/umusb" "$SRC"

if "$TOOL/llvm-readelf" -l "$O/umusb" | grep -q INTERP; then
	die "the binary has a PT_INTERP: an app cannot load an interpreter"
fi
case "$(file -b "$O/umusb")" in
*"ARM aarch64"*"statically linked"*) ;;
*) die "not a static aarch64 binary: $(file -b "$O/umusb")" ;;
esac
for align in $("$TOOL/llvm-readelf" -l "$O/umusb" | awk '$1 == "LOAD" { print $NF }'); do
	[ "$((align))" -ge "$PAGE" ] \
		|| die "a LOAD segment is aligned $align, below the $PAGE page size"
done

if command -v cc >/dev/null 2>&1; then
	cc -O2 -w -o "$O/umusb_host" "$SRC"
	"$O/umusb_host" --selftest || die "the host self-test failed"
else
	warn "no host cc, native self-test skipped"
fi
if command -v "$QEMU" >/dev/null 2>&1; then
	"$QEMU" "$O/umusb" --selftest || die "the aarch64 self-test failed"
else
	warn "no $QEMU, the aarch64 self-test was skipped -- struct layouts unverified"
fi

"$TOOL/llvm-strip" "$O/umusb" 2>/dev/null || warn "llvm-strip failed; shipping unstripped"

# The host-side fix has to be in the binary we ship, not only in the source it
# was meant to come from (the string survives strip: it is .rodata, not symbols).
check_marker "$O/umusb" "$(python3 "$QUIRKS" umusb --marker)"

leak=$(grep -a -o -E '/(home|root|Users)/[A-Za-z0-9._-]+' "$O/umusb" | sort -u || true)
[ -z "$leak" ] || die "the binary carries build-machine paths:
$leak"

cp -f "$O/umusb" "$DEST/umusb"
record_artifact "$DEST/umusb"

say "done"
printf '%-22s %s\n' "umusb:" "$DEST/umusb"
printf '%-22s %s\n' "size:"  "$(human "$(stat -c%s "$DEST/umusb")")"
printf '%-22s %s\n' "sha256:" "$(sha256_of "$DEST/umusb")"
printf '\nThe app ships this as libumusb.so in jniLibs/arm64-v8a: nativeLibraryDir\n'
printf 'is the only directory an app may exec from, and it only keeps lib*.so.\n'

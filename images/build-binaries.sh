#!/bin/bash
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib/common.sh"

# Everything the app execs that does *not* come out of the kernel build:
#
#   libumnet.so  tools/build-umnet.sh    needs the arm64 UML port tree (TREE=)
#   libpasst.so  tools/build-passt.sh    upstream passt
#   libumusb.so  tools/build-umusb.sh    needs the arm64 UML port tree (TREE=)
#   libbash.so   tools/build-bash.sh     GNU bash, signature-checked
#   libqemu.so   tools/build-qemu.sh     QEMU + libslirp, vendored deps static
#   libslirp.so  tools/build-qemu.sh
#
# libuml.so and libstub.so are kernel/build-uml.sh (linux-uml, stub_exe), and the
# engine assets (Image, initrd.img, rootfs.imgz, chroot tarball, drivers) are
# images/build-all.sh. See images/BINARIES.md for what each binary is and the
# contract the app has with it.
#
# STAGE_TO_APK=1 copies the results over the copies committed in jniLibs, which is
# what .github/workflows/binaries.yml does before it commits and triggers a
# release. SKIP_<NAME>=1 skips a stage while iterating (SKIP_QEMU, SKIP_BASH, …).

REPO=$(cd "$HERE/.." && pwd)
APP_JNI=$REPO/app/src/main/jniLibs/arm64-v8a
TERM_JNI=$REPO/terminal/src/main/jniLibs/arm64-v8a
STAGE_TO_APK=${STAGE_TO_APK:-0}

started=$(date -u +%s)
mkdir -p "$OUT_DIR"

run() {
	local name=$1 script=$2
	if [ "${SKIP_ALL:-0}" = 1 ]; then
		warn "$name — skipped (SKIP_ALL=1)"
		return 0
	fi
	say "$name"
	bash "$HERE/tools/$script"
}

run "umnet (UML engine launcher)"      build-umnet.sh
run "passt (UML networking)"           build-passt.sh
run "umusb (USB/IP server)"            build-umusb.sh
run "bash (terminal shell)"            build-bash.sh
run "qemu + libslirp (rootless VM)"    build-qemu.sh

say "verifying what this produced"
# Every check below stops the run on failure, so a broken recipe cannot be
# staged into the APK. Each one is skipped when its stage was skipped.
expect_static() {   # ET_EXEC, no interpreter, 16 KB pages
	local f=$1
	[ -f "$f" ] || die "$f was not produced"
	check_static_exec "$f"
}
expect_pie() {      # a bionic PIE: libqemu.so, exec'd from nativeLibraryDir
	local f=$1
	[ -f "$f" ] || die "$f was not produced"
	check_android_pie "$f"
	check_load_align "$f"
}
expect_shared() {
	local f=$1
	[ -f "$f" ] || die "$f was not produced"
	check_load_align "$f"
}

if [ "${SKIP_ALL:-0}" = 1 ]; then
	warn "nothing was built, so there is nothing to verify"
	exit 0
fi
[ "${SKIP_UMNET:-0}" = 1 ] || expect_static "$OUT_DIR/uml/umnet"
[ "${SKIP_PASST:-0}" = 1 ] || expect_static "$OUT_DIR/uml/passt"
[ "${SKIP_UMUSB:-0}" = 1 ] || expect_static "$OUT_DIR/uml/umusb"
[ "${SKIP_BASH:-0}"  = 1 ] || expect_static "$OUT_DIR/bash/bash"
[ "${SKIP_QEMU:-0}"  = 1 ] || expect_pie    "$OUT_DIR/prebuilt/qemu-system-aarch64"
[ "${SKIP_QEMU:-0}"  = 1 ] || expect_shared "$OUT_DIR/prebuilt/libslirp.so"

printf '\n'
printf '%-26s %-12s %s\n' artifact size sha256
for f in "$OUT_DIR/uml/umnet" "$OUT_DIR/uml/passt" "$OUT_DIR/uml/umusb" \
         "$OUT_DIR/bash/bash" "$OUT_DIR/prebuilt/qemu-system-aarch64" \
         "$OUT_DIR/prebuilt/libslirp.so"; do
	[ -f "$f" ] || continue
	printf '%-26s %-12s %s\n' "$(basename "$f")" "$(human "$(stat -c%s "$f")")" \
		"$(sha256_of "$f")"
done

if [ "$STAGE_TO_APK" = 1 ]; then
	say "staging into the APK sources"
	stage() {
		local src=$1 dst=$2
		[ -f "$src" ] || { warn "not built, left as it is: $dst"; return 0; }
		cp -f "$src" "$dst"
		info "$(basename "$src") -> ${dst#$REPO/}  $(human "$(stat -c%s "$dst")")  $(sha256_of "$dst" | cut -c1-16)…"
	}
	stage "$OUT_DIR/uml/umnet"    "$APP_JNI/libumnet.so"
	stage "$OUT_DIR/uml/passt"    "$APP_JNI/libpasst.so"
	stage "$OUT_DIR/uml/umusb"    "$APP_JNI/libumusb.so"
	stage "$OUT_DIR/bash/bash"    "$TERM_JNI/libbash.so"
	stage "$OUT_DIR/prebuilt/qemu-system-aarch64" "$APP_JNI/libqemu.so"
	stage "$OUT_DIR/prebuilt/libslirp.so"         "$APP_JNI/libslirp.so"
	printf '\n%s\n' "next: git add app/src/main/jniLibs terminal/src/main/jniLibs"
	printf '%s\n' "      (the engine assets and stryker_manifest.json come from images/publish.sh)"
fi

elapsed=$(( $(date -u +%s) - started ))
say "done in $((elapsed / 60))m $((elapsed % 60))s"

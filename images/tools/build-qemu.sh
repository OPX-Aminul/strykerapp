#!/bin/bash
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../lib/common.sh"

# QEMU is the rootless engine's machine. The app execs it straight out of its
# nativeLibraryDir, so it is an ordinary Android bionic binary — from the shipped
# libqemu.so (see images/BINARIES.md):
#
#   DYN (PIE), PT_INTERP /system/bin/linker64
#   NEEDED: libslirp.so, libz.so, libm.so, libdl.so, libc.so
#   LOAD alignment 0x4000 / 0x10000, no debug info
#   strings: /qemu-11.0.2/… (so it was built from that release tarball, unpacked
#            at /qemu-11.0.2), libusb's wrap_sys_device (= --enable-libusb, the
#            usb-host backend UsbPassthroughManager drives over QMP), 9pfs
#            (= --enable-virtfs), glib 2.89.x and pixman linked IN
#
# So: glib, pcre2, libffi, pixman and libusb are static here, libslirp is shared
# next to it, and zlib/libm/libdl/libc come from Android. Nothing else may appear
# in NEEDED — the checks at the end fail the build if it does.
#
# STAGE=deps|libslirp|qemu|all lets CI iterate on one stage at a time; every
# stage caches under $O, so a rerun only rebuilds what changed.

QEMU_VER=${QEMU_VER:-11.0.2}            # read off the shipped binary: /qemu-11.0.2/
GLIB_VER=${GLIB_VER:-2.89.1}            # read off the shipped binary (a version string)
PCRE2_VER=${PCRE2_VER:-10.45}
LIBFFI_VER=${LIBFFI_VER:-3.4.6}
PIXMAN_VER=${PIXMAN_VER:-0.46.4}        # read off the shipped binary (a version string)
LIBUSB_VER=${LIBUSB_VER:-1.0.28}
SLIRP_VER=${SLIRP_VER:-4.9.0}

API=${API:-30}
PAGE=${PAGE:-16384}
STAGE=${STAGE:-all}
O=${O:-$WORK_DIR/qemu}
SRCS=$O/src
PREFIX=$O/prefix
DEST=$OUT_DIR/prebuilt
# meson needs a cross file; it is written just below the functions, before any
# stage runs, and every meson setup points at it with --cross-file.
CROSS=$O/meson-cross-aarch64-android$API.txt

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

need curl tar pkg-config meson ninja make python3
mkdir -p "$O" "$SRCS" "$PREFIX" "$DEST"

# The Xiaomi/MIUI USB fix (images/usb-quirks.py). Every engine that can hand a
# USB device to a guest has its own host side, so each gets the same correction
# applied to its own source: QEMU here, umusb in tools/build-umusb.sh, and the
# guest kernel's safety net in both kernel scripts. A tree whose source has
# changed shape stops the build instead of shipping an unfixed binary.
QUIRKS=$HERE/../usb-quirks.py
[ -f "$QUIRKS" ] || die "no images/usb-quirks.py — the Xiaomi/MIUI USB fix is applied from there"

TARGET=aarch64-linux-android$API
CC_WRAP="$TOOL/clang --target=$TARGET"
# The shipped binary's source paths are /qemu-11.0.2/…, and a build directory
# under /home would otherwise be embedded in every __FILE__ string.
MAP_COMMON=(-fPIC -O2 -fno-strict-aliasing -fno-omit-frame-pointer
            -ffile-prefix-map="$SRCS=."
            -ffile-prefix-map="$NDK=/ndk"
            -ffile-prefix-map="$PWD=."
            -fdebug-compilation-dir=.
            "-Wl,-z,max-page-size=$PAGE")

say "qemu $QEMU_VER + libslirp $SLIRP_VER for android-$API (page $PAGE)"
info "ndk     $NDK"
info "prefix  $PREFIX (static glib/pcre2/libffi/pixman/libusb)"

fetch() {
	local name=$1 url=$2
	local tarball
	tarball=$O/$(basename "$url")
	[ -f "$tarball" ] || curl -fL --retry 3 -sS -o "$tarball" "$url"
	rm -rf "${SRCS:?}/$name"
	mkdir -p "$SRCS/$name"
	tar xf "$tarball" -C "$SRCS/$name" --strip-components=1
	info "$name  $(basename "$url")  $(sha256_of "$tarball" | cut -c1-16)…"
}

# ---------------------------------------------------------------------------
deps() {
	need autoconf automake libtool

	say "libffi $LIBFFI_VER (static)"
	if [ ! -f "$PREFIX/lib/libffi.a" ]; then
		fetch libffi "https://github.com/libffi/libffi/releases/download/v$LIBFFI_VER/libffi-$LIBFFI_VER.tar.gz"
		cd "$SRCS/libffi"
		./configure --host=aarch64-linux-android --build="$(gcc -dumpmachine)" \
			--prefix="$PREFIX" --enable-static --disable-shared --disable-docs \
			CC="$CC_WRAP" AR="$TOOL/llvm-ar" RANLIB="$TOOL/llvm-ranlib" \
			CFLAGS="${MAP_COMMON[*]}" LDFLAGS="-static"
		make -j"$(nproc)" install
	fi

	say "pcre2 $PCRE2_VER (static)"
	if [ ! -f "$PREFIX/lib/libpcre2-8.a" ]; then
		fetch pcre2 "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VER/pcre2-$PCRE2_VER.tar.gz"
		cd "$SRCS/pcre2"
		./configure --host=aarch64-linux-android --build="$(gcc -dumpmachine)" \
			--prefix="$PREFIX" --enable-static --disable-shared \
			--disable-pcre2grep --disable-pcre2test --enable-pcre2-8 \
			CC="$CC_WRAP" AR="$TOOL/llvm-ar" RANLIB="$TOOL/llvm-ranlib" \
			CFLAGS="${MAP_COMMON[*]}" LDFLAGS="-static"
		make -j"$(nproc)" install
	fi

	say "pixman $PIXMAN_VER (static)"
	if [ ! -f "$PREFIX/lib/libpixman-1.a" ]; then
		fetch pixman "https://www.cairographics.org/releases/pixman-$PIXMAN_VER.tar.gz"
		meson setup "$O/b-pixman" "$SRCS/pixman" --cross-file "$CROSS" \
			--prefix="$PREFIX" --default-library=static \
			-Dtests=disabled -Ddemos=disabled
		ninja -C "$O/b-pixman" install
	fi

	say "glib $GLIB_VER (static)"
	if [ ! -f "$PREFIX/lib/libglib-2.0.a" ]; then
		fetch glib "https://download.gnome.org/sources/glib/${GLIB_VER%.*}/glib-$GLIB_VER.tar.xz"
		meson setup "$O/b-glib" "$SRCS/glib" --cross-file "$CROSS" \
			--prefix="$PREFIX" --default-library=static \
			-Dtests=false -Dglib_debug=disabled -Dselinux=disabled \
			-Dlibmount=disabled -Dman-pages=disabled -Ddocumentation=false \
			-Ddtrace=disabled -Dsystemtap=disabled -Dintrospection=disabled
		ninja -C "$O/b-glib" install
	fi

	say "libusb $LIBUSB_VER (static, the usb-host backend)"
	if [ ! -f "$PREFIX/lib/libusb-1.0.a" ]; then
		fetch libusb "https://github.com/libusb/libusb/releases/download/v$LIBUSB_VER/libusb-$LIBUSB_VER.tar.bz2"
		cd "$SRCS/libusb"
		./autogen.sh 2>/dev/null || true
		./configure --host=aarch64-linux-android --build="$(gcc -dumpmachine)" \
			--prefix="$PREFIX" --enable-static --disable-shared --disable-udev \
			CC="$CC_WRAP" AR="$TOOL/llvm-ar" RANLIB="$TOOL/llvm-ranlib" \
			CFLAGS="${MAP_COMMON[*]}" LDFLAGS="-static"
		make -j"$(nproc)" install
	fi
}

libslirp() {
	say "libslirp $SLIRP_VER (shared, glib linked in)"
	fetch libslirp "https://gitlab.freedesktop.org/slirp/libslirp/-/archive/v$SLIRP_VER/libslirp-v$SLIRP_VER.tar.gz"
	meson setup "$O/b-slirp" "$SRCS/libslirp" --cross-file "$CROSS" \
		--prefix="$PREFIX" --default-library=shared \
		-Dtests=false -Ddocumentation=false 2>/dev/null \
		|| meson setup "$O/b-slirp" "$SRCS/libslirp" --cross-file "$CROSS" \
			--prefix="$PREFIX" --default-library=shared
	ninja -C "$O/b-slirp" install

	SO=$PREFIX/lib/libslirp.so
	[ -f "$SO" ] || die "libslirp did not install a shared library"
	# The shipped libslirp.so needs libc only: glib is statically inside it.
	check_needed_absent "$SO" libglib-2.0.so.0 libpixman-1.so.0
	for align in $("$READELF" -l "$SO" | awk '$1 == "LOAD" { print $NF }'); do
		[ "$((align))" -ge "$PAGE" ] || die "libslirp: a LOAD segment is aligned $align"
	done
	cp -f "$SO" "$DEST/libslirp.so"
	record_artifact "$DEST/libslirp.so"
	report_binary "$DEST/libslirp.so"
}

qemu() {
	say "qemu $QEMU_VER (aarch64-softmmu, TCG, virtfs, libusb, slirp)"
	fetch qemu "https://download.qemu.org/qemu-$QEMU_VER.tar.xz"
	cd "$SRCS/qemu"

	# Xiaomi/MIUI's host stack reports a full-speed device as low-speed while
	# the device's own descriptor still says the ep0 maxpacket is 64, which is
	# what the guest refuses. This is the host side of the fix: correct the
	# speed in the control-transfer completion, before the guest reads it.
	python3 "$QUIRKS" qemu-host-libusb hw/usb/host-libusb.c

	export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
	export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
	export PKG_CONFIG_SYSROOT_DIR=

	# What this build must have: TCG (no KVM on a phone), the virt machine's
	# virtio/xhci/9p devices, slirp for -netdev user, libusb for usb-host, an
	# internal libfdt, and zlib. Everything else is off: Android has none of the
	# usual host dependencies (glibc, libaio, libcap-ng, libattr, spice, gtk) and
	# the app needs none of the features that would pull them in.
	WANT=(
		--cross-prefix="$TOOL/llvm-"
		--cc="$CC_WRAP" --cxx="$TOOL/clang++ --target=$TARGET"
		--ar="$TOOL/llvm-ar" --ranlib="$TOOL/llvm-ranlib" --strip="$TOOL/llvm-strip"
		--target-list=aarch64-softmmu --prefix=/usr/local
		--enable-system --disable-user
		--enable-tcg
		--enable-slirp --enable-libusb --enable-virtfs --enable-fdt=internal --enable-zlib
		--disable-guest-agent --disable-tools --disable-docs --disable-werror
		--disable-gtk --disable-sdl --disable-vnc --disable-spice --disable-curses
		--disable-opengl --disable-brlapi --disable-glusterfs --disable-libssh
		--disable-curl --disable-nettle --disable-gnutls --disable-gcrypt
		--disable-linux-aio --disable-attr --disable-cap-ng --disable-rdma
		--disable-vhost-user --disable-vhost-vdpa --disable-xen --disable-kvm
		--disable-bpf --disable-tpm --disable-seccomp --disable-dbus-display
		--extra-cflags="-O2 ${MAP_COMMON[*]} -I$PREFIX/include -ffile-prefix-map=$SRCS/qemu=/qemu-$QEMU_VER"
		--extra-ldflags="-L$PREFIX/lib -Wl,-z,max-page-size=$PAGE -ffile-prefix-map=$SRCS/qemu=/qemu-$QEMU_VER"
	)

	# Options come and go between QEMU releases; drop the ones this release does
	# not know rather than letting configure stop on an unknown --disable-*.
	./configure --help > "$O/qemu-configure-help.txt" 2>&1 || true
	FLAGS=()
	for f in "${WANT[@]}"; do
		case "$f" in
		--enable-*|--disable-*)
			base=${f%%=*}
			alt=$(printf '%s' "$base" | sed 's/^--enable-/--disable-/; s/^--disable-/--enable-/')
			if grep -q -- "$base" "$O/qemu-configure-help.txt" \
			   || grep -q -- "$alt" "$O/qemu-configure-help.txt"; then
				FLAGS+=("$f")
			else
				info "dropped (not in this release's configure): $f"
			fi
			;;
		*) FLAGS+=("$f") ;;
		esac
	done

	./configure "${FLAGS[@]}"

	make -j"$(nproc)" qemu-system-aarch64

	BIN=$SRCS/qemu/build/qemu-system-aarch64
	[ -f "$BIN" ] || die "configure/make reported success but there is no qemu-system-aarch64"

	say "checking what was built"
	check_android_pie "$BIN"
	check_marker "$BIN" "wrap_sys_device"
	check_marker "$BIN" "/qemu-$QEMU_VER/"
	# The Xiaomi/MIUI host-side fix must be *in the binary we are about to ship*,
	# not just in the source it was meant to come from.
	check_marker "$BIN" "$(python3 "$QUIRKS" qemu-host-libusb --marker)"
	check_no_build_paths "$BIN"
	check_needed_absent "$BIN" libglib-2.0.so.0 libpixman-1.so.0 libusb-1.0.so.0
	NEEDED=$("$READELF" -d "$BIN" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | sort)
	printf '%s\n' "$NEEDED" | grep -qx "libslirp.so" \
		|| die "qemu does not link libslirp.so: the app's -netdev user cannot work"
	for align in $("$READELF" -l "$BIN" | awk '$1 == "LOAD" { print $NF }'); do
		[ "$((align))" -ge "$PAGE" ] || die "qemu: a LOAD segment is aligned $align, below $PAGE"
	done
	info "NEEDED: $(printf '%s ' "$NEEDED")"

	# The app execs this as libqemu.so from nativeLibraryDir and needs
	# libslirp.so next to it (RootlessEngine sets LD_LIBRARY_PATH to that dir).
	cp -f "$BIN" "$DEST/qemu-system-aarch64"
	record_artifact "$DEST/qemu-system-aarch64"
	report_binary "$DEST/qemu-system-aarch64"
}

# ---------------------------------------------------------------------------
cat > "$CROSS" <<EOF
[binaries]
c = '$TOOL/clang'
cpp = '$TOOL/clang++'
ar = '$TOOL/llvm-ar'
strip = '$TOOL/llvm-strip'
pkgconfig = '$(command -v pkg-config)'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[built-in options]
c_args = ['--target=$TARGET', '${MAP_COMMON[0]}', '-fno-strict-aliasing', '-ffile-prefix-map=$SRCS=.', '-ffile-prefix-map=$NDK=/ndk', '-ffile-prefix-map=$PWD=.', '-fdebug-compilation-dir=.', '-I$PREFIX/include']
c_link_args = ['--target=$TARGET', '-L$PREFIX/lib', '-Wl,-z,max-page-size=$PAGE']
EOF

case "$STAGE" in
all)      deps; libslirp; qemu ;;
deps)     deps ;;
libslirp) libslirp ;;
qemu)     qemu ;;
*)        die "STAGE must be deps, libslirp, qemu or all (got $STAGE)" ;;
esac

say "done"
printf 'prebuilt/  %s\n' "$DEST"
ls -l "$DEST" | sed 's/^/   /'
printf '\nThe APK ships these as jniLibs/arm64-v8a/libqemu.so and libslirp.so;\n'
printf 'images/publish.sh uploads them to the rootless release tag as\n'
printf 'qemu-system-aarch64 and libslirp.so.\n'
printf '\nThis is the stage most likely to need a first-run fix: the version of each\n'
printf 'vendored dependency is an input (QEMU_VER, GLIB_VER, PIXMAN_VER, LIBUSB_VER,\n'
printf 'SLIRP_VER, PCRE2_VER, LIBFFI_VER) and configure is the part of QEMU that\n'
printf 'changes between releases. The checks above fail loudly rather than shipping\n'
printf 'a binary the app cannot load.\n'

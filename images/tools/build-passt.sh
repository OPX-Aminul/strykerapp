#!/bin/bash
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../lib/common.sh"

# passt is the userspace network stack the UML guest reaches the phone through.
# umnet starts it ("umnet: exec passt", "./passt" in its strings) and forwards
# 127.0.0.1:2222 to the guest's 22, which is how the app's ssh session and the
# guest agent get in.
#
# Measured from the shipped libpasst.so: static ET_EXEC, no interpreter, 16 KB
# (0x4000) LOAD alignment, strings contain upstream passt's netlink/seccomp
# messages and "Copyright Red Hat".
#
# The version string it carries is "defc25b-bionic", which is exactly what the
# arm64 UML port's own build produces:
#
#     VERSION=$(git -C "$SRC" describe --tags --always HEAD)-bionic
#
# so "defc25b" is the passt commit the shipped helpers were built from (the
# checkout had no tags, which is why --always fell back to the sha). That string
# is embedded below for the same reason, and $OUT_DIR/passt.txt records the ref
# that was resolved so a published binary can be traced back to its source.

PASST_REF=${PASST_REF:-main}
PASST_GIT=${PASST_GIT:-https://passt.top/passt}
PASST_TARBALL=${PASST_TARBALL:-}     # e.g. https://passt.top/passt/snapshot/passt-<tag>.tar.gz

API=${API:-30}
PAGE=${PAGE:-16384}
DEBUG=${DEBUG:-1}
O=${O:-$WORK_DIR/passt}
DEST=$OUT_DIR/uml

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

if [ "$PASST_REF" = main ] && [ -z "$PASST_TARBALL" ]; then
	warn "PASST_REF is not pinned to a tag: $PASST_GIT $PASST_REF is whatever HEAD"
	warn "is today. Set PASST_REF=/PASST_TARBALL= to a release so the build repeats."
fi

mkdir -p "$O" "$DEST"
SRC=$O/src

say "passt $PASST_REF (bionic static, aarch64)"
info "ndk     $NDK (API $API, page $PAGE)"

if [ -n "$PASST_TARBALL" ]; then
	need curl tar
	[ -f "$O/passt.tar.gz" ] || curl -fL --retry 3 -sS -o "$O/passt.tar.gz" "$PASST_TARBALL"
	info "tarball sha256 $(sha256_of "$O/passt.tar.gz")"
	rm -rf "$SRC"
	mkdir -p "$SRC"
	tar xf "$O/passt.tar.gz" -C "$SRC" --strip-components=1
else
	need git
	if [ ! -d "$SRC/.git" ]; then
		rm -rf "$SRC"
		git clone --quiet --depth 1 --branch "$PASST_REF" "$PASST_GIT" "$SRC" 2>/dev/null \
			|| git clone --quiet "$PASST_GIT" "$SRC"
	fi
	git -C "$SRC" fetch --quiet --depth 1 origin "$PASST_REF" 2>/dev/null || true
	git -C "$SRC" checkout --quiet "$PASST_REF" 2>/dev/null || true
fi

COMMIT=$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo "not a git checkout")
info "commit  $COMMIT"
[ "$COMMIT" = "not a git checkout" ] && [ -z "$PASST_TARBALL" ] \
	&& die "could not resolve a commit for $PASST_REF — pin PASST_REF to a tag or a sha"

# passt's own Makefile: `make passt` links every .c except the pasta/qrap entry
# points. It wants GNU userspace headers (netlink, seccomp, ethernet, arp), which
# the NDK ships in its sysroot; if one is missing the compile below names it.
# Three things can put a build-machine path in here: the source tree, the NDK's
# sysroot headers (every #include lands in the debug line table) and
# DW_AT_comp_dir, the compiler's working directory. The shipped libpasst.so
# carries none of them and check_no_build_paths() below requires that, so all
# three are mapped -- the source tree alone leaves /home/runner/... behind.
CFLAGS_EXTRA=(-O2 -fno-strict-aliasing -static
              -ffile-prefix-map="$SRC=."
              -ffile-prefix-map="$NDK=/ndk"
              -ffile-prefix-map="$PWD=."
              -fdebug-compilation-dir=.
              "-Wl,-z,max-page-size=$PAGE")
if [ "$DEBUG" = 1 ]; then
	CFLAGS_EXTRA+=(-g -gdwarf-4)
else
	CFLAGS_EXTRA+=(-g0)
fi

# VERSION is what the shipped libpasst.so carries ("defc25b-bionic"): the port
# tree builds passt as "$(git describe --tags --always HEAD)-bionic", so keeping
# the same shape is what makes a rebuild comparable with the released file.
PASST_VERSION=$(git -C "$SRC" describe --tags --always HEAD 2>/dev/null || echo "")
if [ -z "$PASST_VERSION" ] && [ -n "$PASST_TARBALL" ]; then
	PASST_VERSION=$(basename "$PASST_TARBALL" .tar.gz)
fi
[ -n "$PASST_VERSION" ] || PASST_VERSION=unknown
info "version $PASST_VERSION-bionic"

# A checkout that has already been built still holds those outputs, and make
# would reuse a seccomp.h generated for another architecture -- whose AUDIT_ARCH
# check kills passt on its first syscall in the guest. Delete and regenerate.
rm -f "$SRC/passt" "$SRC/pasta" "$SRC/passt.avx2" "$SRC/pasta.avx2" \
      "$SRC/seccomp.h" "$SRC/seccomp_repair.h" "$SRC/seccomp_pesto.h"

# Issue #135: passt's isolate_fds() closes leaked descriptors with
# close_range(2). On hosts whose seccomp policy kills that syscall with SIGSYS
# instead of returning ENOSYS -- every Android release before 11 does it, seen
# as "passt: SIGSYS on syscall 436" followed by "passt exited 90" -- the real
# call never returns, so no error handling in passt can help. Define the symbol
# in an object linked ahead of libc: passt's one call then closes by hand and
# never enters the kernel. First object wins the symbol and the archive member
# in libc is not pulled for it; passt's own filter is generated from the binary,
# which now uses plain close()/fcntl() both of which it allows.
SHIM_C=$O/close_range-shim.c
cat > "$SHIM_C" <<'EOF'
/*
 * close_range emulated by hand.
 *
 * passt's startup closes leaked descriptors with close_range(2) (isolation.c,
 * isolate_fds()). On hosts whose seccomp policy kills the raw syscall instead
 * of returning ENOSYS -- every Android release before 11 does this, reported
 * as "passt: SIGSYS on syscall 436" in issue #135 -- the real call never
 * returns, so no amount of error handling in passt can save it. Define the
 * symbol here, ahead of libc on the link line, so passt's call never enters
 * the kernel: close by hand instead.
 *
 * CLOSE_RANGE_UNSHARE: isolate_fds() runs before passt starts any thread, so
 * the descriptor table is unshared and closing in place is equivalent.
 * CLOSE_RANGE_CLOEXEC is honoured too, for anything else that ends up here.
 */
#include <errno.h>
#include <fcntl.h>
#include <sys/resource.h>
#include <unistd.h>

#ifndef CLOSE_RANGE_UNSHARE
#define CLOSE_RANGE_UNSHARE (1U << 1)
#endif
#ifndef CLOSE_RANGE_CLOEXEC
#define CLOSE_RANGE_CLOEXEC (1U << 2)
#endif

const char close_range_shim_marker[] =
	"close_range: emulated by hand (the host seccomp kills the real one)";

int close_range(unsigned int first, unsigned int last, unsigned int flags)
{
	struct rlimit rl;
	unsigned long end = last;
	unsigned long fd;

	if (first > last ||
	    (flags & ~(CLOSE_RANGE_UNSHARE | CLOSE_RANGE_CLOEXEC))) {
		errno = EINVAL;
		return -1;
	}

	/* Nothing above the soft limit can be open, and last may be ~0U. */
	if (getrlimit(RLIMIT_NOFILE, &rl) == 0 &&
	    rl.rlim_cur != RLIM_INFINITY && end >= rl.rlim_cur)
		end = rl.rlim_cur ? rl.rlim_cur - 1 : 0;

	for (fd = first; fd <= end; fd++) {
		if (flags & CLOSE_RANGE_CLOEXEC)
			fcntl((int)fd, F_SETFD, FD_CLOEXEC);
		else
			close((int)fd);
	}
	return 0;
}
EOF
"$TOOL/clang" --target=aarch64-linux-android$API -O2 -Wall -Wextra -c \
	-o "$O/close_range-shim.o" "$SHIM_C" \
	|| die "the close_range shim did not compile"

say "building"
# ARCH and TARGET are not cosmetic. The Makefile derives both from
# `$(CC) -dumpmachine`, which for an NDK driver reports the *host*, and ARCH in
# particular feeds seccomp.sh, which turns it into the AUDIT_ARCH_* the generated
# filter checks against: left alone, passt installs an x86_64 filter and is killed
# by SIGSYS at its first syscall inside the app. PAGE_SIZE is baked in from the
# build host's getconf for the same reason, and a value smaller than the target's
# under-aligns what passt aligns with it.
make -C "$SRC" -j"$(nproc)" passt \
	CC="$TOOL/clang --target=aarch64-linux-android$API" \
	ARCH=aarch64 TARGET=aarch64-linux-android \
	VERSION="$PASST_VERSION-bionic" \
	CFLAGS="${CFLAGS_EXTRA[*]}" \
	CPPFLAGS="-UPAGE_SIZE -DPAGE_SIZE=$PAGE" \
	LDFLAGS="-static -Wl,-z,max-page-size=$PAGE $O/close_range-shim.o" \
	LDLIBS="" \
	|| die "passt did not build. The usual causes, in order:
   - a linux/ header the NDK does not ship (the error names it; passt needs the
     netlink, seccomp, ethernet, arp and tcp/udp uapi headers)
   - the Makefile's glibc assumptions; pass them through CFLAGS_EXTRA above"

BIN=$SRC/passt
[ -f "$BIN" ] || BIN=$O/passt
[ -f "$BIN" ] || die "the build reported success but there is no passt binary"

say "checking what was built"
check_static_exec "$BIN" "$PAGE"
check_marker "$BIN" "Failed to apply seccomp filter"
check_marker "$BIN" "Copyright Red Hat"
# The Android < 11 close_range shim has to be in the binary we ship.
check_marker "$BIN" "close_range: emulated by hand"
check_no_build_paths "$BIN"

if [ "${STRIP:-0}" = 1 ]; then
	"$TOOL/llvm-strip" -o "$O/passt.stripped" "$BIN"
	BIN=$O/passt.stripped
	info "stripped (the shipped libpasst.so keeps its symbols, so this is not the default)"
fi

cp -f "$BIN" "$DEST/passt"
record_artifact "$DEST/passt"
{
	printf 'passt\n'
	printf 'ref      %s\n' "$PASST_REF"
	printf 'commit   %s\n' "$COMMIT"
	printf 'ndk      %s\n' "$NDK"
	printf 'api      %s\n' "$API"
	printf 'debug    %s\n' "$DEBUG"
} > "$OUT_DIR/passt.txt"

say "done"
report_binary "$DEST/passt"
printf '\nThe APK ships this as jniLibs/arm64-v8a/libpasst.so; umnet is started\n'
printf 'with --passt <that path>. Build info: %s\n' "$OUT_DIR/passt.txt"

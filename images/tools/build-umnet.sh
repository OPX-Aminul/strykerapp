#!/bin/bash
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../lib/common.sh"

# umnet is the launcher the app runs for the UML engine (images/BINARIES.md):
#
#   libumnet.so --passt <libpasst.so> --fwd 127.0.0.1/2222:22 -- libuml.so mem=…M …
#
# It starts passt and the guest kernel, wires their sockets together, and is the
# thing that reports on the console when either of them dies — "umnet: passt
# exited %d", "umnet: kernel killed by signal %d (%s)" — which is what
# BootDiagnosis reads when a boot fails.
#
# The source lives in the arm64 UML port's harness, next to the umusb.c that
# tools/build-umusb.sh builds. Nothing here guesses its file name: the launcher
# is found by looking for the harness C file that parses --passt. The address
# space stub is *not* built here — it is arch/um/kernel/skas/stub_exe out of the
# kernel build (images/kernel/build-uml.sh), and the APK ships that as
# libstub.so.
#
# Measured from the shipped libumnet.so: static ET_EXEC, no interpreter, 16 KB
# (0x4000) LOAD alignment, NDK r27 clang 18.0.x, API 30, DWARF + .symtab kept
# (app/build.gradle lists it in keepDebugSymbols).

if [ -z "${TREE:-}" ]; then
	for c in "$IMAGES_DIR/../../linux-um-arm64" "$IMAGES_DIR/../../mlu-arm64" \
	         "$HOME/linux-um-arm64" "$HOME/mlu-arm64"; do
		[ -d "$c/tools/um-arm64/harness" ] && { TREE=$c; break; }
		[ -d "$c/harness" ] && { TREE=$c; break; }
	done
fi
[ -n "${TREE:-}" ] || die "no arm64 UML port tree found. Point at it:
    TREE=/path/to/linux-um-arm64 $0"
TREE=$(cd "$TREE" && pwd)

HARNESS=
for d in "$TREE/tools/um-arm64/harness" "$TREE/harness"; do
	[ -d "$d" ] && { HARNESS=$d; break; }
done
[ -n "$HARNESS" ] || die "no harness directory under $TREE (looked for
  tools/um-arm64/harness/ and harness/)"

# The launcher is whichever harness source parses the app's --passt /
# --fwd options; that is the marker umnet itself carries.
UMNET_SRC=${UMNET_SRC:-}
if [ -z "$UMNET_SRC" ]; then
	while IFS= read -r f; do
		if grep -q -- '--passt' "$f" && grep -q 'passt exited' "$f"; then
			UMNET_SRC=$f
			break
		fi
	done < <(ls -1 "$HARNESS"/*.c 2>/dev/null)
fi
[ -n "$UMNET_SRC" ] && [ -f "$UMNET_SRC" ] || die "no harness source in $HARNESS parses --passt and reports
  'passt exited' — that file is umnet. What is there:
$(ls -1 "$HARNESS" 2>/dev/null | sed 's/^/    /')
  If the launcher is split up or named differently, pass UMNET_SRC=<path>."

# umnet may be more than one translation unit; UMNET_EXTRA is a space-separated
# list of further .c files, relative to the harness directory.
EXTRA_SRCS=()
for extra in ${UMNET_EXTRA:-}; do
	[ -f "$HARNESS/$extra" ] || die "UMNET_EXTRA=$extra: no such file in $HARNESS"
	EXTRA_SRCS+=("$HARNESS/$extra")
done

API=${API:-30}
PAGE=${PAGE:-16384}
DEBUG=${DEBUG:-1}          # the shipped libumnet.so keeps DWARF
O=${O:-$WORK_DIR/umnet}
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

mkdir -p "$O" "$DEST"

# The shipped libumnet.so carries no build-machine path, and there are three
# places one can enter a binary this size: the tree the source came from, the
# NDK's own sysroot headers (every #include in the debug line table), and
# DW_AT_comp_dir, which is the compiler's working directory. Mapping only the
# tree leaves /home/runner/... in the NDK paths and the compilation directory,
# which check_no_build_paths() then (correctly) refuses.
CFLAGS=(-O2 -Wall -Wextra -static
        -ffile-prefix-map="$TREE=."
        -ffile-prefix-map="$NDK=/ndk"
        -ffile-prefix-map="$PWD=."
        -fdebug-compilation-dir=.
        "-Wl,-z,max-page-size=$PAGE")
if [ "$DEBUG" = 1 ]; then
	CFLAGS+=(-g -gdwarf-4)
else
	CFLAGS+=(-g0)
fi

say "umnet (UML engine launcher, bionic static)"
info "tree    $TREE"
info "source  $UMNET_SRC${EXTRA_SRCS+ ${EXTRA_SRCS[*]}}"
info "ndk     $NDK (API $API, page $PAGE)"
info "commit  $(git -C "$TREE" rev-parse --short HEAD 2>/dev/null || echo 'not a git checkout')"

"$TOOL/clang" --target=aarch64-linux-android$API "${CFLAGS[@]}" \
	-o "$O/umnet" "$UMNET_SRC" ${EXTRA_SRCS+"${EXTRA_SRCS[@]}"}

say "checking what was built"
check_static_exec "$O/umnet" "$PAGE"
check_marker "$O/umnet" "umnet: passt exited"
check_marker "$O/umnet" "umnet: kernel killed by signal"
check_no_build_paths "$O/umnet"

# These are the options UmlEngine.buildCommand() drives; a build without one of
# them is not the launcher the app knows how to start.
for flag in --passt --fwd --mac --gw --iface --isolate-loopback --verbose; do
	grep -aq -- "$flag" "$O/umnet" || die "the built umnet has no $flag option"
done
info "all app-facing umnet flags are present"

if [ "${STRIP:-0}" = 1 ]; then
	"$TOOL/llvm-strip" "$O/umnet"
	info "stripped (the shipped libumnet.so keeps its symbols, so this is not the default)"
fi

cp -f "$O/umnet" "$DEST/umnet"
record_artifact "$DEST/umnet"

{
	printf 'umnet\n'
	printf 'tree     %s\n' "$TREE"
	printf 'source   %s\n' "$UMNET_SRC"
	printf 'commit   %s\n' "$(git -C "$TREE" rev-parse HEAD 2>/dev/null || echo 'not a git checkout')"
	printf 'ndk      %s\n' "$NDK"
	printf 'api      %s\n' "$API"
	printf 'debug    %s\n' "$DEBUG"
} > "$OUT_DIR/umnet.txt"

say "done"
report_binary "$DEST/umnet"
printf '\nThe APK ships this as jniLibs/arm64-v8a/libumnet.so. Build info: %s\n' \
	"$OUT_DIR/umnet.txt"
printf 'libstub.so and libuml.so are the kernel build: images/kernel/build-uml.sh\n'
printf 'produces linux-uml and stub_exe, the APK renames them when it packages.\n'

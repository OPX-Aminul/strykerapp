# shellcheck shell=bash
# Sourced by every build script under images/, never executed on its own.
IMAGES_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT_DIR=${OUT_DIR:-$IMAGES_DIR/out}
WORK_DIR=${WORK_DIR:-$IMAGES_DIR/work}

say()  { printf '\n== %s ==\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '   ! %s\n' "$*" >&2; }
die()  { printf '%s: %s\n' "${0##*/}" "$*" >&2; exit 2; }

need() {
	local missing=
	for t in "$@"; do
		command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
	done
	[ -z "$missing" ] || die "missing tools:$missing"
}

need_root() {
	[ "$(id -u)" = 0 ] || die "run as root: this mounts loop devices and makes device nodes"
}

export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-stryker}
export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-images}
export KBUILD_BUILD_TIMESTAMP=${KBUILD_BUILD_TIMESTAMP:-"Thu Jan  1 00:00:00 UTC 1970"}
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}

GZ_JOBS=${GZ_JOBS:-8}
gz() {
	if command -v pigz >/dev/null 2>&1; then
		pigz -9 -n -b 128 -p "$GZ_JOBS" "$@"
	else
		gzip -9n "$@"
	fi
}

deterministic_tar() {
	local out=$1 dir=$2
	shift 2
	tar --create \
	    --directory="$dir" \
	    --owner=root --group=root --numeric-owner \
	    --mtime="@${SOURCE_DATE_EPOCH}" \
	    --sort=name \
	    --format=gnu \
	    "$@" . | gz > "$out"
}

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

record_artifact() {
	local file=$1
	mkdir -p "$OUT_DIR"
	printf '%s\t%s\t%s\n' "$(basename "$file")" "$(sha256_of "$file")" \
		"$(stat -c%s "$file")" >> "$OUT_DIR/artifacts.tsv"
}

human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1"; }

# ---------------------------------------------------------------------------
# Binary checks shared by the tools/ build scripts. The app may only exec from
# its nativeLibraryDir, so a static ET_EXEC with no interpreter is the rule for
# everything that is not linked against bionic (QEMU is, and is a PIE).

READELF=${READELF:-}
if [ -z "$READELF" ]; then
	if [ -n "${TOOL:-}" ] && [ -x "$TOOL/llvm-readelf" ]; then
		READELF=$TOOL/llvm-readelf
	else
		READELF=readelf
	fi
fi

elf_phdr() {
	# Wide output, or GNU readelf wraps the address columns onto a second line
	# and "the last field of a LOAD line" is no longer the alignment.
	local f=$1
	"$READELF" -lW "$f" 2>/dev/null || "$READELF" -l "$f"
}

# These checks read the output of a tool first and search the string afterwards.
# Piping the tool straight into `grep -q` looks equivalent and is not: grep exits
# at the first match, the tool is killed by SIGPIPE, and because these scripts run
# with `set -o pipefail` the pipeline reports failure even though the pattern was
# found -- the check silently answers "not there" for every binary, which is
# exactly the binary it was written to reject.
has_phdr() {
	local out
	out=$(elf_phdr "$1")
	grep -q -- "$2" <<<"$out"
}

check_static_exec() {
	local f=$1 page=${2:-16384} align machine
	[ -f "$f" ] || die "no such file: $f"
	if has_phdr "$f" INTERP; then
		die "$(basename "$f") has a PT_INTERP: an app cannot load an interpreter"
	fi
	if has_phdr "$f" DYNAMIC; then
		die "$(basename "$f") has a PT_DYNAMIC: it is not statically linked"
	fi
	machine=$("$READELF" -h "$f" | awk '/Machine:/ {print $2}')
	case $machine in
	AArch64*) ;;
	*) die "$(basename "$f") is not aarch64 (Machine: ${machine:-unknown})" ;;
	esac
	for align in $(elf_phdr "$f" | awk '$1 == "LOAD" { print $NF }'); do
		[ "$((align))" -ge "$page" ] \
			|| die "$(basename "$f"): a LOAD segment is aligned $align, below the $page page size"
	done
}

check_android_pie() {
	local f=$1 expect=/system/bin/linker64 interp out
	out=$(elf_phdr "$f")
	interp=$(sed -n 's/.*Requesting program interpreter: \(.*\)\]/\1/p' <<<"$out")
	interp=${interp%%$'\n'*}
	[ "$interp" = "$expect" ] \
		|| die "$(basename "$f"): expected the interpreter $expect, found '${interp:-none}'"
}

check_needed_absent() {
	local f=$1 out lib
	shift
	out=$("$READELF" -d "$f")
	for lib in "$@"; do
		if grep -q "Shared library: \[$lib\]" <<<"$out"; then
			die "$(basename "$f") links $lib dynamically; it has to be inside the binary"
		fi
	done
}

check_load_align() {
	local f=$1 page=${2:-16384} align
	[ -f "$f" ] || die "no such file: $f"
	for align in $(elf_phdr "$f" | awk '$1 == "LOAD" { print $NF }'); do
		[ "$((align))" -ge "$page" ] \
			|| die "$(basename "$f"): a LOAD segment is aligned $align, below the $page page size"
	done
}

check_no_build_paths() {
	local leak
	leak=$(grep -a -o -E '/(home|root|Users)/[A-Za-z0-9._-]+' "$1" | sort -u || true)
	# A real newline, not \n: die() prints its argument verbatim, so an escaped
	# \n arrives in the CI log as a literal backslash-n and the list of leaked
	# paths (the only thing that says what to map) is unreadable.
	[ -z "$leak" ] || die "$(basename "$1") carries build-machine paths:
$leak"
}

check_marker() {
	local f=$1 marker=$2
	grep -aq -- "$marker" "$f" \
		|| die "$(basename "$f") does not contain '$marker' — this is not the build we meant"
}

report_binary() {
	local f=$1
	printf '%-22s %s\n' "$(basename "$f"):" "$f"
	printf '%-22s %s\n' "size:" "$(human "$(stat -c%s "$f")")"
	printf '%-22s %s\n' "sha256:" "$(sha256_of "$f")"
}

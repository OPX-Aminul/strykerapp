#!/usr/bin/env bash
#
# Generates a Markdown changelog for a GitHub Release.
#
#   NEW_TAG=v6.5.12 bash scripts/generate-changelog.sh [output-file]
#
# What it does:
#   * Finds the previous release tag (most recent `v*` tag before this build)
#   * Lists every commit since then, grouped by type (feat / fix / perf / ...)
#   * Adds a compare link, contributor credits and build metadata
#
# Environment:
#   NEW_TAG            tag being released (optional) - used for the compare link
#   GITHUB_REPOSITORY  owner/repo  (provided by GitHub Actions)
#   GITHUB_SERVER_URL  https://github.com (provided by GitHub Actions)
#   MAX_COMMITS        maximum commits listed, default 50
#
set -euo pipefail

OUT="${1:-changelog.md}"
REPO="${GITHUB_REPOSITORY:-OPX-Aminul/strykerapp}"
SERVER="${GITHUB_SERVER_URL:-https://github.com}"
NEW_TAG="${NEW_TAG:-}"
MAX_COMMITS="${MAX_COMMITS:-50}"

# Conventional-commit shape: type(scope)!: subject
CONVENTIONAL_RE='^([A-Za-z]+)(\([^)]*\))?!?:[[:space:]]*(.*)$'

# ---------------------------------------------------------------------------
# Find the previous release tag, skipping the tag we are about to create.
# ---------------------------------------------------------------------------
PREV_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null || true)"
if [ -n "$PREV_TAG" ] && [ -n "$NEW_TAG" ] && [ "$PREV_TAG" = "$NEW_TAG" ]; then
  PREV_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' "${NEW_TAG}^" 2>/dev/null || true)"
fi

if [ -n "$PREV_TAG" ]; then
  RANGE="${PREV_TAG}..HEAD"
else
  RANGE="HEAD"
fi

# ---------------------------------------------------------------------------
# Group commits into sections.
# ---------------------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The trailing `echo` keeps the last line readable by `read` (git log has no final newline).
{
  git log "$RANGE" --no-merges --pretty=format:'%H%x09%s%x09%an' 2>/dev/null | head -n "$MAX_COMMITS"
  echo
} > "$WORK/commits.tsv" || true

bucket_for() {
  case "${1,,}" in
    feat|feature)   echo feature ;;
    fix|bugfix)     echo fix ;;
    perf)           echo perf ;;
    refactor)       echo refactor ;;
    docs|doc)       echo docs ;;
    test|tests)     echo test ;;
    build|ci)       echo build ;;
    chore|style)    echo chore ;;
    *)              echo other ;;
  esac
}

: > "$WORK/authors"
while IFS=$'\t' read -r sha subject author; do
  [ -z "${sha:-}" ] && continue
  clean="$subject"
  type=""
  if [[ "$subject" =~ $CONVENTIONAL_RE ]]; then
    type="${BASH_REMATCH[1]}"
    clean="${BASH_REMATCH[3]}"
  fi
  bucket="$(bucket_for "$type")"
  printf -- '- %s ([`%s`](%s/%s/commit/%s))\n' \
    "$clean" "${sha:0:7}" "$SERVER" "$REPO" "$sha" >> "$WORK/$bucket"
  printf '%s\n' "$author" >> "$WORK/authors"
done < "$WORK/commits.tsv"

# ---------------------------------------------------------------------------
# Write the release notes.
# ---------------------------------------------------------------------------
{
  if [ -n "$PREV_TAG" ]; then
    echo "**Full changelog:** [\`${PREV_TAG}...${NEW_TAG:-HEAD}\`](${SERVER}/${REPO}/compare/${PREV_TAG}...${NEW_TAG:-HEAD})"
  else
    echo "**Full changelog:** [all commits](${SERVER}/${REPO}/commits/${NEW_TAG:-HEAD})"
  fi
  echo
  echo "Automatically built from \`${NEW_TAG:-HEAD}\` by a manual release run."
  echo

  add_section() {
    local file="$1" title="$2"
    if [ -s "$WORK/$file" ]; then
      echo "### $title"
      echo
      cat "$WORK/$file"
      echo
    fi
  }

  add_section feature  "✨ Features"
  add_section fix      "🐛 Bug Fixes"
  add_section perf     "⚡ Performance"
  add_section refactor "♻️ Refactoring"
  add_section docs     "📝 Documentation"
  add_section test     "✅ Tests"
  add_section build    "🔧 Build & CI"
  add_section chore    "🧹 Chores"
  add_section other    "📦 Other Changes"

  if [ ! -s "$WORK/feature" ] && [ ! -s "$WORK/fix" ] && [ ! -s "$WORK/perf" ] \
     && [ ! -s "$WORK/refactor" ] && [ ! -s "$WORK/docs" ] && [ ! -s "$WORK/test" ] \
     && [ ! -s "$WORK/build" ] && [ ! -s "$WORK/chore" ] && [ ! -s "$WORK/other" ]; then
    echo "_No new commits since the previous release — this is a rebuild of the same source._"
    echo
  fi

  # `paste -d ', '` cycles through the delimiters, which drops the spaces, so
  # join with a plain comma and add the spaces afterwards.
  CONTRIBUTORS="$(sort -u "$WORK/authors" 2>/dev/null | grep -v '^$' | paste -sd',' - | sed 's/,/, /g' || true)"
  if [ -n "$CONTRIBUTORS" ]; then
    echo "### 👥 Contributors"
    echo
    echo "$CONTRIBUTORS"
    echo
  fi

  echo "### 📦 Install"
  echo
  echo "Download the APK below and install it on your device (enable \"Install unknown apps\" if prompted)."
} > "$OUT"

echo "Changelog written to $OUT (range: $RANGE)"

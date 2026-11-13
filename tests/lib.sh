# lib.sh -- shared setup for the aowlsuggest test scripts (sourced, not run).
#
# Provides: ROOT, AS (the binary), AOWLPARSER (the checker it shells out to),
# mkwork (a scratch dir the native exe can read), and valid_corpus (known-valid
# aowlmony sources on this machine).
LIBROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$LIBROOT"
DEVDIR="${DEVDIR:-$(cd "$ROOT/.." && pwd)}"
AS="${AOWLSUGGEST:-$ROOT/bin/aowlsuggest.exe}"
export AOWLPARSER="${AOWLPARSER:-$DEVDIR/toolchain/aifparser/bin/aowlparser.exe}"
if command -v cygpath >/dev/null 2>&1; then
  export AOWLPARSER="$(cygpath -m "$AOWLPARSER")"
fi

# A fresh scratch dir as a native (drive-letter) path: a native exe cannot read
# MSYS /tmp paths.
mkwork() {
  local d; d="$(mktemp -d)"
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$d"; else echo "$d"; fi
}

# Known-valid aowlmony sources: the vendored snapshot in tests/corpus (a frozen
# copy of the aowlhexer and aowlc sources, so the proof is reproducible) plus
# this repo's own src. Override the roots with CORPUS_DIRS (space separated).
valid_corpus() {
  local dirs="${CORPUS_DIRS:-$ROOT/tests/corpus $ROOT/src}"
  find $dirs -name '*.aowl' -not -path '*nimcache*' 2>/dev/null | sort
}

# Count occurrences of a fixed string in a file ($1 needle, $2 file).
count_in() { grep -o -F -- "$1" "$2" | wc -l | tr -d ' '; }

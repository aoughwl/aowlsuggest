#!/usr/bin/env bash
# build.sh -- build bin/aowlsuggest.exe with aowlmony. Fails loudly when no exe
# is produced (the compiler exits 0 even then; the exe lands in nimcache/<hash>/).
#
# Overrides: AOWLMONY_ROOT (toolchain root; default ~/dev/toolchain/aowlmony/root),
#            AOWLJSONREF  (jsonref src dir; default ~/dev/std/jsonref/src).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AOWLMONY_ROOT="${AOWLMONY_ROOT:-$HOME/dev/toolchain/aowlmony/root}"
JSONREF="${AOWLJSONREF:-$HOME/dev/std/jsonref/src}"
COMPILER="$AOWLMONY_ROOT/bin/aowlmony.exe"
[[ -x "$COMPILER" ]] || { echo "build.sh: no compiler at $COMPILER" >&2; exit 1; }
if command -v cygpath >/dev/null 2>&1; then
  export AOWLMONY_ROOT="$(cygpath -w "$AOWLMONY_ROOT")"
  JSONREF="$(cygpath -m "$JSONREF")"
fi
mkdir -p "$ROOT/bin"
log="$ROOT/bin/build.log"
exe=""
for attempt in 1 2; do   # the shared nimcache_static can make one build fail spuriously
  rm -f "$ROOT"/src/nimcache/*/aowlsuggest.exe 2>/dev/null || true
  ( cd "$ROOT/src" && "$COMPILER" c -d:release --path:"$JSONREF" --path:"$ROOT/src" aowlsuggest.aowl ) >"$log" 2>&1 || true
  exe="$(ls -t "$ROOT"/src/nimcache/*/aowlsuggest.exe 2>/dev/null | head -1 || true)"
  [[ -n "$exe" ]] && break
done
if [[ -z "$exe" ]]; then
  echo "FAILED: no aowlsuggest.exe produced (see $log)" >&2
  grep -E 'Error' "$log" | head -20 >&2 || true
  exit 1
fi
cp "$exe" "$ROOT/bin/aowlsuggest.exe"
rm -f "$log"
echo "built bin/aowlsuggest.exe"

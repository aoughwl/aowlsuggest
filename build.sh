#!/usr/bin/env bash
# Build aowlsuggest with the Nimony compiler (self-hosted). aowlsuggest consumes
# aowlparser purely as a subprocess over its JSON contract, so no `-p:` include
# paths are needed — only nimony's own stdlib.
#
# The nimony toolchain serializes native codegen through a single shared build
# lock; parallel sessions contend on it, so we take an flock before invoking the
# compiler and print BUILD-OK / BUILD-FAIL then a DONE marker the caller waits on.
#
# Override the compiler with NIMONY=/path/to/nimony.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIMONY="${NIMONY:-$HOME/nimony/bin/nimony}"
AOWLKIT="${AOWLKIT:-$HOME/aowlkit/src}"
LOCK="${NIMONY_BUILD_LOCK:-$HOME/.nimony-build.lock}"
cd "$ROOT"

build() {
  "$NIMONY" c --base:src -p:"$AOWLKIT" -d:nimony src/aowlsuggest.nim 2>&1
}

run_locked() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK"
    flock 9
  fi
  build
}

log="$(run_locked)"; rc=$?
# nimony `c` can exit 0 even on failure, so treat any `Error:` line as failure.
if [ $rc -ne 0 ] || grep -qE '(^|[^a-zA-Z])Error:' <<<"$log"; then
  echo "$log" | grep -E 'Error:' | head -20
  echo "BUILD-FAIL"
  echo "BUILD-DONE"
  exit 1
fi

mkdir -p bin
exe="$(find nimcache -type f -name aowlsuggest -executable -printf '%T@ %p\n' 2>/dev/null \
       | sort -rn | head -1 | cut -d' ' -f2-)"
if [ -z "${exe:-}" ]; then
  echo "build.sh: could not locate built aowlsuggest in nimcache/" >&2
  echo "BUILD-FAIL"; echo "BUILD-DONE"
  exit 1
fi
cp "$exe" bin/aowlsuggest
echo "built bin/aowlsuggest"
echo "BUILD-OK"
echo "BUILD-DONE"

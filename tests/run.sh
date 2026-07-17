#!/usr/bin/env bash
# run.sh — the whole aowlsuggest test suite: behavioural fix tests plus the
# zero-false-positive corpus proof. Builds the binary first if it is missing.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

if [ ! -x "$ROOT/bin/aowlsuggest" ]; then
  echo "building aowlsuggest ..."
  bash "$ROOT/build.sh" || { echo "build failed"; exit 1; }
fi

echo "== fix.sh =="
bash "$ROOT/tests/fix.sh" || fail=1
echo
echo "== features.sh =="
bash "$ROOT/tests/features.sh" || fail=1
echo
echo "== zerofp.sh =="
bash "$ROOT/tests/zerofp.sh" || fail=1
echo
echo "== stress.sh =="
# Realism gate over the full Nim compiler test corpus (deliberately malformed
# files). Skips cleanly if that corpus is absent. Override SAMPLE to trim.
SAMPLE="${SAMPLE:-3000}" bash "$ROOT/tests/stress.sh" || fail=1

echo
if [ "$fail" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "TEST FAILURES"; fi
exit "$fail"

#!/usr/bin/env bash
# stress.sh — realism stress test over the broad Nim compiler test corpus
# (/home/savant/Nim/tests), which is full of DELIBERATELY malformed files.
#
# The zero-false-positive guarantee generalises to a monotonicity invariant the
# verify loop must never break:
#   (I1) error count AFTER fix  <=  error count BEFORE fix        (never worse)
#   (I2) if fix CHANGED the file, then AFTER < BEFORE            (every applied
#        edit strictly reduced errors — because each was verified)
#
# A single violation means a fix corrupted code, so this is a hard gate. Sample
# size is SAMPLE (default 250 files, deterministic: sorted, first N).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AS="${AOWLSUGGEST:-$ROOT/bin/aowlsuggest}"
CORPUS="${STRESS_CORPUS:-/home/savant/Nim/tests}"
SAMPLE="${SAMPLE:-250}"
fail=0

mapfile -t ALL < <(find "$CORPUS" -name '*.nim' 2>/dev/null | sort)
[ "${#ALL[@]}" -gt 0 ] || { echo "stress: no files under $CORPUS (skipping)"; exit 0; }
FILES=( "${ALL[@]:0:$SAMPLE}" )
echo "stress: ${#FILES[@]} of ${#ALL[@]} files from $CORPUS"

scratch="$(mktemp -d)"; trap 'rm -rf "$scratch"' EXIT

errcount() {  # errors reported for $1
  "$AS" check --no-config --format:json "$1" 2>/dev/null | grep -o '"severity":"error"' | wc -l
}

changedFiles=0
improved=0
worsened=0
for f in "${FILES[@]}"; do
  before="$(errcount "$f")"
  cp "$f" "$scratch/p.nim"
  "$AS" fix --no-config "$scratch/p.nim" --write >/dev/null 2>&1
  after="$(errcount "$scratch/p.nim")"
  if [ "$after" -gt "$before" ]; then
    echo "FAIL (I1): fix INCREASED errors ($before -> $after): $f"
    worsened=$((worsened+1)); fail=1
  fi
  if ! cmp -s "$f" "$scratch/p.nim"; then
    changedFiles=$((changedFiles+1))
    if [ "$after" -ge "$before" ]; then
      echo "FAIL (I2): fix changed the file but did not reduce errors ($before -> $after): $f"
      fail=1
    else
      improved=$((improved+1))
    fi
  fi
done

echo "stress: changed=$changedFiles improved=$improved worsened=$worsened"
if [ "$fail" -eq 0 ]; then
  echo "stress: PASS — no fix ever increased errors; every change reduced them"
else
  echo "stress: FAILURES above"
fi
exit "$fail"

#!/usr/bin/env bash
# zerofp.sh — the zero-false-positive proof, over aowlparser's own oracle corpus
# of KNOWN-VALID files:
#   /home/savant/nimony/src   (184)   the nimony compiler
#   /home/savant/nimony/lib   (105)   the nimony stdlib
#   /home/savant/Nim/lib      (310)   the full upstream Nim stdlib
#
# Two guarantees are asserted:
#   (1) lint reports ZERO errors on every file (no false diagnostics), and
#   (2) fix proposes NO change to any file (a fix can never corrupt valid code).
#
# (2) is the strong claim and is independent of aowlparser's diagnostic state:
# even if aowlparser ever emitted a spurious diagnostic, aowlsuggest verifies
# each candidate edit against the checker and would discard one that does not
# strictly reduce errors — so a valid file is left untouched regardless.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AS="${AOWLSUGGEST:-$ROOT/bin/aowlsuggest}"
CORPUS_DIRS="${CORPUS_DIRS:-/home/savant/nimony/src /home/savant/nimony/lib /home/savant/Nim/lib}"
fail=0

mapfile -t FILES < <(find $CORPUS_DIRS -name '*.nim' 2>/dev/null | sort)
echo "corpus: ${#FILES[@]} valid files"
[ "${#FILES[@]}" -gt 0 ] || { echo "FAIL: no corpus files found"; exit 1; }

# (1) census: one lint pass, assert zero errors / run-failures.
census="$(mktemp)"; trap 'rm -f "$census"' EXIT
"$AS" lint --no-config --format:json "${FILES[@]}" > "$census" 2>/dev/null
read -r errors runfail < <(python3 - "$census" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print(d['summary']['errors'], d['summary']['runFailures'])
PY
)
echo "lint census: errors=$errors runFailures=$runfail"
[ "$errors" = "0" ]  || { echo "FAIL: lint reported $errors error(s) on the valid corpus"; fail=1; }
[ "$runfail" = "0" ] || { echo "FAIL: $runfail file(s) failed to run through the checker"; fail=1; }

# (2) fix must not change ANY valid file. Copy each to a scratch path, run
# fix --write, and compare bytes. (--write on a clean file is a no-op by design;
# we verify that empirically rather than trust it.)
scratch="$(mktemp -d)"; trap 'rm -f "$census"; rm -rf "$scratch"' EXIT
changed=0
checked=0
for f in "${FILES[@]}"; do
  cp "$f" "$scratch/probe.nim"
  "$AS" fix --no-config "$scratch/probe.nim" --write >/dev/null 2>&1
  if ! cmp -s "$f" "$scratch/probe.nim"; then
    echo "FAIL: fix changed a VALID file: $f"
    changed=$((changed+1))
    fail=1
  fi
  checked=$((checked+1))
done
echo "fix scan: $checked file(s) checked, $changed changed"

if [ "$fail" -eq 0 ]; then
  echo "zerofp: PASS — 0 errors and 0 fixes across ${#FILES[@]} valid files"
else
  echo "zerofp: FAILURES above"
fi
exit "$fail"

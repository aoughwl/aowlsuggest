#!/usr/bin/env bash
# zerofp.sh -- the zero-false-positive proof over KNOWN-VALID aowlmony sources
# (see valid_corpus in lib.sh: the code, aowllsp, aowlhexer and aowlc repos plus
# this repo's own src).
#
# Two guarantees are asserted:
#   (1) lint reports ZERO errors on every file (no false diagnostics), and
#   (2) fix proposes NO change to any file (a fix can never corrupt valid code).
#
# (2) is the strong claim and is independent of aowlparser's diagnostic state:
# even if aowlparser ever emitted a spurious diagnostic, aowlsuggest verifies
# each candidate edit against the checker and would discard one that does not
# strictly reduce errors -- so a valid file is left untouched regardless.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fail=0

mapfile -t FILES < <(valid_corpus)
echo "corpus: ${#FILES[@]} valid files"
[ "${#FILES[@]}" -gt 0 ] || { echo "FAIL: no corpus files found"; exit 1; }

# (1) census: one lint pass, assert zero errors / run-failures.
census="$(mktemp)"; trap 'rm -f "$census"' EXIT
"$AS" lint --no-config --format:json "${FILES[@]}" > "$census" 2>/dev/null
errors="$(grep -o '"errors":[0-9]*' "$census" | tail -1 | cut -d: -f2)"
runfail="$(grep -o '"runFailures":[0-9]*' "$census" | tail -1 | cut -d: -f2)"
echo "lint census: errors=$errors runFailures=$runfail"
[ "$errors" = "0" ]  || { echo "FAIL: lint reported ${errors:-?} error(s) on the valid corpus"; fail=1; }
[ "$runfail" = "0" ] || { echo "FAIL: ${runfail:-?} file(s) failed to run through the checker"; fail=1; }

# (2) fix must not change ANY valid file. Copy each to a scratch path, run
# fix --write, and compare bytes. (--write on a clean file is a no-op by design;
# we verify that empirically rather than trust it.)
scratch="$(mkwork)"; trap 'rm -f "$census"; rm -rf "$scratch"' EXIT
changed=0
checked=0
for f in "${FILES[@]}"; do
  cp "$f" "$scratch/probe.aowl"
  "$AS" fix --no-config "$scratch/probe.aowl" --write >/dev/null 2>&1
  if ! cmp -s "$f" "$scratch/probe.aowl"; then
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

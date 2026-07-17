#!/usr/bin/env bash
# fix.sh — behavioural tests for aowlsuggest's quick-fix engine.
#
# Two shapes, mirroring aowlparser's tests/diag.sh discipline:
#   (a) before -> after: a malformed file gets exactly the expected repair, and
#       the repaired file then lints CLEAN (the fix is verified end to end).
#   (b) valid stays untouched: a well-formed file yields NO fix and is left
#       byte-for-byte unchanged (the zero-false-positive guarantee, per file).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AS="${AOWLSUGGEST:-$ROOT/bin/aowlsuggest}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail=0

# --- (a) before -> after, then lints clean --------------------------------
# each case: name | before (printf %b) | expected-exact-after
run_fix_case() {
  local name="$1" before="$2" after="$3"
  printf '%b' "$before" > "$WORK/c.nim"
  "$AS" fix "$WORK/c.nim" --write >/dev/null 2>&1
  local got; got="$(cat "$WORK/c.nim")"
  local want; want="$(printf '%b' "$after")"
  if [ "$got" != "$want" ]; then
    echo "FAIL[$name]: after-fix mismatch"
    echo "  want: $(printf '%q' "$want")"
    echo "  got:  $(printf '%q' "$got")"
    fail=1
    return
  fi
  # the repaired file must now be clean (exit 0, no errors)
  if ! "$AS" lint "$WORK/c.nim" >/dev/null 2>&1; then
    echo "FAIL[$name]: repaired file still has errors"; fail=1
  fi
}

run_fix_case assignment      'if x = 5:\n  discard\n'        'if x == 5:\n  discard\n'
run_fix_case expected-colon  'if c\n  echo 1\n'              'if c:\n  echo 1\n'
run_fix_case missing-equals  'proc f()\n  echo 1\n'          'proc f() =\n  echo 1\n'
run_fix_case mismatch-paren  'let a = (1 + 2]\n'             'let a = (1 + 2)\n'
run_fix_case mismatch-brack  'let a = [1, 2)\n'              'let a = [1, 2]\n'
# a cascade: two independent errors, both repaired in one run.
run_fix_case cascade         'proc f()\n  if a = b:\n    echo 1\n' \
                             'proc f() =\n  if a == b:\n    echo 1\n'

# --- (b) valid files must never change ------------------------------------
valid_untouched() {
  local name="$1" src="$2"
  printf '%b' "$src" > "$WORK/v.nim"
  local before; before="$(cat "$WORK/v.nim")"
  local out; out="$("$AS" fix "$WORK/v.nim" --write 2>&1)"
  local after; after="$(cat "$WORK/v.nim")"
  if [ "$before" != "$after" ]; then
    echo "FAIL[$name]: valid file was modified"; fail=1
  fi
  grep -q 'no automatic fixes' <<<"$out" || {
    echo "FAIL[$name]: expected 'no automatic fixes', got: $out"; fail=1; }
}
valid_untouched simple-proc  'proc f(x: int): int = x + 1\n'
valid_untouched named-arg    'discard f(k = v)\n'
valid_untouched if-cmp       'if x == 5:\n  discard\n'
valid_untouched forward-decl 'proc f()\ntype T = int\n'
valid_untouched trailing-comma 'discard foo(a, b,)\n'

# --- fix DRY-RUN shows a diff but does not write ---------------------------
printf 'if x = 5:\n  discard\n' > "$WORK/d.nim"
before="$(cat "$WORK/d.nim")"
dout="$("$AS" fix "$WORK/d.nim" 2>&1)"
[ "$(cat "$WORK/d.nim")" = "$before" ] || { echo "FAIL: dry-run modified the file"; fail=1; }
grep -q '^+if x == 5:' <<<"$dout" || { echo "FAIL: dry-run did not show the diff"; fail=1; }

# --- lint --format:json is a parseable object with a summary ---------------
printf 'let a = (1 + 2]\n' > "$WORK/j.nim"
jout="$("$AS" lint --format:json "$WORK/j.nim" 2>&1)"
case "$jout" in
  '{'*'}') : ;;
  *) echo "FAIL: lint --format:json is not a JSON object"; fail=1 ;;
esac
grep -q '"code":"mismatched-bracket"' <<<"$jout" || { echo "FAIL: json missing code"; fail=1; }
grep -q '"summary"' <<<"$jout" || { echo "FAIL: json missing summary"; fail=1; }

# --- lint exit code is non-zero on error, zero on clean --------------------
printf 'if x = 5:\n  discard\n' > "$WORK/e.nim"
"$AS" lint "$WORK/e.nim" >/dev/null 2>&1 && { echo "FAIL: lint on error exited 0"; fail=1; }
printf 'let x = 1\n' > "$WORK/e.nim"
"$AS" lint "$WORK/e.nim" >/dev/null 2>&1 || { echo "FAIL: lint on clean exited non-zero"; fail=1; }

# --- lsp output carries a code action with a 0-based range -----------------
printf 'if x = 5:\n  discard\n' > "$WORK/l.nim"
lout="$("$AS" lsp "$WORK/l.nim" 2>&1)"
grep -q '"codeActions"' <<<"$lout" || { echo "FAIL: lsp missing codeActions"; fail=1; }
grep -q '"newText":"=="' <<<"$lout" || { echo "FAIL: lsp code action missing newText"; fail=1; }
grep -q '"line":0' <<<"$lout" || { echo "FAIL: lsp range not 0-based"; fail=1; }

if [ "$fail" -eq 0 ]; then echo "fix: all checks passed"; else echo "fix: FAILURES above"; fi
exit "$fail"

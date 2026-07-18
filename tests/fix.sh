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
  # nothing should have been applied to a valid file
  grep -q 'fixed ' <<<"$out" && {
    echo "FAIL[$name]: a fix was applied to a valid file: $out"; fail=1; }
  # dry-run says so explicitly
  grep -q 'no automatic fixes' <<<"$("$AS" fix "$WORK/v.nim" 2>&1)" || {
    echo "FAIL[$name]: dry-run did not report 'no automatic fixes'"; fail=1; }
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

# --- "did you mean" ranking: a mismatched bracket offers TWO ranked actions -
printf 'let a = (1 + 2]\n' > "$WORK/r.nim"
rout="$("$AS" lsp "$WORK/r.nim" 2>&1)"
grep -q '"isPreferred":true' <<<"$rout" || { echo "FAIL: ranking: no preferred action"; fail=1; }
grep -q '"isPreferred":false' <<<"$rout" || { echo "FAIL: ranking: no alternative action"; fail=1; }

# --- stdin (unsaved buffer): check / fix / lsp -----------------------------
sout="$(printf 'if x = 5:\n  discard\n' | "$AS" check --stdin --filename:buf.nim 2>&1)"
grep -q 'buf.nim:1:6: error\[assignment-in-condition\]' <<<"$sout" || {
  echo "FAIL: stdin check did not use the reported filename / diagnostic"; fail=1; }
# fix --stdin writes the FIXED source to stdout (summary goes to stderr)
fsout="$(printf 'if x = 5:\n  discard\n' | "$AS" fix --stdin 2>/dev/null)"
[ "$fsout" = "$(printf 'if x == 5:\n  discard\n')" ] || {
  echo "FAIL: fix --stdin did not emit fixed source on stdout: $fsout"; fail=1; }
# a valid buffer is echoed back unchanged
vsout="$(printf 'let x = 1\n' | "$AS" fix --stdin 2>/dev/null)"
[ "$vsout" = "$(printf 'let x = 1\n')" ] || {
  echo "FAIL: fix --stdin altered a valid buffer"; fail=1; }
lsout="$(printf 'if x = 5:\n  discard\n' | "$AS" lsp --stdin --filename:buf.nim 2>&1)"
grep -q 'buf.nim' <<<"$lsout" || { echo "FAIL: stdin lsp did not use the filename in the URI"; fail=1; }

# --- comparison-in-binding auto-fix (mirror of assignment-in-condition) ----
printf 'let x == 5\n' > "$WORK/cb.nim"
"$AS" fix --no-config --write "$WORK/cb.nim" >/dev/null 2>&1
[ "$(printf 'let x = 5\n')" = "$(cat "$WORK/cb.nim")" ] || { echo "FAIL: comparison-in-binding not fixed: $(cat "$WORK/cb.nim")"; fail=1; }
# must NOT touch a real comparison in the value
printf 'let y = 1\nlet z = y == 2\n' > "$WORK/cb2.nim"
b2="$(cat "$WORK/cb2.nim")"
"$AS" fix --no-config --write "$WORK/cb2.nim" >/dev/null 2>&1
[ "$b2" = "$(cat "$WORK/cb2.nim")" ] || { echo "FAIL: comparison-in-binding fix touched a valid comparison"; fail=1; }

# --- stray-end auto-fix (remove a Ruby/Pascal/Lua 'end') -------------------
printf 'proc f() =\n  discard\nend\n' > "$WORK/se.nim"
"$AS" fix --no-config --write "$WORK/se.nim" >/dev/null 2>&1
grep -qx 'end' "$WORK/se.nim" && { echo "FAIL: stray 'end' not removed"; fail=1; }
"$AS" check --no-config "$WORK/se.nim" >/dev/null 2>&1 || { echo "FAIL: stray-end fix left an error"; fail=1; }

# --- walrus-in-binding auto-fix (':=' -> '=') ------------------------------
for form in 'let x := 5|let x = 5' 'const C := 5|const C = 5' 'var v := 5|var v = 5'; do
  bad="${form%|*}"; good="${form#*|}"
  printf '%s\n' "$bad" > "$WORK/w.nim"
  "$AS" fix --no-config --write "$WORK/w.nim" >/dev/null 2>&1
  [ "$good" = "$(cat "$WORK/w.nim")" ] || { echo "FAIL: walrus fix '$bad' -> $(cat "$WORK/w.nim")"; fail=1; }
done

# --- mut-not-a-keyword auto-fix ('let/var/const mut x' -> 'var x') ---------
for form in 'let mut x = 5|var x = 5' 'var mut y = 1|var y = 1' 'const mut z = 2|var z = 2'; do
  bad="${form%|*}"; good="${form#*|}"
  printf '%s\n' "$bad" > "$WORK/mk.nim"
  "$AS" fix --no-config --write "$WORK/mk.nim" >/dev/null 2>&1
  [ "$good" = "$(cat "$WORK/mk.nim")" ] || { echo "FAIL: mut fix '$bad' -> $(cat "$WORK/mk.nim")"; fail=1; }
done
# a variable literally named 'mut' must be left untouched
printf 'let mut = 5\n' > "$WORK/mk2.nim"
"$AS" fix --no-config --write "$WORK/mk2.nim" >/dev/null 2>&1
[ "let mut = 5" = "$(cat "$WORK/mk2.nim")" ] || { echo "FAIL: mut fix touched a variable named mut"; fail=1; }

# --- angle-bracket-generics auto-fix ('proc f<T>()' -> 'proc f[T]()') ------
printf 'proc f<T>(x: T) = discard\n' > "$WORK/ag.nim"
"$AS" fix --no-config --write "$WORK/ag.nim" >/dev/null 2>&1
[ "proc f[T](x: T) = discard" = "$(cat "$WORK/ag.nim")" ] || { echo "FAIL: angle fix -> $(cat "$WORK/ag.nim")"; fail=1; }
printf 'proc g<T, U>(a: T, b: U) = discard\n' > "$WORK/ag2.nim"
"$AS" fix --no-config --write "$WORK/ag2.nim" >/dev/null 2>&1
[ "proc g[T, U](a: T, b: U) = discard" = "$(cat "$WORK/ag2.nim")" ] || { echo "FAIL: multi-param angle fix -> $(cat "$WORK/ag2.nim")"; fail=1; }

# --- arrow-return-type auto-fix ('proc f() -> T' -> 'proc f(): T') ---------
printf 'proc g() -> int = 2\n' > "$WORK/ar.nim"
"$AS" fix --no-config --write "$WORK/ar.nim" >/dev/null 2>&1
[ "proc g(): int = 2" = "$(cat "$WORK/ar.nim")" ] || { echo "FAIL: arrow-return fix -> $(cat "$WORK/ar.nim")"; fail=1; }
# a sugar lambda must be left untouched
printf 'import std/sugar\nlet f = (x: int) -> x + 1\n' > "$WORK/ar2.nim"
a2="$(cat "$WORK/ar2.nim")"
"$AS" fix --no-config --write "$WORK/ar2.nim" >/dev/null 2>&1
[ "$a2" = "$(cat "$WORK/ar2.nim")" ] || { echo "FAIL: arrow fix touched a sugar lambda"; fail=1; }

# --- else-if-not-elif auto-fix ('else if' -> 'elif') -----------------------
printf 'if a:\n  discard\nelse if b:\n  discard\n' > "$WORK/ei.nim"
"$AS" fix --no-config --write "$WORK/ei.nim" >/dev/null 2>&1
[ "elif b:" = "$(sed -n '3p' "$WORK/ei.nim")" ] || { echo "FAIL: else if -> elif: $(sed -n '3p' "$WORK/ei.nim")"; fail=1; }
"$AS" check --no-config "$WORK/ei.nim" >/dev/null 2>&1 || { echo "FAIL: else-if fix left an error"; fail=1; }
# a valid else: block containing an if must be untouched
printf 'if a:\n  discard\nelse:\n  if b:\n    discard\n' > "$WORK/ei2.nim"
v="$(cat "$WORK/ei2.nim")"
"$AS" fix --no-config --write "$WORK/ei2.nim" >/dev/null 2>&1
[ "$v" = "$(cat "$WORK/ei2.nim")" ] || { echo "FAIL: else-if fix touched a valid else block"; fail=1; }

# --- unterminated-backtick is a SUGGESTION, never auto-applied -------------
# where the closing backtick belongs is ambiguous (idents can hold spaces/ops),
# so aowlsuggest suggests it rather than guessing.
printf 'let `a = 1\n' > "$WORK/bt.nim"
btout="$("$AS" fix --no-config "$WORK/bt.nim" 2>&1)"
grep -q 'help: add the closing backtick' <<<"$btout" || { echo "FAIL: no backtick suggestion"; fail=1; }
"$AS" fix --no-config --write "$WORK/bt.nim" >/dev/null 2>&1
[ "$(printf 'let `a = 1\n')" = "$(cat "$WORK/bt.nim")" ] || { echo "FAIL: backtick was wrongly auto-applied"; fail=1; }

# --- redundant-semicolon: opt-in auto-fix, param-separator safe ------------
printf 'let x = 5;\necho x\n' > "$WORK/sc.nim"
grep -q 'redundant-semicolon' <<<"$("$AS" check --no-config "$WORK/sc.nim" 2>&1)" && {
  echo "FAIL: redundant-semicolon must be OFF by default"; fail=1; }
"$AS" fix --no-config --style:semicolons --write "$WORK/sc.nim" >/dev/null 2>&1
[ "let x = 5" = "$(sed -n '1p' "$WORK/sc.nim")" ] || { echo "FAIL: trailing ; not removed: $(sed -n '1p' "$WORK/sc.nim")"; fail=1; }
# a ';' param separator inside a multi-line proc() must be left ALONE
printf 'proc f(a: int;\n       b: int) = discard\n' > "$WORK/sc2.nim"
sc2="$(cat "$WORK/sc2.nim")"
"$AS" fix --no-config --style:semicolons --write "$WORK/sc2.nim" >/dev/null 2>&1
[ "$sc2" = "$(cat "$WORK/sc2.nim")" ] || { echo "FAIL: param-separator ; was wrongly removed"; fail=1; }

# --- c-style-operator: opt-in, SUGGESTION-only (&&/|| are definable) -------
printf 'if a && b:\n  discard\n' > "$WORK/co.nim"
# off by default
grep -q 'c-style-operator' <<<"$("$AS" check --no-config "$WORK/co.nim" 2>&1)" && {
  echo "FAIL: c-style-operator must be OFF by default"; fail=1; }
# opt-in surfaces a suggestion
coout="$("$AS" fix --no-config --style:c-operators "$WORK/co.nim" 2>&1)"
grep -q "help: use 'and'" <<<"$coout" || { echo "FAIL: no c-operators suggestion"; fail=1; }
# never auto-applied (definable operator + precedence): file untouched by --write
"$AS" fix --no-config --style:c-operators --write "$WORK/co.nim" >/dev/null 2>&1
grep -q '&&' "$WORK/co.nim" || { echo "FAIL: c-style-operator was wrongly auto-applied"; fail=1; }

# --- KB fallback suggestion for a bare value-error -------------------------
# aowlparser attaches no `fix` to invalid-escape-sequence; aowlsuggest supplies a
# knowledge-base hint so the diagnostic still tells you what to do.
printf 'let s = "a\\qb"\n' > "$WORK/esc.nim"
esout="$("$AS" fix --no-config "$WORK/esc.nim" 2>&1)"
grep -q 'invalid-escape-sequence' <<<"$esout" || { echo "FAIL: escape diag missing"; fail=1; }
grep -q 'help: use a valid escape' <<<"$esout" || { echo "FAIL: no KB fallback suggestion for bare value-error"; fail=1; }
# it stays a SUGGESTION — never auto-applied (the file is untouched by --write)
before="$(cat "$WORK/esc.nim")"
"$AS" fix --no-config --write "$WORK/esc.nim" >/dev/null 2>&1
[ "$before" = "$(cat "$WORK/esc.nim")" ] || { echo "FAIL: value-error was wrongly auto-applied"; fail=1; }

# --- version ---------------------------------------------------------------
"$AS" version 2>&1 | grep -q 'aowlsuggest ' || { echo "FAIL: version output"; fail=1; }

if [ "$fail" -eq 0 ]; then echo "fix: all checks passed"; else echo "fix: FAILURES above"; fi
exit "$fail"

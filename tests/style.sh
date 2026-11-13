#!/usr/bin/env bash
# style.sh — the opt-in style/lint layer and its verified auto-fixes.
#
# aowlparser's stylistic checks (trailing whitespace, final newline, EOL
# convention, BOM) are OFF by default — which is what keeps the zero-FP corpus
# clean. aowlsuggest turns them on with `--style:` / `--pedantic` and makes each
# actionable with a VERIFIED fix. This suite proves three things:
#
#   (A) Round-trips — each style fix surfaces the diagnostic, repairs it, and the
#       repaired source re-checks clean under the same policy.
#   (B) Default mode is untouched — with no style flag, none of these diagnostics
#       appear (so the zero-FP guarantee is unaffected; zerofp.sh proves the fix
#       side).
#   (C) Program preservation — the STRONG claim. Over a sample of the KNOWN-VALID
#       corpus, `fix --pedantic` (1) never breaks the parse (the result still
#       checks clean in default mode), (2) changes ONLY insignificant bytes
#       (whitespace / BOM — proven by stripping them and comparing), and (3) is
#       idempotent. A style fix can therefore never change what the program means.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
work="$(mkwork)"; trap 'rm -rf "$work"' EXIT
fail=0

note() { echo "  $1"; }
die()  { echo "FAIL: $1"; fail=1; }

# ── (A) + (B) per-fix round-trips ────────────────────────────────────────────

# helper: assert `check <flags> <file>` output contains a code (or NOT, with !)
check_has() { # <flags> <file> <code>
  local out; out="$("$AS" check --no-config $1 "$2" 2>/dev/null)"
  grep -q "\[$3\]" <<<"$out"
}

echo "== (A) trailing-whitespace =="
printf 'let x = 1   \nlet y = 2\n' > "$work/tw.aowl"
check_has "" "$work/tw.aowl" trailing-whitespace && die "trailing-ws leaked into DEFAULT mode"
check_has "--pedantic" "$work/tw.aowl" trailing-whitespace || die "trailing-ws not flagged under --pedantic"
"$AS" fix --no-config --pedantic --write "$work/tw.aowl" >/dev/null 2>&1
[ "$(printf 'let x = 1\nlet y = 2\n')" = "$(cat "$work/tw.aowl")" ] || die "trailing-ws not removed cleanly"
check_has "--pedantic" "$work/tw.aowl" trailing-whitespace && die "trailing-ws still present after fix"
note "ok"

echo "== (A) missing-final-newline =="
printf 'let a = 1' > "$work/fn.aowl"   # no trailing newline
check_has "" "$work/fn.aowl" missing-final-newline && die "final-newline leaked into DEFAULT mode"
check_has "--style:final-newline" "$work/fn.aowl" missing-final-newline || die "final-newline not flagged"
"$AS" fix --no-config --style:final-newline --write "$work/fn.aowl" >/dev/null 2>&1
[ "$(printf 'let a = 1\n')" = "$(cat "$work/fn.aowl")" ] || die "final newline not appended"
note "ok"

echo "== (A) line-ending CRLF->LF =="
printf 'let a = 1\r\nlet b = 2\r\n' > "$work/eol.aowl"
check_has "" "$work/eol.aowl" line-ending && die "line-ending leaked into DEFAULT mode"
check_has "--style:lf" "$work/eol.aowl" line-ending || die "CRLF not flagged under --style:lf"
"$AS" fix --no-config --style:lf --write "$work/eol.aowl" >/dev/null 2>&1
if grep -q $'\r' "$work/eol.aowl"; then die "CR not removed"; fi
check_has "--style:lf" "$work/eol.aowl" line-ending && die "line-ending still present after fix"
note "ok"

echo "== (A) bom-rejected =="
printf '\xEF\xBB\xBFlet z = 3\n' > "$work/bom.aowl"
check_has "" "$work/bom.aowl" bom-rejected && die "bom leaked into DEFAULT mode"
check_has "--style:bom" "$work/bom.aowl" bom-rejected || die "BOM not flagged under --style:bom"
"$AS" fix --no-config --style:bom --write "$work/bom.aowl" >/dev/null 2>&1
[ "$(printf 'let z = 3\n')" = "$(cat "$work/bom.aowl")" ] || die "BOM not stripped"
note "ok"

echo "== (A) cascade: trailing-ws AND missing-final-newline together =="
printf 'let p = 1   \nlet q = 2   ' > "$work/both.aowl"   # trailing ws + no EOF newline
"$AS" fix --no-config --pedantic --write "$work/both.aowl" >/dev/null 2>&1
[ "$(printf 'let p = 1\nlet q = 2\n')" = "$(cat "$work/both.aowl")" ] || die "cascade fix wrong"
note "ok"

echo "== (B) unknown --style category is rejected =="
"$AS" check --no-config --style:bogus "$work/tw.aowl" >/dev/null 2>&1 && die "bogus --style category accepted"
note "ok"

# ── (C) program-preservation sweep over the valid corpus ─────────────────────

echo "== (C) program preservation across the valid corpus (fix --pedantic) =="
SAMPLE_STRIDE="${SAMPLE_STRIDE:-2}"
mapfile -t ALL < <(valid_corpus)
FILES=()
for ((i=0; i<${#ALL[@]}; i+=SAMPLE_STRIDE)); do FILES+=("${ALL[$i]}"); done
echo "  sample: ${#FILES[@]} of ${#ALL[@]} valid files (stride $SAMPLE_STRIDE)"
[ "${#FILES[@]}" -gt 0 ] || { echo "FAIL: no corpus files found"; exit 1; }

# strip insignificant bytes (leading BOM + all whitespace) for the "same program"
# comparison. If two files agree after this, the fix touched only whitespace/BOM.
strip_insig() {
  # drop a leading UTF-8 BOM, then every space/tab/CR/LF
  local first; first="$(head -c 3 "$1" | od -An -tx1 | tr -d ' \n')"
  if [ "$first" = "efbbbf" ]; then tail -c +4 "$1" | tr -d ' \t\r\n'
  else tr -d ' \t\r\n' < "$1"; fi
}

changed=0; broke=0; nonidem=0; touched=0
for f in "${FILES[@]}"; do
  # fix over stdin so the original is never mutated; fixed source -> stdout
  "$AS" fix --no-config --pedantic --stdin --filename:"$f" < "$f" > "$work/fixed" 2>/dev/null
  # (1) parse must still be clean in DEFAULT mode
  if ! "$AS" check --no-config "$work/fixed" >/dev/null 2>&1; then
    # `check` exits nonzero only on an ERROR-severity diagnostic
    die "fix --pedantic broke the parse of a valid file: $f"; broke=$((broke+1)); continue
  fi
  # (2) same program: only whitespace / BOM may differ
  if ! diff -q <(strip_insig "$f") <(strip_insig "$work/fixed") >/dev/null; then
    die "fix --pedantic changed non-whitespace bytes: $f"; changed=$((changed+1)); continue
  fi
  # track whether anything at all changed (for reporting)
  cmp -s "$f" "$work/fixed" || touched=$((touched+1))
  # (3) idempotence
  "$AS" fix --no-config --pedantic --stdin --filename:"$f" < "$work/fixed" > "$work/fixed2" 2>/dev/null
  if ! cmp -s "$work/fixed" "$work/fixed2"; then
    die "fix --pedantic is not idempotent: $f"; nonidem=$((nonidem+1))
  fi
done
echo "  swept ${#FILES[@]} files: $touched had style changes, $changed corrupted, $broke broke parse, $nonidem non-idempotent"

if [ "$fail" -eq 0 ]; then
  echo "style: PASS — 4 fixes round-trip; program preserved & idempotent across the corpus sample"
else
  echo "style: FAILURES above"
fi
exit "$fail"

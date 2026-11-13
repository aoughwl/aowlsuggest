#!/usr/bin/env bash
# features.sh — tests for the expanded surface: extra auto-fixes, directory
# walking + excludes, SARIF, explain, inline suppression, --stats, and the LSP
# server. The core fix/lint/lsp behaviour lives in fix.sh; the zero-FP and
# realism proofs live in zerofp.sh / stress.sh.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
WORK="$(mkwork)"; trap 'rm -rf "$WORK"' EXIT
fail=0

# --- expanded auto-fixes (each repaired, then lints clean) -----------------
fix_case() {
  local name="$1" before="$2" after="$3"
  printf '%b' "$before" > "$WORK/c.aowl"
  "$AS" fix "$WORK/c.aowl" --write >/dev/null 2>&1
  local got; got="$(cat "$WORK/c.aowl")"
  local want; want="$(printf '%b' "$after")"
  [ "$got" = "$want" ] || { echo "FAIL[$name]: got $(printf '%q' "$got")"; fail=1; }
}
fix_case unterminated-char "let c = 'a\n"       "let c = 'a'\n"
fix_case unmatched-close   'x)\n'               'x\n'
fix_case unclosed-1line    'let a = (1 + 2\n'   'let a = (1 + 2)\n'
fix_case unterminated-str  'let s = "hello\n'   'let s = "hello"\n'
fix_case invalid-int-lit   'echo 0O5\n'         'echo 0o5\n'

# a mid-line tab becomes a space; an INDENTATION tab is left alone (suggestion).
printf 'let\tx = 1\n' > "$WORK/tab.aowl"
"$AS" fix "$WORK/tab.aowl" --write >/dev/null 2>&1
[ "$(cat "$WORK/tab.aowl")" = "let x = 1" ] || { echo "FAIL: mid-line tab not fixed"; fail=1; }

# --- directory walking + excludes ------------------------------------------
mkdir -p "$WORK/proj/sub" "$WORK/proj/vendor"
printf 'if a = 1:\n  discard\n' > "$WORK/proj/x.aowl"
printf 'if b = 2:\n  discard\n' > "$WORK/proj/sub/y.aowl"
printf 'if c = 3:\n  discard\n' > "$WORK/proj/vendor/z.aowl"
out="$("$AS" lint "$WORK/proj" 2>&1)"
grep -q 'x.aowl' <<<"$out" && grep -q 'sub/y.aowl' <<<"$out" && grep -q 'vendor/z.aowl' <<<"$out" || {
  echo "FAIL: directory walk missed a file"; fail=1; }
outx="$("$AS" lint "$WORK/proj" --exclude:'*/vendor/*' 2>&1)"
grep -q 'vendor/z.aowl' <<<"$outx" && { echo "FAIL: --exclude did not prune vendor"; fail=1; }
grep -q 'x.aowl' <<<"$outx" || { echo "FAIL: --exclude pruned too much"; fail=1; }

# --- --stats ---------------------------------------------------------------
grep -q 'by code:' <<<"$("$AS" lint "$WORK/proj" --stats 2>&1)" || {
  echo "FAIL: --stats produced no code summary"; fail=1; }

# --- SARIF -----------------------------------------------------------------
sarif="$("$AS" lint "$WORK/proj/x.aowl" --format:sarif 2>&1)"
grep -q '"version":"2.1.0"' <<<"$sarif" || { echo "FAIL: sarif version"; fail=1; }
grep -q '"ruleId":"assignment-in-condition"' <<<"$sarif" || { echo "FAIL: sarif ruleId"; fail=1; }
grep -q '"startLine":1' <<<"$sarif" || { echo "FAIL: sarif 1-based line"; fail=1; }
# SARIF `fixes`: the auto-fix is emitted as a one-click suggestion with a precise
# replacement region, plus fingerprint and automation id.
grep -q '"insertedContent":{"text":"=="}' <<<"$sarif" || { echo "FAIL: sarif fix replacement text"; fail=1; }
grep -q '"deletedRegion":{"startLine":1' <<<"$sarif" || { echo "FAIL: sarif fix deleted region"; fail=1; }
grep -q '"primaryLocationLineHash":"[0-9a-f][0-9a-f]*"' <<<"$sarif" || { echo "FAIL: sarif fingerprint missing"; fail=1; }
grep -q '"automationDetails":{"id":"[^"]' <<<"$sarif" || { echo "FAIL: sarif automationDetails missing"; fail=1; }
# SARIF partialFingerprints are STABLE when the same bug shifts line number.
printf 'if q = 1:\n  discard\n' > "$WORK/fp_a.aowl"
printf '\n\nif q = 1:\n  discard\n' > "$WORK/fp_b.aowl"
fpa="$("$AS" check --no-config --format:sarif "$WORK/fp_a.aowl" | grep -o '"primaryLocationLineHash":"[^"]*"')"
fpb="$("$AS" check --no-config --format:sarif "$WORK/fp_b.aowl" | grep -o '"primaryLocationLineHash":"[^"]*"')"
[ -n "$fpa" ] && [ "$fpa" = "$fpb" ] || { echo "FAIL: fingerprint not stable across line shift ($fpa vs $fpb)"; fail=1; }

# --- fix --check (gofmt -l style) ------------------------------------------
printf 'if c = 5:\n  discard\n' > "$WORK/chk_dirty.aowl"
printf 'let okk = 1\n' > "$WORK/chk_clean.aowl"
before="$(cat "$WORK/chk_dirty.aowl")"
"$AS" fix --no-config --check "$WORK/chk_dirty.aowl" >/dev/null 2>&1 && {
  echo "FAIL: fix --check should exit nonzero on a fixable file"; fail=1; }
[ "$before" = "$(cat "$WORK/chk_dirty.aowl")" ] || { echo "FAIL: fix --check modified the file"; fail=1; }
"$AS" fix --no-config --check "$WORK/chk_clean.aowl" >/dev/null 2>&1 || {
  echo "FAIL: fix --check should exit 0 on a clean file"; fail=1; }

# --- CI gates: --max-warnings + --quiet ------------------------------------
printf 'let ww = 1   \n' > "$WORK/warn.aowl"   # one trailing-whitespace warning (pedantic)
"$AS" lint --no-config --pedantic --max-warnings:0 "$WORK/warn.aowl" >/dev/null 2>&1 && {
  echo "FAIL: --max-warnings:0 should fail on a warning"; fail=1; }
"$AS" lint --no-config --pedantic --max-warnings:5 "$WORK/warn.aowl" >/dev/null 2>&1 || {
  echo "FAIL: --max-warnings:5 should pass with one warning"; fail=1; }
# --quiet hides the warning line but keeps errors
printf 'if e = 1:   \n  discard\n' > "$WORK/mix.aowl"   # 1 error + 1 trailing-ws warning
q="$("$AS" check --no-config --pedantic --quiet "$WORK/mix.aowl" 2>/dev/null)"
grep -q 'assignment-in-condition' <<<"$q" || { echo "FAIL: --quiet dropped the error"; fail=1; }
grep -q 'trailing-whitespace' <<<"$q" && { echo "FAIL: --quiet kept a warning"; fail=1; }

# --- explain ---------------------------------------------------------------
"$AS" explain assignment-in-condition 2>&1 | grep -q "did you mean" >/dev/null 2>&1 || true
grep -q 'auto-fixable: yes' <<<"$("$AS" explain assignment-in-condition 2>&1)" || {
  echo "FAIL: explain missing auto-fixable line"; fail=1; }
grep -q 'auto-fixable: no' <<<"$("$AS" explain expected-condition 2>&1)" || {
  echo "FAIL: explain should mark expected-condition non-auto-fixable"; fail=1; }

# --- completeness: EVERY known code carries guidance -----------------------
# no diagnostic should ever be a bare error with no advice — an auto-fix,
# aowlparser's own fix hint, or a knowledge-base fallback suggestion.
kbjson="$("$AS" explain --format:json 2>/dev/null)"
grep -q '"guidance":false' <<<"$kbjson" && { echo "FAIL: some diagnostic codes have no guidance"; fail=1; }
grep -q '"guidance":true' <<<"$kbjson" || { echo "FAIL: explain --format:json lists no codes"; fail=1; }
"$AS" explain no-such-code >/dev/null 2>&1 && { echo "FAIL: explain unknown code should fail"; fail=1; }
grep -q 'assignment-in-condition' <<<"$("$AS" explain 2>&1)" || { echo "FAIL: explain list"; fail=1; }

# --- KB completeness: every diagnostic code aowlparser can emit is known ----
# Derive the authoritative code set straight from aowlparser's source (the
# kebab-case string literals it emits, minus the NIF dialect stamp)
# and assert `explain <code>` succeeds for each — so a newly-added aowlparser
# code that we forgot to document makes this test fail loudly.
APSRC="${AOWLPARSER_SRC:-$DEVDIR/toolchain/aifparser/src}"
if [ -d "$APSRC" ]; then
  mapfile -t CODES < <(grep -rhoE --include='lexer.*' --include='parse_*' --include='parsecore.*' --include='parser.*' --include='tokens.*' --include='aowlparser.*' '"[a-z]+(-[a-z]+)+"' "$APSRC" | tr -d '"' \
  | grep -v -- '-parsed$' | sort -u)
  for code in "${CODES[@]}"; do
    "$AS" explain "$code" >/dev/null 2>&1 || {
      echo "FAIL: aowlparser code '$code' is not in the knowledge base"; fail=1; }
  done
else
  echo "note: aowlparser src not at $APSRC — skipping KB-completeness cross-check"
fi

# --- inline suppression ----------------------------------------------------
# same-line ignore silences everything on the line
printf 'if x = 5:  # aowlsuggest:ignore\n  discard\n' > "$WORK/s.aowl"
"$AS" lint "$WORK/s.aowl" >/dev/null 2>&1 || { echo "FAIL: same-line ignore did not silence"; fail=1; }
# ignore[other-code] does NOT silence a different code
printf 'if x = 5:  # aowlsuggest:ignore[expected-colon]\n  discard\n' > "$WORK/s.aowl"
"$AS" lint "$WORK/s.aowl" >/dev/null 2>&1 && { echo "FAIL: ignore[other] wrongly silenced"; fail=1; }
# ignore-next silences the following line
printf '# aowlsuggest:ignore-next\nif x = 5:\n  discard\n' > "$WORK/s.aowl"
"$AS" lint "$WORK/s.aowl" >/dev/null 2>&1 || { echo "FAIL: ignore-next did not silence"; fail=1; }
# --no-suppress restores the diagnostic
"$AS" lint "$WORK/s.aowl" --no-suppress >/dev/null 2>&1 && { echo "FAIL: --no-suppress should re-report"; fail=1; }

# --- LSP server (scripted JSON-RPC session) --------------------------------
# frame JSON bodies with Content-Length (byte length: force the C locale)
frame() { local b="$1"; LC_ALL=C; printf 'Content-Length: %d\r\n\r\n%s' "${#b}" "$b"; }
session="$WORK/lsp_in.bin"
{
  frame '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}'
  frame '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///t.aowl","languageId":"aowl","version":1,"text":"if x = 5:\n  discard\n"}}}'
  frame '{"jsonrpc":"2.0","id":2,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///t.aowl"},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":9}},"context":{"diagnostics":[]}}}'
  frame '{"jsonrpc":"2.0","id":3,"method":"shutdown"}'
  frame '{"jsonrpc":"2.0","method":"exit"}'
} > "$session"
out="$("$AS" lsp-server < "$session" 2>/dev/null | tr -d '\r')"
grep -q '"method":"textDocument/publishDiagnostics"' <<<"$out" || { echo "FAIL: lsp-server: no publishDiagnostics"; fail=1; }
grep -q 'assignment-in-condition' <<<"$out" || { echo "FAIL: lsp-server: diagnostic code missing"; fail=1; }
grep -q '"newText":"=="' <<<"$out" || { echo "FAIL: lsp-server: code action missing"; fail=1; }
grep -q '"textDocumentSync":1' <<<"$out" || { echo "FAIL: lsp-server: initialize capabilities missing"; fail=1; }
grep -q '"id":3,"result":null' <<<"$out" || { echo "FAIL: lsp-server: shutdown not answered"; fail=1; }

if [ "$fail" -eq 0 ]; then echo "features: all checks passed"; else echo "features: FAILURES above"; fi
exit "$fail"

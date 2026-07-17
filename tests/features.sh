#!/usr/bin/env bash
# features.sh — tests for the expanded surface: extra auto-fixes, directory
# walking + excludes, SARIF, explain, inline suppression, --stats, and the LSP
# server. The core fix/lint/lsp behaviour lives in fix.sh; the zero-FP and
# realism proofs live in zerofp.sh / stress.sh.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AS="${AOWLSUGGEST:-$ROOT/bin/aowlsuggest}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail=0

# --- expanded auto-fixes (each repaired, then lints clean) -----------------
fix_case() {
  local name="$1" before="$2" after="$3"
  printf '%b' "$before" > "$WORK/c.nim"
  "$AS" fix "$WORK/c.nim" --write >/dev/null 2>&1
  local got; got="$(cat "$WORK/c.nim")"
  local want; want="$(printf '%b' "$after")"
  [ "$got" = "$want" ] || { echo "FAIL[$name]: got $(printf '%q' "$got")"; fail=1; }
}
fix_case unterminated-char "let c = 'a\n"       "let c = 'a'\n"
fix_case unmatched-close   'x)\n'               'x\n'
fix_case unclosed-1line    'let a = (1 + 2\n'   'let a = (1 + 2)\n'
fix_case unterminated-str  'let s = "hello\n'   'let s = "hello"\n'
fix_case invalid-int-lit   'echo 0O5\n'         'echo 0o5\n'

# a mid-line tab becomes a space; an INDENTATION tab is left alone (suggestion).
printf 'let\tx = 1\n' > "$WORK/tab.nim"
"$AS" fix "$WORK/tab.nim" --write >/dev/null 2>&1
[ "$(cat "$WORK/tab.nim")" = "let x = 1" ] || { echo "FAIL: mid-line tab not fixed"; fail=1; }

# --- directory walking + excludes ------------------------------------------
mkdir -p "$WORK/proj/sub" "$WORK/proj/vendor"
printf 'if a = 1:\n  discard\n' > "$WORK/proj/x.nim"
printf 'if b = 2:\n  discard\n' > "$WORK/proj/sub/y.nim"
printf 'if c = 3:\n  discard\n' > "$WORK/proj/vendor/z.nim"
out="$("$AS" lint "$WORK/proj" 2>&1)"
grep -q 'x.nim' <<<"$out" && grep -q 'sub/y.nim' <<<"$out" && grep -q 'vendor/z.nim' <<<"$out" || {
  echo "FAIL: directory walk missed a file"; fail=1; }
outx="$("$AS" lint "$WORK/proj" --exclude:'*/vendor/*' 2>&1)"
grep -q 'vendor/z.nim' <<<"$outx" && { echo "FAIL: --exclude did not prune vendor"; fail=1; }
grep -q 'x.nim' <<<"$outx" || { echo "FAIL: --exclude pruned too much"; fail=1; }

# --- --stats ---------------------------------------------------------------
grep -q 'by code:' <<<"$("$AS" lint "$WORK/proj" --stats 2>&1)" || {
  echo "FAIL: --stats produced no code summary"; fail=1; }

# --- SARIF -----------------------------------------------------------------
sarif="$("$AS" lint "$WORK/proj/x.nim" --format:sarif 2>&1)"
grep -q '"version":"2.1.0"' <<<"$sarif" || { echo "FAIL: sarif version"; fail=1; }
grep -q '"ruleId":"assignment-in-condition"' <<<"$sarif" || { echo "FAIL: sarif ruleId"; fail=1; }
grep -q '"startLine":1' <<<"$sarif" || { echo "FAIL: sarif 1-based line"; fail=1; }

# --- explain ---------------------------------------------------------------
"$AS" explain assignment-in-condition 2>&1 | grep -q "did you mean" >/dev/null 2>&1 || true
grep -q 'auto-fixable: yes' <<<"$("$AS" explain assignment-in-condition 2>&1)" || {
  echo "FAIL: explain missing auto-fixable line"; fail=1; }
grep -q 'auto-fixable: no' <<<"$("$AS" explain expected-condition 2>&1)" || {
  echo "FAIL: explain should mark expected-condition non-auto-fixable"; fail=1; }
"$AS" explain no-such-code >/dev/null 2>&1 && { echo "FAIL: explain unknown code should fail"; fail=1; }
grep -q 'assignment-in-condition' <<<"$("$AS" explain 2>&1)" || { echo "FAIL: explain list"; fail=1; }

# --- inline suppression ----------------------------------------------------
# same-line ignore silences everything on the line
printf 'if x = 5:  # aowlsuggest:ignore\n  discard\n' > "$WORK/s.nim"
"$AS" lint "$WORK/s.nim" >/dev/null 2>&1 || { echo "FAIL: same-line ignore did not silence"; fail=1; }
# ignore[other-code] does NOT silence a different code
printf 'if x = 5:  # aowlsuggest:ignore[expected-colon]\n  discard\n' > "$WORK/s.nim"
"$AS" lint "$WORK/s.nim" >/dev/null 2>&1 && { echo "FAIL: ignore[other] wrongly silenced"; fail=1; }
# ignore-next silences the following line
printf '# aowlsuggest:ignore-next\nif x = 5:\n  discard\n' > "$WORK/s.nim"
"$AS" lint "$WORK/s.nim" >/dev/null 2>&1 || { echo "FAIL: ignore-next did not silence"; fail=1; }
# --no-suppress restores the diagnostic
"$AS" lint "$WORK/s.nim" --no-suppress >/dev/null 2>&1 && { echo "FAIL: --no-suppress should re-report"; fail=1; }

# --- LSP server (scripted JSON-RPC session) --------------------------------
python3 - "$AS" <<'PY' || { echo "FAIL: lsp-server session"; fail=1; }
import subprocess, json, sys
AS=sys.argv[1]
def frame(o):
    b=json.dumps(o).encode(); return b"Content-Length: %d\r\n\r\n%s"%(len(b),b)
msgs=[
 {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}},
 {"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///t.nim","languageId":"nim","version":1,"text":"if x = 5:\n  discard\n"}}},
 {"jsonrpc":"2.0","id":2,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///t.nim"},"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":9}},"context":{"diagnostics":[]}}},
 {"jsonrpc":"2.0","id":3,"method":"shutdown"},
 {"jsonrpc":"2.0","method":"exit"},
]
p=subprocess.run([AS,"lsp-server"],input=b"".join(frame(m) for m in msgs),capture_output=True,timeout=30)
out=p.stdout.decode(errors="replace")
# must contain a publishDiagnostics with our code and a code action with the fix
assert '"method":"textDocument/publishDiagnostics"' in out, "no publishDiagnostics"
assert 'assignment-in-condition' in out, "diagnostic code missing"
assert '"newText":"=="' in out, "code action missing"
assert '"textDocumentSync":1' in out, "initialize capabilities missing"
PY

if [ "$fail" -eq 0 ]; then echo "features: all checks passed"; else echo "features: FAILURES above"; fi
exit "$fail"

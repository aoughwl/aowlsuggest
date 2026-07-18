#!/usr/bin/env bash
# config.sh — the per-project `.aowlsuggest` config file: discovery (walk up from
# the cwd), application (style/exclude/suppress/parser defaults), CLI precedence,
# and graceful handling of a malformed key. The config only sets DEFAULTS that a
# CLI flag can still override, so it never weakens the zero-FP guarantee.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AS="${AOWLSUGGEST:-$ROOT/bin/aowlsuggest}"
export AOWLPARSER="${AOWLPARSER:-$HOME/aifparser/bin/aowlparser}"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fail=0
die() { echo "FAIL: $1"; fail=1; }

# a project with pedantic style on, an exclude, and a bad key
mkdir -p "$work/proj/sub" "$work/proj/vendor"
printf 'pedantic = true\nexclude = vendor/*\nboguskey = 1\n' > "$work/proj/.aowlsuggest"
printf 'let x = 1   \n' > "$work/proj/f.nim"        # trailing whitespace
printf 'let y = 2   \n' > "$work/proj/sub/g.nim"    # trailing ws, one dir down
printf 'not nim (((\n' > "$work/proj/vendor/skip.nim"

echo "== config applies pedantic (trailing-whitespace surfaces without a CLI flag) =="
out="$(cd "$work/proj" && "$AS" check f.nim 2>/dev/null)"
grep -q 'trailing-whitespace' <<<"$out" || die "config pedantic not applied: $out"

echo "== --no-config ignores the project config =="
out="$(cd "$work/proj" && "$AS" check --no-config f.nim 2>/dev/null)"
[ -z "$out" ] || die "--no-config still reported: $out"

echo "== config discovered by walking up from a subdirectory =="
out="$(cd "$work/proj/sub" && "$AS" check g.nim 2>/dev/null)"
grep -q 'trailing-whitespace' <<<"$out" || die "config not found from subdir: $out"

echo "== --config:PATH loads a specific file from anywhere =="
out="$(cd "$work" && "$AS" check --config:"$work/proj/.aowlsuggest" "$work/proj/f.nim" 2>/dev/null)"
grep -q 'trailing-whitespace' <<<"$out" || die "--config:PATH not honored: $out"

echo "== discovery anchors to the TARGET FILE's dir, not the cwd =="
# checking a file in the project from an unrelated cwd still finds its config
out="$(cd /tmp && "$AS" check "$work/proj/sub/g.nim" 2>/dev/null)"
grep -q 'trailing-whitespace' <<<"$out" || die "file-anchored discovery failed: $out"

echo "== stdin + --filename anchors discovery (the aowllsp / unsaved-buffer case) =="
out="$(cd /tmp && printf 'let z = 9   \n' | "$AS" check --stdin --filename:"$work/proj/sub/g.nim" 2>/dev/null)"
grep -q 'trailing-whitespace' <<<"$out" || die "--filename-anchored discovery failed: $out"

echo "== exclude from config prunes a directory during a walk =="
out="$(cd "$work/proj" && "$AS" lint . 2>/dev/null)"
grep -q 'vendor' <<<"$out" && die "exclude=vendor/* did not prune vendor: $out"

echo "== fix honors config-enabled style fixes =="
( cd "$work/proj" && "$AS" fix --write f.nim >/dev/null 2>&1 )
[ "$(printf 'let x = 1\n')" = "$(cat "$work/proj/f.nim")" ] || die "config-driven fix wrong: $(cat "$work/proj/f.nim" | cat -A)"

echo "== an unknown key is a graceful stderr warning, not a failure =="
err="$(cd "$work/proj" && "$AS" check sub/g.nim 2>&1 1>/dev/null)"
grep -q 'unknown key: boguskey' <<<"$err" || die "no warning for unknown key: $err"

echo "== 'suppress = false' in config disables inline suppression =="
mkdir -p "$work/sup"
printf 'suppress = false\n' > "$work/sup/.aowlsuggest"
printf 'if x = 5:  # aowlsuggest:ignore\n  discard\n' > "$work/sup/s.nim"
out="$(cd "$work/sup" && "$AS" check s.nim 2>/dev/null)"
grep -q 'assignment-in-condition' <<<"$out" || die "suppress=false not applied (diag was hidden): $out"
# and with default (suppress on) the same diagnostic is hidden
out2="$(cd "$work/sup" && "$AS" check --no-config s.nim 2>/dev/null)"
grep -q 'assignment-in-condition' <<<"$out2" && die "inline ignore not honored by default: $out2"

echo "== an explicit --config that can't be read is a hard error (exit 2) =="
"$AS" check --config:"$work/does-not-exist" "$work/proj/f.nim" >/dev/null 2>&1
[ "$?" = "2" ] || die "missing --config should exit 2"

echo "== a binary/garbage config degrades gracefully (no crash) =="
mkdir -p "$work/bin"
printf '\x00\x01\x02 garbage \xff not a config' > "$work/bin/.aowlsuggest"
printf 'let g = 1\n' > "$work/bin/b.nim"
( cd "$work/bin" && "$AS" check b.nim >/dev/null 2>&1 )
[ "$?" = "0" ] || die "binary config crashed / errored the run"

echo "== a CLI flag still overrides/extends the config =="
# config has pedantic; adding --style:lf on the CLI extends it (CRLF now flagged)
printf 'let a = 1\r\n' > "$work/proj/crlf.nim"
out="$(cd "$work/proj" && "$AS" check --style:lf crlf.nim 2>/dev/null)"
grep -q 'line-ending' <<<"$out" || die "CLI --style:lf did not extend config: $out"

echo "== [rules] per-code opinion overrides =="
mkdir -p "$work/rules"
printf 'let z = ok == true\nlet w = x == 3.14\n' > "$work/rules/r.nim"
# naming a gated code in [rules] both ENABLES the check and sets its severity
printf '[rules]\nredundant-bool-literal = error\nfloat-equality = off\n' > "$work/rules/.aowlsuggest"
out="$(cd "$work/rules" && "$AS" check r.nim 2>/dev/null)"; rc=$?
grep -q 'error\[redundant-bool-literal\]' <<<"$out" || die "[rules] did not enable+promote redundant-bool-literal: $out"
grep -q 'float-equality' <<<"$out" && die "[rules] float-equality=off did not silence it: $out"
[ "$rc" = "1" ] || die "[rules] promotion to error should exit 1 (got $rc)"
# off silences without failing
printf '[rules]\nredundant-bool-literal = off\n' > "$work/rules/.aowlsuggest"
out="$(cd "$work/rules" && "$AS" check r.nim 2>/dev/null)"; rc=$?
grep -q 'redundant-bool-literal' <<<"$out" && die "[rules] off did not silence: $out"
# a CLI --rule overrides config and also enables the gated check
out="$(cd "$work/rules" && "$AS" check --no-config --rule:redundant-bool-literal=warning r.nim 2>/dev/null)"
grep -q 'warning\[redundant-bool-literal\]' <<<"$out" || die "--rule did not enable+set severity: $out"
# a bad level is rejected
( cd "$work/rules" && "$AS" check --rule:redundant-bool-literal=loud r.nim >/dev/null 2>&1 )
[ "$?" = "2" ] || die "--rule with a bad level should exit 2"

echo "== [rules] enables the new opinion lints =="
printf 'if (x == 5):\n  discard\n' > "$work/rules/op.nim"
# off by default: nothing without a rule/flag
out="$(cd "$work/rules" && "$AS" check --no-config op.nim 2>/dev/null)"
grep -q 'redundant-parens-condition' <<<"$out" && die "redundant-parens must be OFF by default: $out"
# naming it in [rules] enables+promotes it
printf '[rules]\nredundant-parens-condition = warning\n' > "$work/rules/.aowlsuggest"
out="$(cd "$work/rules" && "$AS" check op.nim 2>/dev/null)"
grep -q 'warning\[redundant-parens-condition\]' <<<"$out" || die "[rules] did not enable redundant-parens: $out"
# a CLI --rule enables broad-exception and gates it as an error
printf 'try:\n  discard\nexcept Exception:\n  discard\n' > "$work/rules/be.nim"
out="$(cd "$work/rules" && "$AS" check --no-config --rule:broad-exception=error be.nim 2>/dev/null)"; rc=$?
grep -q 'error\[broad-exception\]' <<<"$out" || die "--rule did not enable broad-exception: $out"
[ "$rc" = "1" ] || die "broad-exception=error should exit 1 (got $rc)"

if [ "$fail" -eq 0 ]; then
  echo "config: PASS — discovery, application, precedence, and graceful degradation"
else
  echo "config: FAILURES above"
fi
exit "$fail"

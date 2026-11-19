# aowlsuggest

The diagnostics / suggestion and editor-integration layer that sits **on top of
[aowlparser](https://github.com/aoughwl/aowlparser)**. Where aowlparser is the
recovering parser that turns aowlmony source into AIF *and reports every grammar/lex
error it copes with*, aowlsuggest is the layer that makes those errors
**actionable**: verified quick-fixes, batch/CI linting (text, JSON, SARIF), a
full stdio LSP server, code explanations, and inline suppression.

Written in **aowlmony** and built with the aowlmony toolchain; the only library it
uses is `jsonref`.

## The one rule that defines this project

**aowlsuggest consumes aowlparser's diagnostics. It never lexes or parses aowlmony
itself, and never duplicates diagnostic *emission*.** The raw errors — bad
tokens, missing `:`, missing `=`, misindented bodies, unbalanced brackets — are
produced *inside* aowlparser's recovering parse. That coupling is deliberate and
stays there. aowlsuggest takes those structured diagnostics and turns them into
quick-fixes, code actions, ranked suggestions, LSP conversion, and CI linting.

If a suggestion ever needs data the diagnostics don't carry, the fix is to
extend **aowlparser's** schema — not to re-derive it here. That boundary is the
whole design.

## The contract (the seam)

aowlsuggest talks to aowlparser over one stable interface:

```sh
aowlparser check --diagnostics:json <file.aowl>
```

which emits a JSON array; each element is

```json
{ "severity", "code", "message", "line", "col", "endCol",
  "fix"?, "related"? { "message", "line", "col" } }
```

Coordinates match a nifler token: `line` is 1-based, `col`/`endCol` are 0-based
(`endCol` exclusive). The process exits non-zero iff any error-severity
diagnostic was produced. `src/contract.aowl` is the *only* module that crosses
this boundary; it reads the JSON **defensively** (unknown fields tolerated, only
missing required fields are fatal). The binary is located via `--parser:PATH`,
then `$AOWLPARSER`, then the default checkout.

> Implementation note: aowlparser prints the whole array on one line, and a
> line-buffered pipe capture can split it — so the contract layer redirects the
> checker's stdout to a temp file and reads it whole. See
> `contract.runCheckerOnFile`.

## Commands

```sh
aowlsuggest fix    <paths...> [--write] [--dry-run]      apply verified quick-fixes
aowlsuggest lint   <paths...> [--format:text|json|sarif] batch lint (nonzero exit on error)
aowlsuggest lsp    <file>                                 LSP diagnostics + code actions (JSON)
aowlsuggest lsp-server                                    a stdio LSP server (JSON-RPC)
aowlsuggest check  <file> [--format:text|json|sarif]      raw diagnostics pass-through
aowlsuggest explain [code] [--format:json]                explain a diagnostic code
aowlsuggest version
```

`<paths...>` are files **or directories** (directories are walked for `*.aowl`).
Common flags:

- `--parser:PATH` — override the aowlparser binary (else `$AOWLPARSER`, else the
  default checkout).
- `--exclude:GLOB` — skip paths matching a glob (`*` and `?`); repeatable.
- `--format:FMT` — `text` (default), `json`, or `sarif` (lint/check).
- `--stats` — (lint) also print a per-code count summary.
- `--max-warnings:N` — (lint) exit non-zero if warnings exceed `N` (CI gate).
- `--quiet` — show only errors in text output (warnings still counted).
- `--color` — colorize the human-readable output.
- `--no-suppress` — ignore inline `# aowlsuggest:ignore` markers.
- `--pedantic` / `--style:CAT` / `--indent-width:N` — opt in to aowlparser's
  stylistic lint policies (see **Style / lint policies**); off by default.
- `--config:PATH` / `--no-config` — use a specific project `.aowlsuggest`, or
  ignore config discovery (see **Project config**).
- `--stdin` (with `fix`/`lsp`/`check`) — read the source from stdin instead of a
  file, so an editor can check an **unsaved buffer**. `--filename:NAME` sets the
  path reported in diagnostics and URIs. In this mode `fix` writes the corrected
  source to stdout (pipe it back into the buffer) and its summary to stderr.

### `fix`

Applies the diagnostics' repairs. Auto-applicable codes — each localized,
guarded, and **verified** before it is kept:

| code | repair |
|------|--------|
| `assignment-in-condition` | `=` → `==` in a condition |
| `mismatched-bracket` | swap the wrong close bracket for the one that matches its opener |
| `expected-colon` | insert `:` at the end of the block header |
| `missing-routine-equals` | insert `=` after a routine signature that has a body |
| `unterminated-char` | add the missing closing `'` |
| `unmatched-close` | delete a surplus close bracket |
| `unclosed-bracket` | add the matching close (single-line brackets) |
| `tabs-not-allowed` | replace a **mid-line** tab with a space |
| `trailing-whitespace` | delete the spaces/tabs before the newline *(style)* |
| `missing-final-newline` | append a terminating newline *(style)* |
| `line-ending` | rewrite the EOL to the requested LF/CRLF *(style)* |
| `bom-rejected` | strip a leading UTF-8 byte-order mark *(style)* |

Everything else is surfaced as a **suggestion** (needs human judgement), never
auto-applied — and **no diagnostic is ever left bare**: the suggestion text is
aowlparser's own `fix` hint when it gave one, otherwise a crisp fallback from
aowlsuggest's knowledge base (e.g. a bad escape, an out-of-range number, an
unterminated backtick). A tested invariant guarantees every known code carries
guidance. `--dry-run` (the default) prints a unified diff;
`--write` applies it; `--check` (gofmt -l / prettier --check style) writes
nothing and just **exits non-zero if any fix is available** — the CI gate for
"this code is already clean" (combine with `--pedantic` to enforce style too).
Directories and cascades are handled in one pass.

The four *(style)* fixes only fire when the matching policy is opted in (see
**Style / lint policies** below); each touches nothing but insignificant
whitespace/BOM, so it can never change what the program means.

### Style / lint policies

aowlparser owns diagnostic *emission*, and several of its stylistic checks are
**off by default** — which is exactly what keeps the zero-FP corpus clean.
aowlsuggest turns them on **on request** and makes each one actionable with a
verified fix. Nothing changes in the default pipeline; these are strictly
opt-in.

```sh
aowlsuggest lint --pedantic          <paths...>   # trailing-ws + final-newline + bom
aowlsuggest fix  --style:lf  --write <paths...>   # normalize CRLF → LF
aowlsuggest fix  --pedantic  --write <paths...>   # apply the whole safe style set
```

| flag | aowlparser policy | code surfaced |
|------|-------------------|---------------|
| `--style:trailing-whitespace` | `--trailing-whitespace:warn` | `trailing-whitespace` |
| `--style:final-newline` | `--final-newline:require` | `missing-final-newline` |
| `--style:lf` / `--style:crlf` | `--newline:lf` / `:crlf` | `line-ending` |
| `--style:bom` | `--bom:reject` | `bom-rejected` |
| `--style:indent-consistency` | `--indent-consistency` | `indent-consistency` *(advisory, no fix)* |
| `--indent-width:N` | `--indent-width:N` | `indent-width` *(advisory, no fix)* |
| `--pedantic` | trailing-whitespace + final-newline + bom | the three above |

`--style:` is repeatable. The flags flow through the same contract seam and the
same verify loop as every other fix — a style edit is kept only if re-checking
under the *same* policy shows strictly fewer diagnostics and introduces no new
code. The `lsp-server` honours these flags too, so an editor session lints
exactly as the CLI would.

### Project config — `.aowlsuggest`

A repo can commit its lint/style defaults so `lint`, `fix`, and `lsp-server` all
behave identically without repeating flags — and so an
[aowllsp](https://github.com/aoughwl/aowllsp) editor session (which drives
aowlsuggest) inherits the same policy. Discovery walks **up** from the working
directory to the filesystem root and uses the first `.aowlsuggest` it finds.

```ini
# .aowlsuggest
pedantic     = true
style        = trailing-whitespace, final-newline, lf
indent-width = 2
exclude      = tests/fixtures/*, vendor/*
suppress     = true
parser       = /opt/aowlparser/bin/aowlparser
```

The config sets **defaults**; a command-line flag always overrides (scalars) or
extends (lists) it, so it never weakens any guarantee. `--config:PATH` forces a
specific file; `--no-config` ignores discovery entirely. Unknown keys and
malformed values degrade to a stderr warning rather than a hard error.

### `lint`

Batch-lints files and directories. Human-readable by default; `--format:json` for
tooling, `--format:sarif` for **GitHub code scanning** and other SARIF 2.1.0
consumers. `--stats` adds a per-code count. Exits non-zero if any file has an
error-severity diagnostic or fails to run — CI-friendly.

The SARIF output carries **`fixes`**: every diagnostic with a verified auto-fix
(including the "did you mean" alternatives) emits a SARIF `fix` with a precise
`deletedRegion` + `insertedContent`, so GitHub renders them as one-click *Apply
fix* suggestions right in the PR. Each result also carries a
**`partialFingerprints.primaryLocationLineHash`** derived from the rule id and
the diagnostic's *line content* (not its line number), so GitHub tracks the same
alert across commits instead of churning it whenever an unrelated edit shifts the
line — and an `automationDetails.id` so several uploads don't collide.

CI gates: `--max-warnings:N` makes `lint` exit non-zero when warnings exceed `N`
(errors always fail); `--quiet` shows only errors in text output (warnings are
still counted toward the gate).

### `lsp` and `lsp-server`

`lsp` emits a one-shot editor payload: LSP `Diagnostic` objects (0-based ranges,
`relatedInformation`) plus `CodeAction` quick-fixes carrying a `WorkspaceEdit`,
in one JSON object `{uri, diagnostics, codeActions}`. When a diagnostic has more
than one plausible repair (e.g. a mismatched bracket can be fixed at the close
*or* the open), all are emitted as a ranked **"did you mean"** set — the first
marked `isPreferred`.

`lsp-server` is a full **stdio Language Server** (JSON-RPC 2.0 with
`Content-Length` framing): `initialize`, `textDocument/{didOpen,didChange,`
`didSave,didClose}` → live `publishDiagnostics`, and `textDocument/codeAction` →
quick-fixes. Text sync is Full; diagnostics come from aowlparser on every edit.

### `explain`

`aowlsuggest explain <code>` describes a diagnostic (what it means, a bad/good
example, whether it is auto-fixable); with no argument it lists every known code.
The knowledge base is derived from aowlparser's diagnostic set.

### Inline suppression

A project can silence an accepted diagnostic with a comment (found by a source
scan, not a reparse):

```
foo(bar)            # aowlsuggest:ignore                 (all codes, this line)
baz(qux)            # aowlsuggest:ignore[expected-colon] (only these codes)
# aowlsuggest:ignore-next
next_line_here()
```

Suppression is on by default; `--no-suppress` disables it.

## Zero-false-positive discipline

Inherited from aowlparser and **non-negotiable**: a fix that corrupts valid code
is worse than no fix. So every auto-fix is **verified** — aowlsuggest applies the
candidate edit, re-runs `aowlparser check`, and keeps it only if it **strictly
reduces the error count and introduces no new error code**. The checker itself is
the oracle; a bad edit can never survive.

This is proven three ways:

- **No false diagnostics / fixes on valid code.** Over a frozen corpus of
  known-valid aowlmony sources (`tests/corpus`, a snapshot of the aowlhexer and
  aowlc sources, plus this repo's own `src`), aowlsuggest reports **0 errors**
  and proposes **0 fixes**. (`tests/zerofp.sh`)
- **Never makes messy code worse.** Each valid file is damaged four ways (drop a
  block-header colon, drop a closing paren, `==` to `=` in a condition, drop a
  routine's `=`); `fix` never increases the error count, and every file it
  changes strictly *reduces* it — the monotonicity invariant the verify loop
  enforces. (`tests/stress.sh`)
- **Style fixes preserve the program.** When the opt-in style policies are on,
  `fix --pedantic` over the valid corpus changes **only** insignificant bytes
  (whitespace / BOM) — proven by stripping whitespace+BOM from both sides and
  comparing — never breaks the parse, and is idempotent. A style fix can't change
  what the code means. (`tests/style.sh`)

Run it yourself:

```sh
bash tests/run.sh        # fix + feature + style + config tests, zero-FP proof, mutation stress gate
```

The `lint` command is a drop-in CI gate. For **GitHub code scanning**, emit SARIF
and upload it — the diagnostics (and their one-click fixes) then appear inline on
the PR, tracked stably across commits by their fingerprints:

```yaml
# .github/workflows/lint.yml
name: aowlsuggest
on: [push, pull_request]
jobs:
  lint:
    runs-on: ubuntu-latest
    permissions:
      security-events: write        # required to upload SARIF
    steps:
      - uses: actions/checkout@v4
      # ... build/obtain aowlparser + aowlsuggest (see their build.sh) ...
      - name: Lint
        run: aowlsuggest lint --format:sarif . > aowlsuggest.sarif
      - name: Upload SARIF
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: aowlsuggest.sarif
```

Prefer a hard pass/fail check instead? Use the exit code:

```sh
aowlsuggest lint --pedantic --max-warnings:0 .   # nonzero on any error OR warning
```

Commit a [`.aowlsuggest`](#project-config--aowlsuggest) so the same policy governs
CI, the CLI, and every editor.

## Build

```sh
bash build.sh            # -> bin/aowlsuggest.exe
```

aowlmony builds it from `src/aowlsuggest.aowl` with one external library,
[jsonref](https://github.com/aoughwl/std/tree/main/jsonref) (`--path:~/dev/std/jsonref/src`;
override with `AOWLJSONREF`). The toolchain root defaults to
`~/dev/toolchain/aowlmony/root` (override with `AOWLMONY_ROOT`). The compiler
exits 0 even when it produced nothing, so `build.sh` treats "no exe in
`nimcache/<hash>/`" as the failure, retries once (the shared static cache can
fail a build spuriously) and exits non-zero loudly.

### The parser dependency

aowlsuggest does not link any parser code: aowlparser is a **subprocess** behind
the contract above, so nothing is vendored. At run time it needs an
`aowlparser` binary: `--parser:PATH`, else `$AOWLPARSER`, else
`~/dev/toolchain/aifparser/bin/aowlparser.exe`. The tool lints `.aowl` files.

### Windows notes

- Directory walking and reported paths use forward slashes; `file:` URIs for
  drive paths come out as `file:///C:/...`.
- stdin/stdout are switched to binary mode at start-up, so `fix --stdin` returns
  the exact bytes (no LF to CRLF rewriting) and LSP framing is exact.
- The checker is launched as `cmd /d /s /c "..."` with stdout redirected to a
  temp file and read back whole.


| file | role |
|------|------|
| `src/contract.aowl` | the seam: run aowlparser, decode its JSON → `seq[Diagnostic]` |
| `src/textedit.aowl` | byte-offset edits, line/col mapping, unified diff |
| `src/fixes.aowl` | the fix registry + the verified zero-FP apply loop |
| `src/lsp.aowl` | diagnostics + code actions as editor JSON |
| `src/lspserver.aowl` | the stdio JSON-RPC Language Server |
| `src/sarif.aowl` | SARIF 2.1.0 output |
| `src/explain.aowl` | the diagnostic-code knowledge base |
| `src/suppress.aowl` | inline `# aowlsuggest:ignore` filtering |
| `src/walk.aowl` | directory walking + glob excludes |
| `src/projconfig.aowl` | the optional `.aowlsuggest` project config (discovery + parse) |
| `src/jsonout.aowl` | JSON string escaping + fragment builders |
| `src/subproc.aowl` | run a child, capture its stdout whole (temp-file redirect) |
| `src/binstdio.aowl` | binary-mode stdin/stdout on Windows |
| `src/aowlsuggest.aowl` | CLI |

## Cooperating with aowlparser

aowlparser is the source of truth for what is an error. If a suggestion needs a
new field or code, that's a coordinated change *there* (a "parser API request"),
bumping the contract in lockstep — never a scrape or re-derivation here.

## Tests

`bash tests/run.sh` runs `fix.sh`, `features.sh`, `zerofp.sh`, `style.sh`,
`config.sh` and `stress.sh` (bash only; they build the binary first if missing).
`tests/lib.sh` holds the shared setup, and `tests/corpus/` is the frozen
known-valid corpus.

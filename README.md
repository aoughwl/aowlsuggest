# aowlsuggest

The diagnostics / suggestion and editor-integration layer that sits **on top of
[aowlparser](https://github.com/aoughwl/aowlparser)**. Where aowlparser is the
recovering parser that turns Nim source into AIF *and reports every grammar/lex
error it copes with*, aowlsuggest is the layer that makes those errors
**actionable**: verified quick-fixes, batch/CI linting (text, JSON, SARIF), a
full stdio LSP server, code explanations, and inline suppression.

Written in **nimony** (the same self-hosted compiler aowlparser builds with), so
it stays JS-compilable and free of the classic Nim toolchain.

## The one rule that defines this project

**aowlsuggest consumes aowlparser's diagnostics. It never lexes or parses Nim
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
aowlparser check --diagnostics:json <file.nim>
```

which emits a JSON array; each element is

```json
{ "severity", "code", "message", "line", "col", "endCol",
  "fix"?, "related"? { "message", "line", "col" } }
```

Coordinates match a nifler token: `line` is 1-based, `col`/`endCol` are 0-based
(`endCol` exclusive). The process exits non-zero iff any error-severity
diagnostic was produced. `src/contract.nim` is the *only* module that crosses
this boundary; it reads the JSON **defensively** (unknown fields tolerated, only
missing required fields are fatal). The binary is located via `--parser:PATH`,
then `$AOWLPARSER`, then the default checkout.

> Implementation note: aowlparser prints the whole array on one line, and
> nimony's `execCmdEx` line-capture mangles lines longer than its buffer — so
> the contract layer redirects the checker's stdout to a temp file and reads it
> whole. See `contract.runCheckerOnFile`.

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

`<paths...>` are files **or directories** (directories are walked for `*.nim`).
Common flags:

- `--parser:PATH` — override the aowlparser binary (else `$AOWLPARSER`, else the
  default checkout).
- `--exclude:GLOB` — skip paths matching a glob (`*` and `?`); repeatable.
- `--format:FMT` — `text` (default), `json`, or `sarif` (lint/check).
- `--stats` — (lint) also print a per-code count summary.
- `--color` — colorize the human-readable output.
- `--no-suppress` — ignore inline `# aowlsuggest:ignore` markers.
- `--pedantic` / `--style:CAT` / `--indent-width:N` — opt in to aowlparser's
  stylistic lint policies (see **Style / lint policies**); off by default.
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

Everything else with a repair hint is surfaced as a **suggestion** (needs human
judgement), never auto-applied. `--dry-run` (the default) prints a unified diff;
`--write` applies it. Directories and cascades are handled in one pass.

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

### `lint`

Batch-lints files and directories. Human-readable by default; `--format:json` for
tooling, `--format:sarif` for **GitHub code scanning** and other SARIF 2.1.0
consumers. `--stats` adds a per-code count. Exits non-zero if any file has an
error-severity diagnostic or fails to run — CI-friendly.

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

```nim
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

This is proven two ways:

- **No false diagnostics / fixes on valid code.** Against aowlparser's own oracle
  corpus of known-valid files — `nimony/src` (184), `nimony/lib` (105), and the
  full upstream `Nim/lib` (310), **599 files** — aowlsuggest reports **0 errors**
  and proposes **0 fixes**. (`tests/zerofp.sh`)
- **Never makes messy code worse.** Over the full Nim compiler test corpus
  (**2890 files**, deliberately malformed), `fix` never increases the error
  count, and every file it changes strictly *reduces* it — the monotonicity
  invariant the verify loop enforces. (`tests/stress.sh`)

- **Style fixes preserve the program.** When the opt-in style policies are on,
  `fix --pedantic` over the 599 valid files changes **only** insignificant bytes
  (whitespace / BOM) — proven by stripping whitespace+BOM from both sides and
  comparing — never breaks the parse, and is idempotent. A style fix can't change
  what the code means. (`tests/style.sh`)

Run it yourself:

```sh
bash tests/run.sh        # fix + feature + style tests, 599-file zero-FP proof, 2890-file realism gate
```

The expanded auto-fixes (`unclosed-bracket`, `unmatched-close`, …) are more
aggressive, but the verify loop keeps the guarantee intact: still **0 changes**
across the 599 valid files, and **0 files ever worsened** across the 2890.

## Build

```sh
bash build.sh            # -> bin/aowlsuggest
```

Nimony builds it with only its own stdlib (aowlparser is consumed as a
subprocess, so no `-p:` include paths are needed). The build serializes native
codegen through a shared lock and prints `BUILD-OK` / `BUILD-FAIL`.

## Layout

| file | role |
|------|------|
| `src/contract.nim` | the seam: run aowlparser, decode its JSON → `seq[Diagnostic]` |
| `src/textedit.nim` | byte-offset edits, line/col mapping, unified diff |
| `src/fixes.nim` | the fix registry + the verified zero-FP apply loop |
| `src/lsp.nim` | diagnostics + code actions as editor JSON |
| `src/lspserver.nim` | the stdio JSON-RPC Language Server |
| `src/sarif.nim` | SARIF 2.1.0 output |
| `src/explain.nim` | the diagnostic-code knowledge base |
| `src/suppress.nim` | inline `# aowlsuggest:ignore` filtering |
| `src/walk.nim` | directory walking + glob excludes |
| `src/jsonout.nim` | JSON string escaping |
| `src/aowlsuggest.nim` | CLI |

## Cooperating with aowlparser

aowlparser is the source of truth for what is an error. If a suggestion needs a
new field or code, that's a coordinated change *there* (a "parser API request"),
bumping the contract in lockstep — never a scrape or re-derivation here.

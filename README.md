# aowlsuggest

The diagnostics / suggestion and editor-integration layer that sits **on top of
[aowlparser](https://github.com/aoughwl/aowlparser)**. Where aowlparser is the
recovering parser that turns Nim source into AIF *and reports every grammar/lex
error it copes with*, aowlsuggest is the layer that makes those errors
**actionable**: verified quick-fixes, batch/CI linting, and editor (LSP)
payloads.

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
aowlsuggest fix   <file> [--write] [--dry-run]   apply verified quick-fixes
aowlsuggest lint  <files...> [--format:json]     batch lint (nonzero exit on error)
aowlsuggest lsp   <file>                          LSP diagnostics + code actions (JSON)
aowlsuggest check <file> [--format:json]          raw diagnostics pass-through
aowlsuggest version                               print the version
```

Common flags:

- `--parser:PATH` — override the aowlparser binary (else `$AOWLPARSER`, else the
  default checkout).
- `--stdin` (with `fix`/`lsp`/`check`) — read the source from stdin instead of a
  file, so an editor can check an **unsaved buffer**. `--filename:NAME` sets the
  path reported in diagnostics and URIs. In this mode `fix` writes the corrected
  source to stdout (pipe it back into the buffer) and its summary to stderr.

### `fix`

Applies the diagnostics' repairs to the source. Four diagnostic codes carry an
**auto-applicable** edit today — each localized and unambiguous:

| code | repair |
|------|--------|
| `assignment-in-condition` | `=` → `==` in a condition |
| `mismatched-bracket` | swap the wrong close bracket for the one that matches its opener |
| `expected-colon` | insert `:` at the end of the block header |
| `missing-routine-equals` | insert `=` after a routine signature that has a body |

Everything else with a repair hint is surfaced as a **suggestion** (needs human
judgement), never auto-applied. `--dry-run` (the default) prints a unified diff;
`--write` applies it. Independent errors — even a cascade — are all repaired in
one pass.

### `lint`

Batch-lints many files. Human-readable by default, `--format:json` for tooling.
Exits non-zero if any file has an error-severity diagnostic or fails to run —
CI-friendly.

### `lsp`

Emits an editor payload: LSP `Diagnostic` objects (0-based ranges,
`relatedInformation`) plus `CodeAction` quick-fixes carrying a `WorkspaceEdit`,
in one JSON object `{uri, diagnostics, codeActions}`. When a diagnostic has more
than one plausible repair (e.g. a mismatched bracket can be fixed at the close
*or* the open), all are emitted as a ranked **"did you mean"** set — the first
marked `isPreferred`, the alternatives offered for the user to pick.

## Zero-false-positive discipline

Inherited from aowlparser and **non-negotiable**: a fix that corrupts valid code
is worse than no fix. So every auto-fix is **verified** — aowlsuggest applies the
candidate edit, re-runs `aowlparser check`, and keeps it only if it **strictly
reduces the error count and introduces no new error code**. The checker itself is
the oracle; a bad edit can never survive.

This is proven against aowlparser's own oracle corpus of known-valid files —
`nimony/src` (184), `nimony/lib` (105), and the full upstream `Nim/lib` (310),
**599 files** — where aowlsuggest reports **0 errors** and proposes **0 fixes**.
Run it yourself:

```sh
bash tests/run.sh        # behavioural fix tests + the 599-file zero-FP proof
```

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
| `src/jsonout.nim` | JSON string escaping |
| `src/aowlsuggest.nim` | CLI |

## Cooperating with aowlparser

aowlparser is the source of truth for what is an error. If a suggestion needs a
new field or code, that's a coordinated change *there* (a "parser API request"),
bumping the contract in lockstep — never a scrape or re-derivation here.

# Parser API requests

Per the cooperation model, anything a suggestion needs that aowlparser's
diagnostic JSON doesn't carry is recorded here as a request to extend
**aowlparser's** schema deliberately — never scraped or re-derived in
aowlsuggest. Each entry: what, why, and the proposed shape.

## 1. A structured `edit` alongside the human `fix` hint

**Status:** open. **Priority:** high — it is the one place aowlsuggest currently
has to interpret a diagnostic rather than just apply it.

**What.** Today each diagnostic carries `fix` as *prose* (`"did you mean '=='?"`,
`"insert ':' at the end of the line"`). aowlsuggest must map `(code, span,
message)` to a concrete text edit itself, in `src/fixes.nim`. That means the
auto-applicable set is a hardcoded four codes (`assignment-in-condition`,
`mismatched-bracket`, `expected-colon`, `missing-routine-equals`); every other
repairable diagnostic degrades to a non-applied "suggestion".

**Why it belongs in aowlparser.** aowlparser already *knows* the exact repair —
it computed the span and wrote the prose. Emitting the edit structurally lets
aowlsuggest apply repairs for **any** code aowlparser can fix, with no per-code
logic and no risk of aowlsuggest's interpretation drifting from aowlparser's
intent. It keeps the "consume, don't re-derive" boundary clean.

**Proposed shape** (additive, back-compatible — `fix` stays for humans):

```json
"edit": { "line": 1, "col": 5, "endCol": 6, "newText": "==" }
```

or, for multi-span repairs, an `"edits": [ … ]` array of the same objects.
Coordinates in the existing token convention (1-based line, 0-based col,
`endCol` exclusive). A pure insertion has `col == endCol`.

With this in place, `planFix` collapses to "apply `edit` if present", and the
zero-FP verification loop (apply → re-check → keep only if strictly better) is
unchanged — it still guards against any bad edit, whoever proposed it.

## 2. (reserved)

No further requests yet. Add them here as suggestions demand data the current
schema can't express.

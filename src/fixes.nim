## fixes.nim — turn aowlparser diagnostics into verified source repairs.
##
## The zero-false-positive rule lives here. aowlsuggest only AUTO-applies a fix
## when the edit is unambiguous and localized, and it VERIFIES every application
## by re-running aowlparser: a candidate is kept only if it strictly reduces the
## error count and introduces no new error code. A fix that would corrupt valid
## code can therefore never survive — the checker itself is the oracle.
##
## Diagnostics whose repair is real but not mechanically unambiguous (e.g.
## "add a condition") are surfaced as SUGGESTIONS with aowlparser's own hint,
## never auto-applied.

import std/strutils
import contract, textedit, explain

type
  FixKind* = enum
    fkNone        ## no repair information at all
    fkSuggestion  ## aowlparser proposed a repair, but it is not safe to apply
                  ## mechanically (needs human judgement)
    fkAuto        ## a concrete, verifiable edit

  PlannedFix* = object
    kind*: FixKind
    edit*: TextEdit   ## meaningful only when kind == fkAuto
    hint*: string     ## human-facing description / suggestion

  AppliedFix* = object
    code*: string
    line*: int
    col*: int
    label*: string

  FixOutcome* = object
    original*: string
    fixed*: string
    applied*: seq[AppliedFix]
    remaining*: seq[Diagnostic]   ## diagnostics still present after fixing
    changed*: bool
    ok*: bool
    error*: string

proc closerFor(openCh: char): char =
  case openCh
  of '(': ')'
  of '[': ']'
  of '{': '}'
  else: '\0'

proc firstQuotedChar(s: string; startAt: int): (char, int) =
  ## Return the first `'x'` single-quoted character in `s` at/after `startAt`,
  ## and the index just past its closing quote. `('\0', -1)` if none.
  var i = startAt
  while i + 2 < s.len:
    if s[i] == '\'' and s[i+2] == '\'':
      return (s[i+1], i + 3)
    inc i
  result = ('\0', -1)

proc charAt(src: string; off: int): char =
  if off >= 0 and off < src.len: src[off] else: '\0'

proc openerFor(closeCh: char): char =
  case closeCh
  of ')': '('
  of ']': '['
  of '}': '{'
  else: '\0'

proc autoEdit(d: Diagnostic; src: string; starts: seq[int]): PlannedFix =
  ## The single PREFERRED auto edit for `d`, or `fkNone`. This is the edit the
  ## `fix` command applies (after verification). Alternatives (for "did you mean"
  ## ranking) live in `candidateFixes`.
  result = PlannedFix(kind: fkNone, edit: TextEdit(startOff: 0, endOff: 0,
                      replacement: "", label: ""), hint: d.fix)
  case d.code
  of "assignment-in-condition":
    # The span is the offending '='. Replace it with '=='.
    let a = lineColToOffset(src, starts, d.line, d.col)
    let b = lineColToOffset(src, starts, d.line, d.endCol)
    if b == a + 1 and charAt(src, a) == '=':
      result.kind = fkAuto
      result.edit = TextEdit(startOff: a, endOff: b, replacement: "==",
                             label: "change '=' to '=='")
      result.hint = "did you mean '=='?"
  of "comparison-in-binding":
    # The mirror of the above: the span is the offending '=='. Replace it with '='.
    let a = lineColToOffset(src, starts, d.line, d.col)
    let b = lineColToOffset(src, starts, d.line, d.endCol)
    if b == a + 2 and charAt(src, a) == '=' and charAt(src, a + 1) == '=':
      result.kind = fkAuto
      result.edit = TextEdit(startOff: a, endOff: b, replacement: "=",
                             label: "change '==' to '='")
      result.hint = "did you mean '='?"
  of "walrus-in-binding":
    # The Pascal/Go ':=' in a binding. The span is ':=' — replace it with '='.
    let a = lineColToOffset(src, starts, d.line, d.col)
    let b = lineColToOffset(src, starts, d.line, d.endCol)
    if b == a + 2 and charAt(src, a) == ':' and charAt(src, a + 1) == '=':
      result.kind = fkAuto
      result.edit = TextEdit(startOff: a, endOff: b, replacement: "=",
                             label: "change ':=' to '='")
      result.hint = "did you mean '='?"
  of "stray-end":
    # Delete the stray `end` keyword (Nim uses indentation, not `end`).
    let a = lineColToOffset(src, starts, d.line, d.col)
    let b = lineColToOffset(src, starts, d.line, d.endCol)
    if b > a and charAt(src, a) == 'e' and charAt(src, a + 1) == 'n' and
       charAt(src, a + 2) == 'd':
      result.kind = fkAuto
      result.edit = TextEdit(startOff: a, endOff: b, replacement: "",
                             label: "remove the 'end'")
      result.hint = "remove the 'end' (Nim uses indentation)"
  of "mut-not-a-keyword":
    # `let/var/const mut x` → `var x` (the Rust mutable-binding habit). The span
    # covers `<keyword> mut`; replace the whole run with `var`. Guard: it starts
    # with a binding keyword and ends with `mut`, so a surprising span no-fixes.
    let a = lineColToOffset(src, starts, d.line, d.col)
    let b = lineColToOffset(src, starts, d.line, d.endCol)
    let startsBinding =
      (charAt(src, a) == 'l' and charAt(src, a+1) == 'e' and charAt(src, a+2) == 't') or
      (charAt(src, a) == 'v' and charAt(src, a+1) == 'a' and charAt(src, a+2) == 'r') or
      (charAt(src, a) == 'c' and charAt(src, a+1) == 'o' and charAt(src, a+2) == 'n')
    if b > a + 3 and startsBinding and
       charAt(src, b-3) == 'm' and charAt(src, b-2) == 'u' and charAt(src, b-1) == 't':
      result.kind = fkAuto
      result.edit = TextEdit(startOff: a, endOff: b, replacement: "var",
                             label: "change '" & substr(src, a, b-1) & "' to 'var'")
      result.hint = "use 'var' for a mutable binding"
  of "go-var-notype":
    # `var x int` → `var x: int` (the Go/Java/C# `name type` binding). The span is
    # the stray TYPE token; walk back over the whitespace to the end of the name
    # and replace that gap with ': ', giving the idiomatic `name: Type`. Guard: the
    # char before the gap isn't already a ':' (so a re-run is a no-op).
    let a = lineColToOffset(src, starts, d.line, d.col)
    var s = a
    while s > 0 and (charAt(src, s - 1) == ' ' or charAt(src, s - 1) == '\t'): dec s
    if s < a and s > 0 and charAt(src, s - 1) != ':':
      result.kind = fkAuto
      result.edit = TextEdit(startOff: s, endOff: a, replacement: ": ",
                             label: "insert ':' before the type")
      result.hint = "a typed binding is 'name: Type'"
  of "c-block-comment":
    # `/* … */` → `#[ … ]#` (swap the block-comment delimiters). The span is `/*`;
    # block comments don't nest, so the first `*/` closes it. If the body itself
    # holds a `]#`, the rewrite won't parse and the verify loop discards it (falling
    # back to a suggestion). An unterminated `/*` has no `*/` and stays a suggestion.
    let a = lineColToOffset(src, starts, d.line, d.col)
    if charAt(src, a) == '/' and charAt(src, a + 1) == '*':
      var i = a + 2
      var close = -1
      while i + 1 < src.len:
        if src[i] == '*' and src[i + 1] == '/':
          close = i
          break
        inc i
      if close > a:
        let inner = substr(src, a + 2, close - 1)
        result.kind = fkAuto
        result.edit = TextEdit(startOff: a, endOff: close + 2,
                               replacement: "#[" & inner & "]#",
                               label: "change '/* … */' to '#[ … ]#'")
        result.hint = "use '#[ … ]#' for a block comment"
  of "angle-bracket-generics":
    # `proc f<T>(…)` → `proc f[T](…)`. The span is the `<`; find its matching `>`
    # (tracking `<`/`>` nesting for `<A<B>>`) and rewrite `<…>` to `[…]`. Bails at
    # a newline; the verify loop discards it if the span was wrong.
    let a = lineColToOffset(src, starts, d.line, d.col)
    if charAt(src, a) == '<':
      var depth = 0
      var i = a
      var close = -1
      while i < src.len:
        let c = src[i]
        if c == '<': inc depth
        elif c == '>':
          dec depth
          if depth == 0:
            close = i
            break
        elif c == '\n':
          break
        inc i
      if close > a:
        let inner = substr(src, a + 1, close - 1)
        result.kind = fkAuto
        result.edit = TextEdit(startOff: a, endOff: close + 1,
                               replacement: "[" & inner & "]",
                               label: "change '<…>' to '[…]'")
        result.hint = "use '[T]' for generics"
  of "arrow-return-type":
    # `proc f() -> T` → `proc f(): T`. Span is `->`; replace with `:`, absorbing
    # one preceding space so the result is the idiomatic `(): T`, not `() : T`.
    let a = lineColToOffset(src, starts, d.line, d.col)
    let b = lineColToOffset(src, starts, d.line, d.endCol)
    if b == a + 2 and charAt(src, a) == '-' and charAt(src, a + 1) == '>':
      var s = a
      if s > 0 and charAt(src, s - 1) == ' ': dec s
      result.kind = fkAuto
      result.edit = TextEdit(startOff: s, endOff: b, replacement: ":",
                             label: "change '->' to a ':' return type")
      result.hint = "write the return type after ':'"
  of "else-if-not-elif":
    # The span covers `else if` (from the `else` to the end of `if`, same line).
    # Collapse the whole run to `elif`. Guard: it really starts with `else` and
    # ends with `if`, so a surprising span degrades to no-fix.
    let a = lineColToOffset(src, starts, d.line, d.col)
    let b = lineColToOffset(src, starts, d.line, d.endCol)
    if b >= a + 6 and charAt(src, a) == 'e' and charAt(src, a+1) == 'l' and
       charAt(src, a+2) == 's' and charAt(src, a+3) == 'e' and
       charAt(src, b-2) == 'i' and charAt(src, b-1) == 'f':
      result.kind = fkAuto
      result.edit = TextEdit(startOff: a, endOff: b, replacement: "elif",
                             label: "change 'else if' to 'elif'")
      result.hint = "use 'elif'"
  of "mismatched-bracket":
    # The span is one wrong closing bracket; swap it for the closer that matches
    # the opener named in the message ("']' does not match '('").
    let a = lineColToOffset(src, starts, d.line, d.col)
    let b = lineColToOffset(src, starts, d.line, d.endCol)
    let cur = charAt(src, a)
    if b == a + 1 and (cur == ')' or cur == ']' or cur == '}'):
      # message is "'X' does not match 'Y'": X is the wrong close, Y the opener.
      # The opener is the SECOND single-quoted character.
      let (_, after1) = firstQuotedChar(d.message, 0)
      var openerCh = '\0'
      if after1 > 0:
        let (o2, _) = firstQuotedChar(d.message, after1)
        openerCh = o2
      let want = closerFor(openerCh)
      if want != '\0' and want != cur:
        result.kind = fkAuto
        result.edit = TextEdit(startOff: a, endOff: b, replacement: $want,
                               label: "change '" & $cur & "' to '" & $want & "'")
        result.hint = "change it to '" & $want & "'"
  of "expected-colon":
    # Insert ':' at the end of the line's content.
    let e = lineContentEndOffset(src, starts, d.line)
    if charAt(src, e - 1) != ':':
      result.kind = fkAuto
      result.edit = TextEdit(startOff: e, endOff: e, replacement: ":",
                             label: "insert ':'")
      result.hint = "insert ':'"
  of "missing-routine-equals":
    # Insert ' =' at the end of the routine's signature (the header line, which
    # `related` points at).
    if d.hasRelated:
      let e = lineContentEndOffset(src, starts, d.relLine)
      if charAt(src, e - 1) != '=':
        result.kind = fkAuto
        result.edit = TextEdit(startOff: e, endOff: e, replacement: " =",
                               label: "insert '='")
        result.hint = "insert '=' after the signature"
  of "unterminated-char":
    # `'a` -> `'a'`: insert the closing quote just past the span. Guard: the span
    # must actually start at a `'`.
    let a = lineColToOffset(src, starts, d.line, d.col)
    let b = lineColToOffset(src, starts, d.line, d.endCol)
    if charAt(src, a) == '\'' and b > a:
      result.kind = fkAuto
      result.edit = TextEdit(startOff: b, endOff: b, replacement: "'",
                             label: "insert closing '\\''")
      result.hint = "add the closing '"
  of "unmatched-close":
    # A surplus close bracket with no opener: delete it. Guard: the span is a
    # single close character.
    let a = lineColToOffset(src, starts, d.line, d.col)
    let b = lineColToOffset(src, starts, d.line, d.endCol)
    let cur = charAt(src, a)
    if b == a + 1 and (cur == ')' or cur == ']' or cur == '}'):
      result.kind = fkAuto
      result.edit = TextEdit(startOff: a, endOff: b, replacement: "",
                             label: "remove unmatched '" & $cur & "'")
      result.hint = "remove the unmatched '" & $cur & "'"
  of "unclosed-bracket":
    # Best-effort: append the matching close at the end of the OPENING bracket's
    # line. Correct for single-line brackets; the verify loop discards it when the
    # bracket legitimately spans lines (the edit won't reduce errors there).
    let a = lineColToOffset(src, starts, d.line, d.col)
    let openCur = charAt(src, a)
    let want = closerFor(openCur)
    if want != '\0':
      let e = lineContentEndOffset(src, starts, d.line)
      result.kind = fkAuto
      result.edit = TextEdit(startOff: e, endOff: e, replacement: $want,
                             label: "add matching '" & $want & "'")
      result.hint = "add a matching '" & $want & "'"
  of "tabs-not-allowed":
    # Only a MID-LINE tab (not indentation) is unambiguous to replace with a
    # space. A leading/indentation tab changes block structure by an unknown
    # amount, so it stays a suggestion.
    let a = lineColToOffset(src, starts, d.line, d.col)
    if charAt(src, a) == '\t':
      let lineStart = starts[d.line - 1]
      var onlyWs = true
      var i = lineStart
      while i < a:
        if src[i] != ' ' and src[i] != '\t': onlyWs = false; break
        inc i
      if not onlyWs:
        result.kind = fkAuto
        result.edit = TextEdit(startOff: a, endOff: a + 1, replacement: " ",
                               label: "replace tab with a space")
        result.hint = "use a space instead of a tab"
  of "unterminated-string":
    # A string literal with no closing quote: append `"` at the end of the line's
    # content. (Nim strings don't span lines, so the close belongs on this line.)
    let e = lineContentEndOffset(src, starts, d.line)
    if charAt(src, e - 1) != '"':
      result.kind = fkAuto
      result.edit = TextEdit(startOff: e, endOff: e, replacement: "\"",
                             label: "insert closing '\"'")
      result.hint = "add the closing \""
  of "invalid-int-literal":
    # A base prefix written with an uppercase letter — `0O5` / `0B1` (and the
    # like). aowlparser spans the two-char prefix (`0O`); lowercase its letter.
    # Only the letter changes, so the literal's value is untouched.
    let a = lineColToOffset(src, starts, d.line, d.col)
    let b = lineColToOffset(src, starts, d.line, d.endCol)
    if b == a + 2 and charAt(src, a) == '0':
      let letter = charAt(src, a + 1)
      var lower = '\0'
      case letter
      of 'O': lower = 'o'
      of 'X': lower = 'x'
      of 'B': lower = 'b'
      else: discard
      if lower != '\0':
        result.kind = fkAuto
        result.edit = TextEdit(startOff: a + 1, endOff: a + 2,
                               replacement: $lower,
                               label: "lowercase the '" & $letter & "' prefix")
        result.hint = "use lowercase '0" & $lower & "'"
  of "unterminated-comment":
    # A `#[` block comment runs to end-of-input with no `]#`; append the closer
    # at the end of the file. The verify loop discards it if that doesn't help.
    let e = src.len
    result.kind = fkAuto
    result.edit = TextEdit(startOff: e, endOff: e, replacement: " ]#",
                           label: "close the block comment with ']#'")
    result.hint = "add a matching ']#'"
  of "trailing-whitespace":
    # aowlparser flags the line (span at the newline) when `--trailing-whitespace`
    # is on. Delete the maximal run of spaces / tabs at the end of the line's
    # content — never the `\r` (that is the `line-ending` concern) or the `\n`.
    let e = lineEndOffset(src, starts, d.line)
    var s = e
    while s > 0 and (src[s-1] == ' ' or src[s-1] == '\t'):
      dec s
    if s < e:
      result.kind = fkAuto
      result.edit = TextEdit(startOff: s, endOff: e, replacement: "",
                             label: "remove trailing whitespace")
      result.hint = "delete the trailing whitespace"
  of "missing-final-newline":
    # The source does not end with a newline (`--final-newline:require`). Append
    # one. Guard: only when the file is non-empty and truly lacks it.
    if src.len > 0 and src[src.len - 1] != '\n':
      let e = src.len
      result.kind = fkAuto
      result.edit = TextEdit(startOff: e, endOff: e, replacement: "\n",
                             label: "add a final newline")
      result.hint = "end the file with a newline"
  of "line-ending":
    # An EOL that violates the requested convention (`--newline:lf|crlf`). The
    # message names the desired end: "expected LF" → drop the `\r`; "expected
    # CRLF" → insert one. Either way the edit is at the line's terminating '\n'.
    let nl = lineEndOffset(src, starts, d.line)   # offset of the '\n' (or EOF)
    if find(d.message, "expected LF") >= 0:
      if nl > 0 and charAt(src, nl - 1) == '\r':
        result.kind = fkAuto
        result.edit = TextEdit(startOff: nl - 1, endOff: nl, replacement: "",
                               label: "convert CRLF to LF")
        result.hint = "use a plain LF line ending"
    elif find(d.message, "expected CRLF") >= 0:
      if nl <= src.len and charAt(src, nl) == '\n' and charAt(src, nl - 1) != '\r':
        result.kind = fkAuto
        result.edit = TextEdit(startOff: nl, endOff: nl, replacement: "\r",
                               label: "convert LF to CRLF")
        result.hint = "use a CRLF line ending"
  of "bom-rejected":
    # A leading UTF-8 BOM (`EF BB BF`) under `--bom:reject`. Strip the 3 bytes.
    if src.len >= 3 and src[0] == '\xEF' and src[1] == '\xBB' and src[2] == '\xBF':
      result.kind = fkAuto
      result.edit = TextEdit(startOff: 0, endOff: 3, replacement: "",
                             label: "strip the leading UTF-8 BOM")
      result.hint = "remove the byte-order mark"
  of "redundant-semicolon":
    # Delete a redundant statement-level trailing `;` (opt-in --style:semicolons).
    # aowlparser only flags a depth-0 one, so deleting it can't break a separator.
    let a = lineColToOffset(src, starts, d.line, d.col)
    let b = lineColToOffset(src, starts, d.line, d.endCol)
    if b == a + 1 and charAt(src, a) == ';':
      result.kind = fkAuto
      result.edit = TextEdit(startOff: a, endOff: b, replacement: "",
                             label: "remove the redundant ';'")
      result.hint = "remove the ';'"
  # NOTE: `unterminated-backtick` is deliberately NOT auto-fixed. A backtick
  # identifier can contain spaces and operators (`` `foo bar` ``, `` `+` ``), so
  # where the closing backtick belongs is genuinely ambiguous: appending it at the
  # line's end turns `` let `a = 1 `` into the nonsense identifier `` `a = 1` ``,
  # which the (syntax-only) checker happily accepts — a fix that passes
  # verification yet means something the author never wrote. It stays a suggestion
  # (see `explain.suggestionFor`).
  else:
    discard

proc planFix*(d: Diagnostic; src: string; starts: seq[int]): PlannedFix =
  ## The preferred repair for `d`: its auto edit if one exists, else a suggestion.
  ## The suggestion text is aowlparser's own `fix` hint when it gave one (it is
  ## context-specific and authoritative); otherwise a crisp fallback from the
  ## knowledge base, so every diagnostic carries guidance — nothing is left bare.
  result = autoEdit(d, src, starts)
  if result.kind == fkNone:
    if d.fix.len > 0:
      result.kind = fkSuggestion
      result.hint = d.fix
    else:
      let kb = suggestionFor(d.code)
      if kb.len > 0:
        result.kind = fkSuggestion
        result.hint = kb

proc candidateFixes*(d: Diagnostic; src: string; starts: seq[int]): seq[PlannedFix] =
  ## All plausible auto edits for `d`, most-preferred first — the "did you mean"
  ## set an editor offers. The first is what `fix` applies; the rest are equally
  ## valid alternatives a human might prefer (e.g. fixing the OPENING bracket
  ## instead of the closing one). Only auto edits appear here; suggestions do not.
  result = @[]
  let primary = autoEdit(d, src, starts)
  if primary.kind == fkAuto:
    result.add primary
  # A mismatched bracket can also be repaired at the OPENER: change the '(' the
  # message names to the opener that matches the actual close. `related` carries
  # the opener's position.
  if d.code == "mismatched-bracket" and d.hasRelated:
    let a = lineColToOffset(src, starts, d.line, d.col)
    let cur = charAt(src, a)
    let oa = lineColToOffset(src, starts, d.relLine, d.relCol)
    let openCur = charAt(src, oa)
    let wantOpen = openerFor(cur)
    if (openCur == '(' or openCur == '[' or openCur == '{') and
       wantOpen != '\0' and wantOpen != openCur:
      result.add PlannedFix(kind: fkAuto,
        edit: TextEdit(startOff: oa, endOff: oa + 1, replacement: $wantOpen,
          label: "change the opening '" & $openCur & "' to '" & $wantOpen & "'"),
        hint: "or change the opener to '" & $wantOpen & "'")

proc errorCodes(diags: seq[Diagnostic]): seq[string] =
  result = @[]
  for i in 0 ..< diags.len:
    if diags[i].severity == sevError:
      result.add diags[i].code

proc allCodes(diags: seq[Diagnostic]): seq[string] =
  result = @[]
  for i in 0 ..< diags.len:
    result.add diags[i].code

proc containsStr(xs: seq[string]; s: string): bool =
  for i in 0 ..< xs.len:
    if xs[i] == s: return true
  return false

proc improves(before, after: CheckResult): bool =
  ## Whether a candidate edit is a strict improvement — the zero-FP gate. An edit
  ## is kept only if the checker still ran (`after.ok`), it introduces no new
  ## ERROR code, and one of two branches holds:
  ##
  ## * **Error branch** — the error count strictly drops. This is the original
  ##   rule for syntax repairs; a fix may still legitimately unmask a *warning*.
  ## * **Warning branch** — the error count is unchanged, the *total* diagnostic
  ##   count strictly drops, and no new code of ANY severity appears. This lets a
  ##   verified STYLE fix (trailing whitespace, missing final newline, CRLF, BOM)
  ##   be accepted, while still forbidding it from trading one warning for another
  ##   or perturbing the parse (which would change some code).
  ##
  ## Either way a fix can never trade one problem for a different, possibly worse,
  ## one — the checker itself is the oracle.
  if not after.ok: return false
  let oldErr = errorCodes(before.diags)
  let newErr = errorCodes(after.diags)
  for i in 0 ..< newErr.len:
    if not containsStr(oldErr, newErr[i]):
      return false
  # Error branch: strictly fewer errors (warnings may shift — original rule).
  if after.errorCount < before.errorCount:
    return true
  # Warning branch: errors unchanged, strictly fewer diagnostics overall, and no
  # new code of any severity (so nothing was unmasked or swapped).
  if after.errorCount == before.errorCount and
     after.diags.len < before.diags.len:
    let oldAll = allCodes(before.diags)
    let newAll = allCodes(after.diags)
    for i in 0 ..< newAll.len:
      if not containsStr(oldAll, newAll[i]):
        return false
    return true
  return false

proc diagKey(d: Diagnostic): string =
  d.code & ":" & $d.line & ":" & $d.col

proc autofix*(parserBin, src: string; extra = ""): FixOutcome =
  ## Iteratively apply verified fixes until none remain. Each accepted edit
  ## strictly lowers the error count (or, for a style fix, the total diagnostic
  ## count), so the loop is bounded by the initial number of diagnostics; a hard
  ## cap guards against any pathological case. `extra` carries the opt-in lint
  ## flags (see `contract.checkSource`): every check here — the survey AND the
  ## per-candidate verify — runs under the SAME policy, so a style fix is judged
  ## against the same rules that surfaced it.
  result = FixOutcome(original: src, fixed: src, applied: @[], remaining: @[],
                      changed: false, ok: true, error: "")
  var current = src
  var tried: seq[string] = @[]
  var iterations = 0
  let maxIter = 10000
  while iterations < maxIter:
    inc iterations
    let res = checkSource(parserBin, current, extra)
    if not res.ok:
      result.ok = false
      result.error = res.error
      result.fixed = current
      result.remaining = res.diags
      return
    # find the first source-ordered diagnostic with an untried auto fix
    var starts = lineStarts(current)
    var picked = -1
    var plan = PlannedFix(kind: fkNone, edit: TextEdit(startOff: 0, endOff: 0,
                          replacement: "", label: ""), hint: "")
    for i in 0 ..< res.diags.len:
      let p = planFix(res.diags[i], current, starts)
      if p.kind == fkAuto and not containsStr(tried, diagKey(res.diags[i])):
        picked = i
        plan = p
        break
    if picked < 0:
      # nothing left to auto-apply
      result.fixed = current
      result.remaining = res.diags
      result.changed = (current != src)
      return
    let d = res.diags[picked]
    let candidate = applyEdit(current, plan.edit)
    let cres = checkSource(parserBin, candidate)
    if improves(res, cres):
      current = candidate
      result.applied.add AppliedFix(code: d.code, line: d.line, col: d.col,
                                    label: plan.edit.label)
      tried = @[]   # positions shifted; reconsider everything
    else:
      tried.add diagKey(d)
  # cap hit (should never happen)
  result.fixed = current
  let final = checkSource(parserBin, current)
  result.remaining = final.diags
  result.changed = (current != src)

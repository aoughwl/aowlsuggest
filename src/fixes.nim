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
import contract, textedit

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

proc planFix*(d: Diagnostic; src: string; starts: seq[int]): PlannedFix =
  ## Decide how (if at all) diagnostic `d` can be repaired in `src`. Only the
  ## four codes below yield an `fkAuto` edit; each carries a guard so a
  ## surprising span degrades to "no auto-fix" rather than a bad splice.
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
    if result.kind != fkAuto and d.fix.len > 0:
      result.kind = fkSuggestion
  else:
    if d.fix.len > 0:
      result.kind = fkSuggestion
  # A diagnostic that carries a fix hint but got no auto edit is a suggestion.
  if result.kind == fkNone and d.fix.len > 0:
    result.kind = fkSuggestion

proc errorCodes(diags: seq[Diagnostic]): seq[string] =
  result = @[]
  for i in 0 ..< diags.len:
    if diags[i].severity == sevError:
      result.add diags[i].code

proc containsStr(xs: seq[string]; s: string): bool =
  for i in 0 ..< xs.len:
    if xs[i] == s: return true
  return false

proc improves(before, after: CheckResult): bool =
  ## An edit is accepted only if it strictly reduces the error count AND every
  ## error code remaining afterwards was already present before — so a fix can
  ## never trade one problem for a different (possibly worse) one.
  if not after.ok: return false
  if after.errorCount >= before.errorCount: return false
  let oldCodes = errorCodes(before.diags)
  let newCodes = errorCodes(after.diags)
  for i in 0 ..< newCodes.len:
    if not containsStr(oldCodes, newCodes[i]):
      return false
  return true

proc diagKey(d: Diagnostic): string =
  d.code & ":" & $d.line & ":" & $d.col

proc autofix*(parserBin, src: string): FixOutcome =
  ## Iteratively apply verified fixes until none remain. Each accepted edit
  ## strictly lowers the error count, so the loop is bounded by the initial
  ## number of errors; a hard cap guards against any pathological case.
  result = FixOutcome(original: src, fixed: src, applied: @[], remaining: @[],
                      changed: false, ok: true, error: "")
  var current = src
  var tried: seq[string] = @[]
  var iterations = 0
  let maxIter = 10000
  while iterations < maxIter:
    inc iterations
    let res = checkSource(parserBin, current)
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

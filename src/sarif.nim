## sarif.nim — emit diagnostics as SARIF 2.1.0, the format GitHub code scanning
## (and many CI dashboards) ingest. Coordinates are converted to SARIF's 1-based
## line AND column convention (endColumn is the column just past the span).
##
## When a diagnostic has verified auto-fix candidates, they are emitted as SARIF
## `fixes` — so GitHub code scanning renders them as one-click "Apply fix"
## suggestions in the PR. The edits are the same localized fkAuto edits the `fix`
## command applies; only auto (never merely suggested) fixes are surfaced here.

import jsonout, contract, explain, textedit, fixes

proc sarifLevel(s: Severity): string =
  case s
  of sevError: "error"
  of sevWarn: "warning"
  of sevHint: "note"

proc containsStr(xs: seq[string]; s: string): bool =
  for i in 0 ..< xs.len:
    if xs[i] == s: return true
  return false

proc offsetToLineCol(starts: seq[int]; off: int): (int, int) =
  ## Map a byte offset to (1-based line, 0-based byte column), matching the
  ## byte-column convention the rest of this file already uses for SARIF columns.
  var line = 1
  for k in 0 ..< starts.len:
    if starts[k] <= off: line = k + 1
    else: break
  let col = off - starts[line - 1]
  result = (line, col)

proc sarifFixes(d: Diagnostic; file, src: string; starts: seq[int]): string =
  ## The SARIF `fixes` array for `d` (its verified auto-fix candidates), or "" if
  ## there are none. Each candidate becomes one fix with a single replacement.
  let cands = candidateFixes(d, src, starts)
  if cands.len == 0: return ""
  var arr = "["
  var first = true
  for i in 0 ..< cands.len:
    let e = cands[i].edit
    let (sl, sc) = offsetToLineCol(starts, e.startOff)
    let (el, ec) = offsetToLineCol(starts, e.endOff)
    if not first: arr.add ","
    first = false
    # deletedRegion columns are 1-based, endColumn exclusive (== startColumn for
    # a pure insertion). insertedContent carries the replacement text.
    arr.add "{\"description\":{\"text\":" & jStr(cands[i].edit.label) & "}," &
      "\"artifactChanges\":[{\"artifactLocation\":{\"uri\":" & jStr(file) & "}," &
      "\"replacements\":[{\"deletedRegion\":{" &
        "\"startLine\":" & $sl & ",\"startColumn\":" & $(sc + 1) &
        ",\"endLine\":" & $el & ",\"endColumn\":" & $(ec + 1) & "}"
    if e.replacement.len > 0:
      arr.add ",\"insertedContent\":{\"text\":" & jStr(e.replacement) & "}"
    arr.add "}]}]}"
  arr.add "]"
  result = arr

proc sarifRun*(files: seq[string]; diagsPerFile: seq[seq[Diagnostic]];
               version: string; sources: seq[string] = @[]): string =
  ## One SARIF run over parallel `files` / `diagsPerFile`. Rules are the distinct
  ## codes actually seen, described from the knowledge base. When `sources` is
  ## supplied (parallel to `files`), each result also carries SARIF `fixes` for
  ## the diagnostic's verified auto-fix candidates.
  # collect distinct rule ids in first-seen order
  var ruleIds: seq[string] = @[]
  for fi in 0 ..< diagsPerFile.len:
    let ds = diagsPerFile[fi]
    for i in 0 ..< ds.len:
      if not containsStr(ruleIds, ds[i].code):
        ruleIds.add ds[i].code

  var rules = "["
  for i in 0 ..< ruleIds.len:
    if i > 0: rules.add ","
    rules.add "{\"id\":" & jStr(ruleIds[i]) &
      ",\"name\":" & jStr(ruleIds[i]) &
      ",\"shortDescription\":{\"text\":" & jStr(shortDescription(ruleIds[i])) & "}}"
  rules.add "]"

  var results = "["
  var firstResult = true
  for fi in 0 ..< files.len:
    let file = files[fi]
    let ds = if fi < diagsPerFile.len: diagsPerFile[fi] else: @[]
    let src = if fi < sources.len: sources[fi] else: ""
    let starts = if src.len > 0: lineStarts(src) else: @[0]
    for i in 0 ..< ds.len:
      let d = ds[i]
      if not firstResult: results.add ","
      firstResult = false
      results.add "{\"ruleId\":" & jStr(d.code) &
        ",\"level\":" & jStr(sarifLevel(d.severity)) &
        ",\"message\":{\"text\":" & jStr(d.message) & "}" &
        ",\"locations\":[{\"physicalLocation\":{" &
          "\"artifactLocation\":{\"uri\":" & jStr(file) & "}," &
          "\"region\":{\"startLine\":" & $d.line &
            ",\"startColumn\":" & $(d.col + 1) &
            ",\"endColumn\":" & $(d.endCol + 1) & "}}}]"
      if src.len > 0:
        let fx = sarifFixes(d, file, src, starts)
        if fx.len > 0: results.add ",\"fixes\":" & fx
      results.add "}"
  results.add "]"

  result = "{\"$schema\":\"https://json.schemastore.org/sarif-2.1.0.json\"," &
    "\"version\":\"2.1.0\",\"runs\":[{\"tool\":{\"driver\":{" &
    "\"name\":\"aowlsuggest\"," &
    "\"informationUri\":\"https://github.com/aoughwl/aowlsuggest\"," &
    "\"version\":" & jStr(version) & ",\"rules\":" & rules & "}}," &
    "\"results\":" & results & "}]}"

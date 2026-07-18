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

proc trimmedLine(src: string; starts: seq[int]; line1: int): string =
  ## The content of 1-based line `line1`, stripped of leading/trailing whitespace
  ## (spaces, tabs, CR). Manual trim — `strutils.strip` with named args is
  ## ambiguous under nimony.
  if line1 < 1 or line1 - 1 >= starts.len: return ""
  var s = starts[line1 - 1]
  var e = if line1 < starts.len: starts[line1] else: src.len
  while e > s and (src[e-1] == '\n' or src[e-1] == '\r' or src[e-1] == ' ' or
                   src[e-1] == '\t'): dec e
  while s < e and (src[s] == ' ' or src[s] == '\t'): inc s
  result = substr(src, s, e - 1)

proc fnv1aHex(s: string): string =
  ## FNV-1a (32-bit) of `s`, lower-hex. Deterministic and dependency-free — used
  ## for a stable per-alert fingerprint. Unsigned arithmetic wraps in nimony.
  var h: uint32 = 2166136261'u32
  for i in 0 ..< s.len:
    h = h xor uint32(ord(s[i]))
    h = h * 16777619'u32
  const hexd = "0123456789abcdef"
  result = ""
  var shift = 28
  while shift >= 0:
    result.add hexd[int((h shr uint32(shift)) and 0xF'u32)]
    shift = shift - 4

proc lineFingerprint(code: string; src: string; starts: seq[int]; line1: int): string =
  ## A fingerprint that is STABLE when code moves up/down the file: it hashes the
  ## rule id together with the diagnostic's (trimmed) source line, NOT its line
  ## number. GitHub code scanning uses this to track the same alert across commits
  ## instead of churning it on every edit elsewhere in the file.
  result = fnv1aHex(code & "\x1f" & trimmedLine(src, starts, line1))

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
        # a line-content-based fingerprint so GitHub tracks the alert across
        # commits even when unrelated edits shift its line number
        results.add ",\"partialFingerprints\":{\"primaryLocationLineHash\":" &
          jStr(lineFingerprint(d.code, src, starts, d.line)) & "}"
        let fx = sarifFixes(d, file, src, starts)
        if fx.len > 0: results.add ",\"fixes\":" & fx
      results.add "}"
  results.add "]"

  result = "{\"$schema\":\"https://json.schemastore.org/sarif-2.1.0.json\"," &
    "\"version\":\"2.1.0\",\"runs\":[{\"tool\":{\"driver\":{" &
    "\"name\":\"aowlsuggest\"," &
    "\"informationUri\":\"https://github.com/aoughwl/aowlsuggest\"," &
    "\"version\":" & jStr(version) & ",\"rules\":" & rules & "}}," &
    "\"automationDetails\":{\"id\":\"aowlsuggest/lint/\"}," &
    "\"results\":" & results & "}]}"

## sarif.nim — emit diagnostics as SARIF 2.1.0, the format GitHub code scanning
## (and many CI dashboards) ingest. Coordinates are converted to SARIF's 1-based
## line AND column convention (endColumn is the column just past the span).

import jsonout, contract, explain

proc sarifLevel(s: Severity): string =
  case s
  of sevError: "error"
  of sevWarn: "warning"
  of sevHint: "note"

proc containsStr(xs: seq[string]; s: string): bool =
  for i in 0 ..< xs.len:
    if xs[i] == s: return true
  return false

proc sarifRun*(files: seq[string]; diagsPerFile: seq[seq[Diagnostic]];
               version: string): string =
  ## One SARIF run over parallel `files` / `diagsPerFile`. Rules are the distinct
  ## codes actually seen, described from the knowledge base.
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
            ",\"endColumn\":" & $(d.endCol + 1) & "}}}]}"
  results.add "]"

  result = "{\"$schema\":\"https://json.schemastore.org/sarif-2.1.0.json\"," &
    "\"version\":\"2.1.0\",\"runs\":[{\"tool\":{\"driver\":{" &
    "\"name\":\"aowlsuggest\"," &
    "\"informationUri\":\"https://github.com/aoughwl/aowlsuggest\"," &
    "\"version\":" & jStr(version) & ",\"rules\":" & rules & "}}," &
    "\"results\":" & results & "}]}"

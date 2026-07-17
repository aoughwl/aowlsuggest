## lsp.nim — convert aowlparser diagnostics into editor-facing JSON: LSP
## `Diagnostic` objects (0-based ranges, related information) and `CodeAction`
## quick-fixes carrying a `WorkspaceEdit`. This is the "editor surface" layer;
## it derives everything from the diagnostics + the fix planner and never looks
## at Nim syntax itself.

import std/[os, strutils]
import contract, textedit, fixes, jsonout

proc lspSeverity(s: Severity): int =
  ## LSP DiagnosticSeverity: 1 Error, 2 Warning, 3 Information, 4 Hint.
  case s
  of sevError: 1
  of sevWarn: 2
  of sevHint: 4

proc toFileUri*(pathArg: string): string =
  ## A `file://` URI for `pathArg`, resolved against the cwd when relative.
  var p = pathArg
  if p.len == 0 or p[0] != '/':
    try:
      p = getCurrentDir() & "/" & pathArg
    except:
      p = pathArg
  result = "file://" & p

proc offsetToLineCol(starts: seq[int]; off: int): (int, int) =
  ## (1-based line, 0-based column) for a byte offset.
  var line = 1
  for k in 0 ..< starts.len:
    if starts[k] <= off: line = k + 1
    else: break
  let col = off - starts[line - 1]
  result = (line, col)

proc rangeJson(sl, sc, el, ec: int): string =
  ## An LSP Range with 0-based line/character (input lines are 1-based).
  "{\"start\":{\"line\":" & $(sl - 1) & ",\"character\":" & $sc &
    "},\"end\":{\"line\":" & $(el - 1) & ",\"character\":" & $ec & "}}"

proc diagJson(d: Diagnostic; uri: string): string =
  ## One LSP Diagnostic. `endCol == col` (a point span) is widened by nothing —
  ## editors render a zero-width range at that column, which is correct.
  result = "{\"range\":" & rangeJson(d.line, d.col, d.line, d.endCol) &
    ",\"severity\":" & $lspSeverity(d.severity) &
    ",\"code\":" & jStr(d.code) &
    ",\"source\":\"aowlparser\"" &
    ",\"message\":" & jStr(d.message)
  if d.hasRelated:
    result.add ",\"relatedInformation\":[{\"location\":{\"uri\":" & jStr(uri) &
      ",\"range\":" & rangeJson(d.relLine, d.relCol, d.relLine, d.relCol) &
      "},\"message\":" & jStr(d.relMsg) & "}]"
  result.add "}"

proc diagnosticsJson*(file, src: string; diags: seq[Diagnostic]): string =
  ## An LSP `PublishDiagnosticsParams`-shaped object: `{uri, diagnostics:[...]}`.
  let uri = toFileUri(file)
  result = "{\"uri\":" & jStr(uri) & ",\"diagnostics\":["
  for i in 0 ..< diags.len:
    if i > 0: result.add ","
    result.add diagJson(diags[i], uri)
  result.add "]}"

proc codeActionsJson*(file, src: string; diags: seq[Diagnostic]): string =
  ## An array of LSP `CodeAction` quick-fixes. Each diagnostic contributes ALL
  ## its plausible auto edits (the "did you mean" set), ranked — the first is
  ## marked `isPreferred` (what `fix` would apply), the alternatives are equally
  ## valid choices an editor can offer.
  let uri = toFileUri(file)
  let starts = lineStarts(src)
  result = "["
  var first = true
  for i in 0 ..< diags.len:
    let d = diags[i]
    let cands = candidateFixes(d, src, starts)
    for ci in 0 ..< cands.len:
      let plan = cands[ci]
      let (sl, sc) = offsetToLineCol(starts, plan.edit.startOff)
      let (el, ec) = offsetToLineCol(starts, plan.edit.endOff)
      if not first: result.add ","
      first = false
      result.add "{\"title\":" & jStr(plan.edit.label) &
        ",\"kind\":\"quickfix\",\"isPreferred\":" &
        (if ci == 0: "true" else: "false") &
        ",\"diagnostics\":[" & diagJson(d, uri) & "]" &
        ",\"edit\":{\"changes\":{" & jStr(uri) & ":[{\"range\":" &
          rangeJson(sl, sc, el, ec) &
          ",\"newText\":" & jStr(plan.edit.replacement) & "}]}}}"
  result.add "]"

proc lspReportJson*(file, src: string; diags: seq[Diagnostic]): string =
  ## Combined editor payload: diagnostics + code actions in one object.
  result = "{\"uri\":" & jStr(toFileUri(file)) &
    ",\"diagnostics\":"
  # reuse diagnosticsJson's inner array by slicing off its wrapper is fiddly;
  # just rebuild the array here for a self-contained object.
  result.add "["
  let uri = toFileUri(file)
  for i in 0 ..< diags.len:
    if i > 0: result.add ","
    result.add diagJson(diags[i], uri)
  result.add "],\"codeActions\":"
  result.add codeActionsJson(file, src, diags)
  result.add "}"

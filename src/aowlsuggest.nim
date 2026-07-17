## aowlsuggest — the diagnostics / suggestion + editor-integration layer on top
## of aowlparser.
##
## aowlsuggest CONSUMES aowlparser's diagnostics; it never lexes or parses Nim
## itself (see `contract.nim`). The raw errors — bad tokens, missing ':',
## missing '=', unbalanced brackets — are produced inside aowlparser's
## recovering parse. This tool turns those structured diagnostics into
## verifiable quick-fixes, batch/CI linting, and editor (LSP) payloads.
##
## Commands:
##   aowlsuggest fix   <file> [--write] [--dry-run]   apply verified quick-fixes
##   aowlsuggest lint  <files...> [--format:json]     batch lint (CI exit code)
##   aowlsuggest lsp   <file>                          LSP diagnostics + actions
##   aowlsuggest check <file>                          raw pass-through diagnostics
##
## Common flags: --parser:PATH (aowlparser binary; else $AOWLPARSER or default).

import std/[syncio, cmdline, strutils]
import contract, textedit, fixes, lsp, jsonout

proc afterColon(s: string): string =
  var i = 0
  while i < s.len and s[i] != ':': inc i
  if i < s.len: inc i
  result = ""
  while i < s.len:
    result.add s[i]; inc i

proc sevName(s: Severity): string =
  case s
  of sevError: "error"
  of sevWarn: "warning"
  of sevHint: "hint"

proc diagLine(file: string; d: Diagnostic): string =
  ## Compiler-style `file:line:col: severity[code]: message` (col shown 1-based
  ## for humans, as aowlparser's own text mode does).
  result = file & ":" & $d.line & ":" & $(d.col + 1) & ": " &
    sevName(d.severity) & "[" & d.code & "]: " & d.message
  if d.hasRelated:
    result.add "\n  note: " & d.relMsg & " (" & file & ":" & $d.relLine &
      ":" & $(d.relCol + 1) & ")"
  if d.fix.len > 0:
    result.add "\n  help: " & d.fix

proc diagRawJson(file: string; d: Diagnostic): string =
  ## Native-shape diagnostic JSON (aowlparser's coordinates: line 1-based, col
  ## 0-based) plus the owning `file`.
  result = "{\"file\":" & jStr(file) &
    ",\"severity\":" & jStr(sevName(d.severity)) &
    ",\"code\":" & jStr(d.code) &
    ",\"message\":" & jStr(d.message) &
    ",\"line\":" & $d.line & ",\"col\":" & $d.col & ",\"endCol\":" & $d.endCol
  if d.fix.len > 0:
    result.add ",\"fix\":" & jStr(d.fix)
  if d.hasRelated:
    result.add ",\"related\":{\"message\":" & jStr(d.relMsg) &
      ",\"line\":" & $d.relLine & ",\"col\":" & $d.relCol & "}"
  result.add "}"

proc readSource(file: string; ok: var bool): string =
  ok = true
  try:
    result = readFile(file)
  except:
    ok = false
    result = ""

# ── fix ──────────────────────────────────────────────────────────────────────

proc cmdFix(parserBin, file: string; doWrite: bool): int =
  var readOk = false
  let src = readSource(file, readOk)
  if not readOk:
    write stderr, "aowlsuggest: cannot read file: " & file & "\n"
    return 2
  let outcome = autofix(parserBin, src)
  if not outcome.ok:
    write stderr, "aowlsuggest: " & outcome.error & "\n"
    return 2
  # Report the suggestions and still-unfixed errors from what remains.
  var suggestions: seq[string] = @[]
  var remainingErrors = 0
  let starts = lineStarts(outcome.fixed)
  for i in 0 ..< outcome.remaining.len:
    let d = outcome.remaining[i]
    if d.severity == sevError: inc remainingErrors
    let plan = planFix(d, outcome.fixed, starts)
    if plan.kind == fkSuggestion:
      suggestions.add diagLine(file, d)
  if doWrite:
    if outcome.changed:
      try:
        writeFile(file, outcome.fixed)
      except:
        write stderr, "aowlsuggest: cannot write file: " & file & "\n"
        return 2
      write stdout, "fixed " & file & ": applied " & $outcome.applied.len &
        " change(s)\n"
      for i in 0 ..< outcome.applied.len:
        let a = outcome.applied[i]
        write stdout, "  - " & a.label & " (was " & a.code & " at " &
          $a.line & ":" & $(a.col + 1) & ")\n"
    else:
      write stdout, "no automatic fixes for " & file & "\n"
  else:
    # dry-run: show the diff and what would change.
    if outcome.changed:
      write stdout, unifiedDiff(file, file & " (fixed)", src, outcome.fixed)
      write stdout, "\n" & $outcome.applied.len & " fix(es) available " &
        "(re-run with --write to apply)\n"
    else:
      write stdout, "no automatic fixes for " & file & "\n"
  if suggestions.len > 0:
    write stdout, "\nsuggestions (need human judgement — not auto-applied):\n"
    for i in 0 ..< suggestions.len:
      write stdout, "  " & suggestions[i] & "\n"
  if remainingErrors > 0:
    write stdout, "\n" & $remainingErrors &
      " error(s) remain that could not be auto-fixed\n"
  return 0

# ── lint ─────────────────────────────────────────────────────────────────────

proc cmdLint(parserBin: string; files: seq[string]; asJson: bool): int =
  var totalErrors = 0
  var totalWarnings = 0
  var runFailures = 0
  if asJson:
    var s = "{\"files\":["
    var firstFile = true
    for fi in 0 ..< files.len:
      let file = files[fi]
      let res = runCheckerOnFile(parserBin, file)
      if not firstFile: s.add ","
      firstFile = false
      var ferr = 0
      for i in 0 ..< res.diags.len:
        if res.diags[i].severity == sevError: inc ferr
        elif res.diags[i].severity == sevWarn: inc totalWarnings
      totalErrors += ferr
      if not res.ok: inc runFailures
      s.add "{\"file\":" & jStr(file) & ",\"ok\":" & (if res.ok: "true" else: "false")
      if not res.ok:
        s.add ",\"error\":" & jStr(res.error)
      s.add ",\"errorCount\":" & $ferr & ",\"diagnostics\":["
      for i in 0 ..< res.diags.len:
        if i > 0: s.add ","
        s.add diagRawJson(file, res.diags[i])
      s.add "]}"
    s.add "],\"summary\":{\"files\":" & $files.len & ",\"errors\":" &
      $totalErrors & ",\"warnings\":" & $totalWarnings & ",\"runFailures\":" &
      $runFailures & "}}"
    write stdout, s & "\n"
  else:
    var filesWithIssues = 0
    for fi in 0 ..< files.len:
      let file = files[fi]
      let res = runCheckerOnFile(parserBin, file)
      if not res.ok:
        inc runFailures
        write stderr, "aowlsuggest: " & file & ": " & res.error & "\n"
        continue
      if res.diags.len > 0: inc filesWithIssues
      for i in 0 ..< res.diags.len:
        let d = res.diags[i]
        if d.severity == sevError: inc totalErrors
        elif d.severity == sevWarn: inc totalWarnings
        write stdout, diagLine(file, d) & "\n"
    write stdout, "\n" & $files.len & " file(s) checked, " &
      $filesWithIssues & " with issues: " & $totalErrors & " error(s), " &
      $totalWarnings & " warning(s)\n"
  if totalErrors > 0 or runFailures > 0: return 1
  return 0

# ── lsp ──────────────────────────────────────────────────────────────────────

proc cmdLsp(parserBin, file: string): int =
  var readOk = false
  let src = readSource(file, readOk)
  if not readOk:
    write stderr, "aowlsuggest: cannot read file: " & file & "\n"
    return 2
  let res = runCheckerOnFile(parserBin, file)
  if not res.ok:
    write stderr, "aowlsuggest: " & res.error & "\n"
    return 2
  write stdout, lspReportJson(file, src, res.diags) & "\n"
  if res.errorCount > 0: return 1
  return 0

# ── check (pass-through) ─────────────────────────────────────────────────────

proc cmdCheck(parserBin, file: string; asJson: bool): int =
  let res = runCheckerOnFile(parserBin, file)
  if not res.ok:
    write stderr, "aowlsuggest: " & res.error & "\n"
    return 2
  if asJson:
    var s = "["
    for i in 0 ..< res.diags.len:
      if i > 0: s.add ","
      s.add diagRawJson(file, res.diags[i])
    s.add "]"
    write stdout, s & "\n"
  else:
    for i in 0 ..< res.diags.len:
      write stdout, diagLine(file, res.diags[i]) & "\n"
  if res.errorCount > 0: return 1
  return 0

# ── CLI ──────────────────────────────────────────────────────────────────────

proc usage(): int =
  write stderr, "aowlsuggest — verified quick-fixes & editor diagnostics over aowlparser\n"
  write stderr, "usage:\n"
  write stderr, "  aowlsuggest fix   <file> [--write] [--dry-run]   apply verified quick-fixes\n"
  write stderr, "  aowlsuggest lint  <files...> [--format:json]     batch lint (nonzero exit on error)\n"
  write stderr, "  aowlsuggest lsp   <file>                          LSP diagnostics + code actions (JSON)\n"
  write stderr, "  aowlsuggest check <file> [--format:json]          raw diagnostics pass-through\n"
  write stderr, "flags:\n"
  write stderr, "  --parser:PATH   aowlparser binary (else $AOWLPARSER, else the default checkout)\n"
  write stderr, "  --write         (fix) write changes back to the file\n"
  write stderr, "  --dry-run       (fix) show a unified diff without writing (default)\n"
  write stderr, "  --format:json   (lint/check) machine-readable output\n"
  return 1

proc main(): int =
  var parserBin = defaultParserBin()
  var doWrite = false
  var asJson = false
  var positional: seq[string] = @[]
  let cli = commandLineParams()
  for ci in 0 ..< cli.len:
    let a = cli[ci]
    if a == "--write":
      doWrite = true
    elif a == "--dry-run":
      doWrite = false
    elif a == "--help" or a == "-h":
      return usage()
    elif startsWith(a, "--parser:"):
      parserBin = afterColon(a)
    elif startsWith(a, "--format:"):
      if afterColon(a) == "json": asJson = true
    else:
      positional.add a
  if positional.len < 1:
    return usage()
  let action = positional[0]
  case action
  of "fix":
    if positional.len < 2: return usage()
    return cmdFix(parserBin, positional[1], doWrite)
  of "lint":
    if positional.len < 2: return usage()
    var files: seq[string] = @[]
    for i in 1 ..< positional.len: files.add positional[i]
    return cmdLint(parserBin, files, asJson)
  of "lsp":
    if positional.len < 2: return usage()
    return cmdLsp(parserBin, positional[1])
  of "check":
    if positional.len < 2: return usage()
    return cmdCheck(parserBin, positional[1], asJson)
  else:
    write stderr, "aowlsuggest: unknown command: " & action & "\n"
    return usage()

quit main()

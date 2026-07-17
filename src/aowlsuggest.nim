## aowlsuggest — the diagnostics / suggestion + editor-integration layer on top
## of aowlparser.
##
## aowlsuggest CONSUMES aowlparser's diagnostics; it never lexes or parses Nim
## itself (see `contract.nim`). This tool turns those structured diagnostics into
## verifiable quick-fixes, batch/CI linting (text, JSON, SARIF), editor (LSP)
## payloads and a full LSP server, code explanations, and inline suppression.
##
## Commands:
##   aowlsuggest fix    <paths...> [--write] [--dry-run]     apply verified quick-fixes
##   aowlsuggest lint   <paths...> [--format:text|json|sarif] batch lint (CI exit)
##   aowlsuggest lsp    <file>                                LSP diagnostics + actions (JSON)
##   aowlsuggest lsp-server                                   a stdio LSP server
##   aowlsuggest check  <file> [--format:...]                 raw diagnostics pass-through
##   aowlsuggest explain [code]                               explain a diagnostic code
##   aowlsuggest version
##
## `<paths...>` may be files or directories (walked for *.nim). Common flags:
##   --parser:PATH  --exclude:GLOB  --stdin  --filename:NAME  --stats  --color
##   --no-suppress  (ignore inline `# aowlsuggest:ignore` markers)

import std/[syncio, cmdline, strutils]
import contract, textedit, fixes, lsp, jsonout, walk, sarif, explain, suppress
import lspserver

const aowlsuggestVersion = "0.2.0"

type
  Options = object
    parserBin: string
    excludes: seq[string]
    suppress: bool
    format: string      ## "text" | "json" | "sarif"
    stats: bool
    doWrite: bool
    useStdin: bool
    filename: string
    color: bool

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

proc colorFor(s: Severity): string =
  case s
  of sevError: "\e[31m"    # red
  of sevWarn: "\e[33m"     # yellow
  of sevHint: "\e[36m"     # cyan

proc diagLine(file: string; d: Diagnostic; color: bool): string =
  ## Compiler-style `file:line:col: severity[code]: message` (col shown 1-based
  ## for humans, as aowlparser's own text mode does).
  let sev = if color: colorFor(d.severity) & sevName(d.severity) & "\e[0m"
            else: sevName(d.severity)
  result = file & ":" & $d.line & ":" & $(d.col + 1) & ": " & sev &
    "[" & d.code & "]: " & d.message
  if d.hasRelated:
    result.add "\n  note: " & d.relMsg & " (" & file & ":" & $d.relLine &
      ":" & $(d.relCol + 1) & ")"
  if d.fix.len > 0:
    result.add "\n  help: " & d.fix

proc diagRawJson(file: string; d: Diagnostic): string =
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

proc loadSource(useStdin: bool; file: string; ok: var bool): string =
  if useStdin:
    ok = true
    try:
      result = readAll(stdin)
    except:
      ok = false
      result = ""
  else:
    result = readSource(file, ok)

proc maybeSuppress(opts: Options; src: string; diags: seq[Diagnostic]): seq[Diagnostic] =
  if opts.suppress:
    let f = filterSuppressed(src, diags)
    result = f.kept
  else:
    result = diags

# ── fix ──────────────────────────────────────────────────────────────────────

proc fixOne(opts: Options; file: string; useStdin: bool; displayName: string): int =
  ## Fix a single source (file or stdin). Returns error-remaining count via the
  ## printed summary; the process exit is computed by the caller.
  var readOk = false
  let src = loadSource(useStdin, file, readOk)
  if not readOk:
    write stderr, "aowlsuggest: cannot read " &
      (if useStdin: "stdin" else: "file: " & file) & "\n"
    return 2
  let outcome = autofix(opts.parserBin, src)
  if not outcome.ok:
    write stderr, "aowlsuggest: " & outcome.error & "\n"
    return 2
  var suggestions: seq[string] = @[]
  var remainingErrors = 0
  let starts = lineStarts(outcome.fixed)
  for i in 0 ..< outcome.remaining.len:
    let d = outcome.remaining[i]
    if d.severity == sevError: inc remainingErrors
    let plan = planFix(d, outcome.fixed, starts)
    if plan.kind == fkSuggestion:
      suggestions.add diagLine(displayName, d, opts.color)
  if useStdin:
    write stdout, outcome.fixed
    write stderr, $outcome.applied.len & " fix(es) applied\n"
    for i in 0 ..< outcome.applied.len:
      let a = outcome.applied[i]
      write stderr, "  - " & a.label & " (was " & a.code & " at " &
        $a.line & ":" & $(a.col + 1) & ")\n"
    for i in 0 ..< suggestions.len:
      write stderr, "suggestion: " & suggestions[i] & "\n"
    return 0
  if opts.doWrite:
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
    # a clean file in a batch stays quiet
  else:
    if outcome.changed:
      write stdout, unifiedDiff(displayName, displayName & " (fixed)", src,
        outcome.fixed)
      write stdout, "\n" & $outcome.applied.len & " fix(es) available " &
        "(re-run with --write to apply)\n"
    else:
      write stdout, "no automatic fixes for " & displayName & "\n"
  if suggestions.len > 0:
    write stdout, "\nsuggestions (need human judgement — not auto-applied):\n"
    for i in 0 ..< suggestions.len:
      write stdout, "  " & suggestions[i] & "\n"
  if remainingErrors > 0:
    write stdout, "\n" & $remainingErrors &
      " error(s) remain that could not be auto-fixed\n"
  return 0

proc cmdFix(opts: Options; paths: seq[string]): int =
  if opts.useStdin:
    return fixOne(opts, "", true, opts.filename)
  let files = collectFiles(paths, opts.excludes)
  if files.len == 0:
    write stderr, "aowlsuggest: no .nim files in the given paths\n"
    return 2
  var worstRc = 0
  for i in 0 ..< files.len:
    let rc = fixOne(opts, files[i], false, files[i])
    if rc > worstRc: worstRc = rc
  if opts.doWrite and files.len > 1:
    write stdout, "\n" & $files.len & " file(s) processed\n"
  return worstRc

# ── lint ─────────────────────────────────────────────────────────────────────

proc bump(codes: var seq[string]; counts: var seq[int]; code: string) =
  for i in 0 ..< codes.len:
    if codes[i] == code:
      counts[i] = counts[i] + 1
      return
  codes.add code
  counts.add 1

proc cmdLint(opts: Options; paths: seq[string]): int =
  let files = collectFiles(paths, opts.excludes)
  var totalErrors = 0
  var totalWarnings = 0
  var totalSuppressed = 0
  var runFailures = 0
  var filesWithIssues = 0
  var statCodes: seq[string] = @[]
  var statCounts: seq[int] = @[]
  # per-file diagnostics captured once, reused by every output format
  var allFiles: seq[string] = @[]
  var allDiags: seq[seq[Diagnostic]] = @[]
  for fi in 0 ..< files.len:
    let file = files[fi]
    var readOk = false
    let src = readSource(file, readOk)
    let res = runCheckerOnFile(opts.parserBin, file)
    if not res.ok:
      inc runFailures
      write stderr, "aowlsuggest: " & file & ": " & res.error & "\n"
      allFiles.add file
      allDiags.add @[]
      continue
    var diags = res.diags
    if readOk:
      let before = diags.len
      diags = maybeSuppress(opts, src, diags)
      totalSuppressed += (before - diags.len)
    allFiles.add file
    allDiags.add diags
    if diags.len > 0: inc filesWithIssues
    for i in 0 ..< diags.len:
      if diags[i].severity == sevError: inc totalErrors
      elif diags[i].severity == sevWarn: inc totalWarnings
      bump(statCodes, statCounts, diags[i].code)

  case opts.format
  of "json":
    var s = "{\"files\":["
    for fi in 0 ..< allFiles.len:
      if fi > 0: s.add ","
      var ferr = 0
      for i in 0 ..< allDiags[fi].len:
        if allDiags[fi][i].severity == sevError: inc ferr
      s.add "{\"file\":" & jStr(allFiles[fi]) & ",\"errorCount\":" & $ferr &
        ",\"diagnostics\":["
      for i in 0 ..< allDiags[fi].len:
        if i > 0: s.add ","
        s.add diagRawJson(allFiles[fi], allDiags[fi][i])
      s.add "]}"
    s.add "],\"summary\":{\"files\":" & $files.len & ",\"errors\":" &
      $totalErrors & ",\"warnings\":" & $totalWarnings & ",\"suppressed\":" &
      $totalSuppressed & ",\"runFailures\":" & $runFailures & "}}"
    write stdout, s & "\n"
  of "sarif":
    write stdout, sarifRun(allFiles, allDiags, aowlsuggestVersion) & "\n"
  else:
    for fi in 0 ..< allFiles.len:
      for i in 0 ..< allDiags[fi].len:
        write stdout, diagLine(allFiles[fi], allDiags[fi][i], opts.color) & "\n"
    if opts.stats and statCodes.len > 0:
      write stdout, "\nby code:\n"
      # print sorted by count descending (selection)
      var order: seq[int] = @[]
      for i in 0 ..< statCodes.len: order.add i
      for a in 0 ..< order.len:
        var best = a
        for b in a + 1 ..< order.len:
          if statCounts[order[b]] > statCounts[order[best]]: best = b
        let va = order[a]
        let vb = order[best]
        order[a] = vb
        order[best] = va
      for k in 0 ..< order.len:
        let idx = order[k]
        write stdout, "  " & $statCounts[idx] & "\t" & statCodes[idx] & "\n"
    let sup = if totalSuppressed > 0: ", " & $totalSuppressed & " suppressed" else: ""
    write stdout, "\n" & $files.len & " file(s) checked, " &
      $filesWithIssues & " with issues: " & $totalErrors & " error(s), " &
      $totalWarnings & " warning(s)" & sup & "\n"
  if totalErrors > 0 or runFailures > 0: return 1
  return 0

# ── check ────────────────────────────────────────────────────────────────────

proc cmdCheck(opts: Options; file: string): int =
  var readOk = false
  let src = loadSource(opts.useStdin, file, readOk)
  if not readOk:
    write stderr, "aowlsuggest: cannot read " &
      (if opts.useStdin: "stdin" else: "file: " & file) & "\n"
    return 2
  let displayName = if opts.useStdin: opts.filename else: file
  let res =
    if opts.useStdin: checkSource(opts.parserBin, src)
    else: runCheckerOnFile(opts.parserBin, file)
  if not res.ok:
    write stderr, "aowlsuggest: " & res.error & "\n"
    return 2
  let diags = maybeSuppress(opts, src, res.diags)
  var errCount = 0
  for i in 0 ..< diags.len:
    if diags[i].severity == sevError: inc errCount
  case opts.format
  of "json":
    var s = "["
    for i in 0 ..< diags.len:
      if i > 0: s.add ","
      s.add diagRawJson(displayName, diags[i])
    s.add "]"
    write stdout, s & "\n"
  of "sarif":
    write stdout, sarifRun(@[displayName], @[diags], aowlsuggestVersion) & "\n"
  else:
    for i in 0 ..< diags.len:
      write stdout, diagLine(displayName, diags[i], opts.color) & "\n"
  if errCount > 0: return 1
  return 0

# ── lsp (one-shot payload) ───────────────────────────────────────────────────

proc cmdLsp(opts: Options; file: string): int =
  var readOk = false
  let src = loadSource(opts.useStdin, file, readOk)
  if not readOk:
    write stderr, "aowlsuggest: cannot read " &
      (if opts.useStdin: "stdin" else: "file: " & file) & "\n"
    return 2
  let displayName = if opts.useStdin: opts.filename else: file
  let res =
    if opts.useStdin: checkSource(opts.parserBin, src)
    else: runCheckerOnFile(opts.parserBin, file)
  if not res.ok:
    write stderr, "aowlsuggest: " & res.error & "\n"
    return 2
  write stdout, lspReportJson(displayName, src, res.diags) & "\n"
  if res.errorCount > 0: return 1
  return 0

# ── explain ──────────────────────────────────────────────────────────────────

proc cmdExplain(opts: Options; codeArg: string): int =
  let kb = knowledgeBase()
  if codeArg.len == 0:
    if opts.format == "json":
      var s = "["
      for i in 0 ..< kb.len:
        if i > 0: s.add ","
        s.add "{\"code\":" & jStr(kb[i].code) & ",\"title\":" & jStr(kb[i].title) &
          ",\"autofixable\":" & (if kb[i].autofixable: "true" else: "false") & "}"
      s.add "]"
      write stdout, s & "\n"
    else:
      write stdout, "known diagnostic codes:\n"
      for i in 0 ..< kb.len:
        let mark = if kb[i].autofixable: " [auto-fixable]" else: ""
        write stdout, "  " & kb[i].code & mark & "\n    " & kb[i].title & "\n"
    return 0
  var found = false
  let info = lookup(codeArg, found)
  if not found:
    write stderr, "aowlsuggest: unknown diagnostic code: " & codeArg & "\n"
    return 2
  if opts.format == "json":
    write stdout, "{\"code\":" & jStr(info.code) & ",\"title\":" & jStr(info.title) &
      ",\"explanation\":" & jStr(info.explanation) &
      ",\"badExample\":" & jStr(info.badExample) &
      ",\"goodExample\":" & jStr(info.goodExample) &
      ",\"autofixable\":" & (if info.autofixable: "true" else: "false") & "}\n"
  else:
    write stdout, info.code & " — " & info.title & "\n\n"
    write stdout, info.explanation & "\n"
    if info.badExample.len > 0:
      write stdout, "\n  bad:  " & info.badExample & "\n"
    if info.goodExample.len > 0:
      write stdout, "  good: " & info.goodExample & "\n"
    write stdout, "\nauto-fixable: " &
      (if info.autofixable: "yes" else: "no (reported as a suggestion)") & "\n"
  return 0

# ── CLI ──────────────────────────────────────────────────────────────────────

proc usage(): int =
  write stderr, "aowlsuggest " & aowlsuggestVersion &
    " — verified quick-fixes & editor diagnostics over aowlparser\n"
  write stderr, "usage:\n"
  write stderr, "  aowlsuggest fix    <paths...> [--write] [--dry-run]\n"
  write stderr, "  aowlsuggest lint   <paths...> [--format:text|json|sarif] [--stats]\n"
  write stderr, "  aowlsuggest lsp    <file>\n"
  write stderr, "  aowlsuggest lsp-server\n"
  write stderr, "  aowlsuggest check  <file> [--format:text|json|sarif]\n"
  write stderr, "  aowlsuggest explain [code] [--format:json]\n"
  write stderr, "  aowlsuggest version\n"
  write stderr, "flags:\n"
  write stderr, "  --parser:PATH    aowlparser binary (else $AOWLPARSER, else the default)\n"
  write stderr, "  --exclude:GLOB   skip paths matching GLOB (repeatable; * and ?)\n"
  write stderr, "  --write          (fix) write changes back to the file\n"
  write stderr, "  --dry-run        (fix) show a unified diff without writing (default)\n"
  write stderr, "  --format:FMT     text (default), json, or sarif\n"
  write stderr, "  --stats          (lint) also print a per-code count summary\n"
  write stderr, "  --color          colorize the human-readable output\n"
  write stderr, "  --no-suppress    ignore inline '# aowlsuggest:ignore' markers\n"
  write stderr, "  --stdin          (fix/lsp/check) read source from stdin\n"
  write stderr, "  --filename:NAME  (with --stdin) the path to report\n"
  return 1

proc main(): int =
  var opts = Options(parserBin: defaultParserBin(), excludes: @[],
                     suppress: true, format: "text", stats: false,
                     doWrite: false, useStdin: false, filename: "stdin",
                     color: false)
  var positional: seq[string] = @[]
  let cli = commandLineParams()
  for ci in 0 ..< cli.len:
    let a = cli[ci]
    if a == "--write": opts.doWrite = true
    elif a == "--dry-run": opts.doWrite = false
    elif a == "--stdin": opts.useStdin = true
    elif a == "--stats": opts.stats = true
    elif a == "--color": opts.color = true
    elif a == "--no-suppress": opts.suppress = false
    elif a == "--help" or a == "-h": return usage()
    elif a == "--version":
      write stdout, "aowlsuggest " & aowlsuggestVersion & "\n"; return 0
    elif startsWith(a, "--parser:"): opts.parserBin = afterColon(a)
    elif startsWith(a, "--filename:"): opts.filename = afterColon(a)
    elif startsWith(a, "--exclude:"): opts.excludes.add afterColon(a)
    elif startsWith(a, "--format:"): opts.format = afterColon(a)
    else: positional.add a
  if positional.len < 1: return usage()
  let action = positional[0]
  var rest: seq[string] = @[]
  for i in 1 ..< positional.len: rest.add positional[i]
  case action
  of "fix":
    if not opts.useStdin and rest.len < 1: return usage()
    return cmdFix(opts, rest)
  of "lint":
    if rest.len < 1: return usage()
    return cmdLint(opts, rest)
  of "lsp":
    if not opts.useStdin and rest.len < 1: return usage()
    return cmdLsp(opts, if rest.len >= 1: rest[0] else: "")
  of "lsp-server":
    return runLspServer(opts.parserBin)
  of "check":
    if not opts.useStdin and rest.len < 1: return usage()
    return cmdCheck(opts, if rest.len >= 1: rest[0] else: "")
  of "explain":
    return cmdExplain(opts, if rest.len >= 1: rest[0] else: "")
  of "version":
    write stdout, "aowlsuggest " & aowlsuggestVersion & "\n"; return 0
  else:
    write stderr, "aowlsuggest: unknown command: " & action & "\n"
    return usage()

quit main()

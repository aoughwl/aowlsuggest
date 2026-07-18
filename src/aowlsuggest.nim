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
import lspserver, projconfig

const aowlsuggestVersion = "0.3.0"

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
    checkFlags: string  ## opt-in aowlparser lint flags (see `--style` / `--pedantic`)
    maxWarnings: int    ## lint: fail if warnings exceed this; -1 = unlimited
    quiet: bool         ## suppress warning/hint DISPLAY in text output (still counted)
    checkMode: bool     ## fix --check: report (don't apply) and exit nonzero if unclean

proc afterColon(s: string): string =
  var i = 0
  while i < s.len and s[i] != ':': inc i
  if i < s.len: inc i
  result = ""
  while i < s.len:
    result.add s[i]; inc i

# ── style / lint policy ──────────────────────────────────────────────────────
#
# aowlparser owns diagnostic EMISSION; several of its stylistic checks are gated
# behind flags that are OFF by default (which is exactly why the zero-FP corpus
# stays clean). aowlsuggest turns them on ON REQUEST and makes the resulting
# diagnostics actionable. The mapping below is the whole whitelist — the only
# text that ever reaches aowlparser's command line — so nothing user-controlled
# is interpolated into the shell.

proc styleFlag(cat: string; ok: var bool): string =
  ## Map a `--style:` category to the aowlparser flag that enables it.
  ok = true
  case cat
  of "trailing-whitespace", "trailing": "--trailing-whitespace:warn"
  of "final-newline", "eof-newline": "--final-newline:require"
  of "lf", "newline-lf": "--newline:lf"
  of "crlf", "newline-crlf": "--newline:crlf"
  of "bom": "--bom:reject"
  of "c-operators", "c-ops": "--c-operators:warn"
  of "semicolons", "semicolon": "--semicolons:warn"
  of "idioms", "idiom": "--idioms:warn"
  of "float-equality", "float-eq": "--float-equality:warn"
  of "indent-consistency", "indent": "--indent-consistency"
  else:
    ok = false
    ""

proc addFlag(flags: var string; f: string) =
  ## Append a flag once (dedup keeps the command tidy; repeats are harmless).
  if f.len == 0: return
  var i = 0
  # crude contains-token check; flag set is tiny
  while i < flags.len:
    var j = i
    while j < flags.len and flags[j] != ' ': inc j
    if substr(flags, i, j - 1) == f: return
    i = j + 1
  if flags.len > 0: flags.add " "
  flags.add f

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
  let outcome = autofix(opts.parserBin, src, opts.checkFlags)
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
      # diagLine renders aowlparser's own `fix` hint; when it gave none, append
      # the knowledge-base fallback hint planFix supplied so the line still helps.
      var line = diagLine(displayName, d, opts.color)
      if d.fix.len == 0 and plan.hint.len > 0:
        line.add "\n  help: " & plan.hint
      suggestions.add line
  if opts.checkMode:
    # gofmt -l / prettier --check: report, never write. Exit nonzero if unclean.
    if outcome.changed:
      write stdout, displayName & ": " & $outcome.applied.len &
        " fix(es) available (run 'fix --write' to apply)\n"
      return 1
    return 0
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
  var unclean = 0
  for i in 0 ..< files.len:
    let rc = fixOne(opts, files[i], false, files[i])
    if opts.checkMode and rc == 1: inc unclean
    if rc > worstRc: worstRc = rc
  if opts.checkMode:
    if unclean == 0 and worstRc < 2:
      write stdout, $files.len & " file(s) checked, all clean\n"
    elif unclean > 0:
      write stdout, "\n" & $unclean & " of " & $files.len &
        " file(s) have auto-fixable issues (run 'fix --write' to apply)\n"
    return worstRc   # 2 if any file errored, else 1 if any unclean, else 0
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
  var allSrcs: seq[string] = @[]   # parallel to allFiles (for SARIF fixes)
  for fi in 0 ..< files.len:
    let file = files[fi]
    var readOk = false
    let src = readSource(file, readOk)
    let res = runCheckerOnFile(opts.parserBin, file, opts.checkFlags)
    if not res.ok:
      inc runFailures
      write stderr, "aowlsuggest: " & file & ": " & res.error & "\n"
      allFiles.add file
      allDiags.add @[]
      allSrcs.add ""
      continue
    var diags = res.diags
    if readOk:
      let before = diags.len
      diags = maybeSuppress(opts, src, diags)
      totalSuppressed += (before - diags.len)
    allFiles.add file
    allDiags.add diags
    allSrcs.add (if readOk: src else: "")
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
    write stdout, sarifRun(allFiles, allDiags, aowlsuggestVersion, allSrcs) & "\n"
  else:
    for fi in 0 ..< allFiles.len:
      for i in 0 ..< allDiags[fi].len:
        if opts.quiet and allDiags[fi][i].severity != sevError: continue
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
    if opts.maxWarnings >= 0 and totalWarnings > opts.maxWarnings:
      write stdout, "exceeded --max-warnings:" & $opts.maxWarnings & " (" &
        $totalWarnings & " warnings)\n"
  # CI exit: any error, any run failure, or warnings over the --max-warnings gate
  if totalErrors > 0 or runFailures > 0: return 1
  if opts.maxWarnings >= 0 and totalWarnings > opts.maxWarnings: return 1
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
    if opts.useStdin: checkSource(opts.parserBin, src, opts.checkFlags)
    else: runCheckerOnFile(opts.parserBin, file, opts.checkFlags)
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
    write stdout, sarifRun(@[displayName], @[diags], aowlsuggestVersion, @[src]) & "\n"
  else:
    for i in 0 ..< diags.len:
      if opts.quiet and diags[i].severity != sevError: continue
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
    if opts.useStdin: checkSource(opts.parserBin, src, opts.checkFlags)
    else: runCheckerOnFile(opts.parserBin, file, opts.checkFlags)
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
          ",\"autofixable\":" & (if kb[i].autofixable: "true" else: "false") &
          ",\"guidance\":" & (if hasGuidance(kb[i].code): "true" else: "false") & "}"
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
  write stderr, "  --check          (fix) report only; exit nonzero if fixes are available (CI)\n"
  write stderr, "  --format:FMT     text (default), json, or sarif\n"
  write stderr, "  --stats          (lint) also print a per-code count summary\n"
  write stderr, "  --max-warnings:N (lint) exit non-zero if warnings exceed N\n"
  write stderr, "  --quiet          show only errors in text output (warnings still counted)\n"
  write stderr, "  --color          colorize the human-readable output\n"
  write stderr, "  --no-suppress    ignore inline '# aowlsuggest:ignore' markers\n"
  write stderr, "  --stdin          (fix/lsp/check) read source from stdin\n"
  write stderr, "  --filename:NAME  (with --stdin) the path to report\n"
  write stderr, "style (opt-in lint policies, off by default; each is auto-fixable):\n"
  write stderr, "  --pedantic       enable trailing-whitespace + final-newline + bom + float-equality\n"
  write stderr, "  --style:CAT      enable one policy; repeatable. CAT is one of:\n"
  write stderr, "                     trailing-whitespace  final-newline  bom\n"
  write stderr, "                     lf | crlf (EOL convention)  c-operators  semicolons\n"
  write stderr, "                     idioms (== true / not not)  float-equality  indent-consistency\n"
  write stderr, "  --indent-width:N advisory: warn when indent isn't a multiple of N\n"
  write stderr, "config:\n"
  write stderr, "  a project `.aowlsuggest` (found by walking up from the cwd) sets\n"
  write stderr, "  defaults: pedantic, style, indent-width, exclude, suppress, parser.\n"
  write stderr, "  --config:PATH    use a specific config file\n"
  write stderr, "  --no-config      ignore any project config\n"
  return 1

proc validIndentWidth(s: string): bool =
  if s.len == 0: return false
  for i in 0 ..< s.len:
    if s[i] < '0' or s[i] > '9': return false
  return true

proc applyConfig(opts: var Options; c: ProjectConfig) =
  ## Fold a loaded `.aowlsuggest` into `opts` BEFORE the CLI flags run, so a
  ## command-line flag always wins (scalars) or extends (lists).
  if c.pedantic:
    addFlag(opts.checkFlags, "--trailing-whitespace:warn")
    addFlag(opts.checkFlags, "--final-newline:require")
    addFlag(opts.checkFlags, "--bom:reject")
    addFlag(opts.checkFlags, "--float-equality:warn")
  for cat in c.styles:
    var ok = false
    let f = styleFlag(cat, ok)
    if ok: addFlag(opts.checkFlags, f)
    else: write stderr, "aowlsuggest: " & c.path &
      ": unknown style category: " & cat & "\n"
  if c.indentWidth.len > 0:
    if validIndentWidth(c.indentWidth):
      addFlag(opts.checkFlags, "--indent-width:" & c.indentWidth)
    else:
      write stderr, "aowlsuggest: " & c.path & ": indent-width expects a number\n"
  for g in c.excludes: opts.excludes.add g
  if c.suppressSet: opts.suppress = c.suppress
  if c.parserBin.len > 0: opts.parserBin = c.parserBin
  for w in c.warnings:
    write stderr, "aowlsuggest: " & c.path & ": " & w & "\n"

proc main(): int =
  var opts = Options(parserBin: defaultParserBin(), excludes: @[],
                     suppress: true, format: "text", stats: false,
                     doWrite: false, useStdin: false, filename: "stdin",
                     color: false, checkFlags: "", maxWarnings: -1, quiet: false,
                     checkMode: false)
  var positional: seq[string] = @[]
  let cli = commandLineParams()
  # Discover & apply the project `.aowlsuggest` FIRST (CLI flags override it).
  # Pre-scan so the effect is argument-order independent: the two config flags,
  # plus the discovery anchor — --filename (the stdin/LSP case) or the first
  # target path, so a committed config is found relative to the FILE, not just
  # the cwd. That is what lets an aowllsp editor session inherit a repo's config.
  var useConfig = true
  var configPath = ""
  var filenameArg = ""
  var firstPath = ""
  var sawCmd = false
  for ci in 0 ..< cli.len:
    let a = cli[ci]
    if a == "--no-config": useConfig = false
    elif startsWith(a, "--config:"): configPath = afterColon(a)
    elif startsWith(a, "--filename:"): filenameArg = afterColon(a)
    elif startsWith(a, "-"): discard          # any other flag
    elif not sawCmd: sawCmd = true             # the subcommand token
    elif firstPath.len == 0: firstPath = a     # the first positional path
  if useConfig:
    let anchor = anchorDirFor(firstPath, filenameArg)
    let p = if configPath.len > 0: configPath else: discoverConfigPathFrom(anchor)
    if p.len > 0:
      let c = loadConfig(p)
      if c.found: applyConfig(opts, c)
      elif configPath.len > 0:
        # an EXPLICIT --config that can't be read is a hard error, not a warning
        write stderr, "aowlsuggest: cannot read config: " & p & "\n"
        return 2
  for ci in 0 ..< cli.len:
    let a = cli[ci]
    if a == "--write": opts.doWrite = true
    elif a == "--dry-run": opts.doWrite = false
    elif a == "--check": opts.checkMode = true
    elif a == "--stdin": opts.useStdin = true
    elif a == "--stats": opts.stats = true
    elif a == "--color": opts.color = true
    elif a == "--no-suppress": opts.suppress = false
    elif a == "--quiet": opts.quiet = true
    elif startsWith(a, "--max-warnings:"):
      let n = afterColon(a)
      if not validIndentWidth(n):   # reuse: non-negative integer check
        write stderr, "aowlsuggest: --max-warnings expects a non-negative number\n"
        return 2
      var v = 0
      for k in 0 ..< n.len: v = v * 10 + (ord(n[k]) - ord('0'))
      opts.maxWarnings = v
    elif a == "--no-config": discard        # handled in the pre-scan above
    elif startsWith(a, "--config:"): discard # handled in the pre-scan above
    elif a == "--pedantic":
      # the universally-safe, auto-fixable style set + the float-equality lint
      addFlag(opts.checkFlags, "--trailing-whitespace:warn")
      addFlag(opts.checkFlags, "--final-newline:require")
      addFlag(opts.checkFlags, "--bom:reject")
      addFlag(opts.checkFlags, "--float-equality:warn")
    elif a == "--help" or a == "-h": return usage()
    elif a == "--version":
      write stdout, "aowlsuggest " & aowlsuggestVersion & "\n"; return 0
    elif startsWith(a, "--parser:"): opts.parserBin = afterColon(a)
    elif startsWith(a, "--filename:"): opts.filename = afterColon(a)
    elif startsWith(a, "--exclude:"): opts.excludes.add afterColon(a)
    elif startsWith(a, "--format:"): opts.format = afterColon(a)
    elif startsWith(a, "--style:"):
      let cat = afterColon(a)
      var ok = false
      let f = styleFlag(cat, ok)
      if not ok:
        write stderr, "aowlsuggest: unknown --style category: " & cat &
          " (trailing-whitespace, final-newline, lf, crlf, bom, c-operators, semicolons, indent-consistency)\n"
        return 2
      addFlag(opts.checkFlags, f)
    elif startsWith(a, "--indent-width:"):
      let n = afterColon(a)
      if not validIndentWidth(n):
        write stderr, "aowlsuggest: --indent-width expects a number\n"
        return 2
      addFlag(opts.checkFlags, "--indent-width:" & n)
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
    return runLspServer(opts.parserBin, opts.checkFlags)
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

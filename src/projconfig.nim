## projconfig.nim — the optional per-project `.aowlsuggest` config file.
##
## A repo can commit its lint/style defaults so `lint`, `fix`, and `lsp-server`
## all behave identically without repeating flags on every invocation — and so an
## aowllsp editor session (which drives aowlsuggest) inherits the same policy.
##
## Discovery walks UP from the working directory to the filesystem root and uses
## the first `.aowlsuggest` it finds. `--config:PATH` forces a specific file;
## `--no-config` skips discovery. The config is applied BEFORE the CLI flags, so
## a command-line flag always overrides (scalars) or extends (lists) it.
##
## Format — line-based `key = value`; `#` starts a comment (at line start or after
## whitespace); blank lines are ignored:
##
##   # .aowlsuggest
##   pedantic     = true
##   style        = trailing-whitespace, final-newline, lf
##   indent-width = 2
##   exclude      = tests/*, vendor/*
##   suppress     = false
##   parser       = /opt/aowlparser/bin/aowlparser

import std/[syncio, strutils, os, dirs]

type
  ProjectConfig* = object
    found*: bool            ## a config file was located and read
    path*: string           ## its path (for diagnostics)
    pedantic*: bool
    styles*: seq[string]    ## raw `--style` category names (validated by the CLI)
    indentWidth*: string    ## "" when unset
    excludes*: seq[string]
    suppress*: bool
    suppressSet*: bool      ## whether `suppress` was specified
    parserBin*: string      ## "" when unset
    warnings*: seq[string]  ## non-fatal parse issues (unknown keys, bad bools)

proc emptyConfig(found: bool; path: string): ProjectConfig =
  ProjectConfig(found: found, path: path, pedantic: false, styles: @[],
    indentWidth: "", excludes: @[], suppress: true, suppressSet: false,
    parserBin: "", warnings: @[])

proc indexOf(s: string; c: char; startAt = 0): int =
  var i = startAt
  while i < s.len:
    if s[i] == c: return i
    inc i
  return -1

proc parentDirStr(p: string): string =
  ## The parent directory of `p` (expected absolute), or "" past the root.
  var i = p.len - 1
  while i >= 0 and p[i] == '/': dec i          # drop trailing slashes
  while i >= 0 and p[i] != '/': dec i          # skip the last component
  if i < 0: return ""
  if i == 0: return "/"                          # "/x" -> "/"
  result = substr(p, 0, i - 1)

proc dirNameOf(p: string): string =
  ## Directory portion of a file path ("/a/b/f.nim" -> "/a/b"; "f.nim" -> "").
  var i = p.len - 1
  while i >= 0 and p[i] != '/': dec i
  if i < 0: return ""
  if i == 0: return "/"
  result = substr(p, 0, i - 1)

proc anchorDirFor*(pathArg, filenameArg: string): string =
  ## The directory to anchor config discovery at. `--filename` wins (the stdin /
  ## LSP case, where the buffer's intended path — not the cwd — identifies the
  ## project); otherwise the target path's directory, or the path itself when it
  ## is a directory; otherwise "" (→ the cwd).
  if filenameArg.len > 0: return dirNameOf(filenameArg)
  if pathArg.len > 0:
    if dirExists(pathArg): return pathArg
    return dirNameOf(pathArg)
  return ""

proc findConfigPath*(startDir: string): string =
  ## First `.aowlsuggest` at or above `startDir`, or "" if none.
  var dir = startDir
  while dir.len > 0:
    let cand = dir & "/.aowlsuggest"
    if fileExists(cand): return cand
    let up = parentDirStr(dir)
    if up.len == 0 or up == dir: break
    dir = up
  return ""

proc stripComment(line: string): string =
  ## Remove a `#` comment. `#` only starts a comment at the line's start or when
  ## preceded by whitespace, so a `#` inside a value (e.g. a glob) survives.
  var i = 0
  while i < line.len:
    if line[i] == '#' and (i == 0 or line[i-1] == ' ' or line[i-1] == '\t'):
      return substr(line, 0, i - 1)
    inc i
  return line

proc parseBoolVal(v: string; ok: var bool): bool =
  ok = true
  case toLowerAscii(strip(v))
  of "true", "yes", "on", "1": true
  of "false", "no", "off", "0": false
  else:
    ok = false
    false

proc splitCsv(v: string): seq[string] =
  result = @[]
  for part in split(v, ','):
    let s = strip(part)
    if s.len > 0: result.add s

proc parseConfigText*(text: string): ProjectConfig =
  ## Parse `.aowlsuggest` content. Unknown keys / malformed values are collected
  ## as `warnings` (never fatal) so a typo degrades gracefully.
  result = emptyConfig(true, "")
  for rawLine in splitLines(text):
    let line = strip(stripComment(rawLine))
    if line.len == 0: continue
    let eq = indexOf(line, '=')
    if eq < 0:
      result.warnings.add "ignored line (no '='): " & rawLine
      continue
    let key = strip(substr(line, 0, eq - 1))
    let val = strip(substr(line, eq + 1, line.len - 1))
    case toLowerAscii(key)
    of "pedantic":
      var ok = false
      let b = parseBoolVal(val, ok)
      if ok: result.pedantic = b
      else: result.warnings.add "bad bool for 'pedantic': " & val
    of "style", "styles":
      for c in splitCsv(val): result.styles.add c
    of "indent-width", "indentwidth":
      result.indentWidth = val
    of "exclude", "excludes":
      for g in splitCsv(val): result.excludes.add g
    of "suppress":
      var ok = false
      let b = parseBoolVal(val, ok)
      if ok:
        result.suppress = b
        result.suppressSet = true
      else: result.warnings.add "bad bool for 'suppress': " & val
    of "parser", "parser-bin":
      result.parserBin = val
    else:
      result.warnings.add "unknown key: " & key

proc loadConfig*(path: string): ProjectConfig =
  ## Read and parse `path`. `found = false` if it can't be read.
  var text = ""
  try:
    text = readFile(path)
  except:
    return emptyConfig(false, path)
  result = parseConfigText(text)
  result.path = path

proc discoverConfigPathFrom*(anchor: string): string =
  ## The `.aowlsuggest` found by walking up from `anchor` (a directory), made
  ## absolute against the cwd when it isn't already; falls back to the cwd when
  ## `anchor` is empty. "" if none / the cwd is unavailable.
  var cwd = ""
  try:
    cwd = $dirs.getCurrentDir()
  except:
    cwd = ""
  var start = anchor
  if start.len == 0:
    start = cwd
  elif start[0] != '/' and cwd.len > 0:
    start = cwd & "/" & start
  if start.len == 0: return ""
  result = findConfigPath(start)

proc discoverConfigPath*(): string =
  ## Discovery anchored at the current working directory.
  result = discoverConfigPathFrom("")

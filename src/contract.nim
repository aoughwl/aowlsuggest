## contract.nim — the seam between aowlsuggest and aowlparser.
##
## aowlsuggest NEVER lexes or parses Nim itself. Every diagnostic it works with
## is produced INSIDE aowlparser's recovering parse and handed over across this
## one boundary: `aowlparser check --diagnostics:json <file>`. This module runs
## that subprocess, reads its structured JSON, and models the result as a typed
## `seq[Diagnostic]`. If a suggestion ever needs data this JSON doesn't carry,
## the fix is to extend aowlparser's diagnostic schema — not to re-derive it here.
##
## The JSON schema (per element, aowlparser owns it):
##   { "severity", "code", "message", "line", "col", "endCol",
##     "fix"?, "related"? { "message", "line", "col" } }
## Coordinates match a nifler token: `line` is 1-based, `col`/`endCol` are 0-based
## (endCol is exclusive, one past the span's last char on `line`).
##
## We read the JSON DEFENSIVELY: unknown extra fields are ignored (the schema may
## grow), and only the genuinely-required fields (code, line, col) being absent
## is treated as a hard error.

import std/[json, osproc, syncio, envvars, appdirs, paths, dirs, strutils, monotimes]

type
  Severity* = enum
    ## Mirrors aowlparser's `tokens.Severity`. Only `sevError` blocks (non-zero
    ## exit); `sevWarn`/`sevHint` are advisory.
    sevHint
    sevWarn
    sevError

  Diagnostic* = object
    ## One recoverable diagnostic, decoded from aowlparser's JSON. `line` is
    ## 1-based; `col`/`endCol` are 0-based (endCol exclusive). `fix` is the
    ## human-readable repair hint aowlparser attached (may be empty). When
    ## `hasRelated`, `rel*` carry a secondary source location (e.g. the `(` an
    ## unclosed bracket was opened at).
    severity*: Severity
    code*: string
    message*: string
    line*: int
    col*: int
    endCol*: int
    fix*: string
    hasRelated*: bool
    relMsg*: string
    relLine*: int
    relCol*: int

  CheckResult* = object
    ## The outcome of one checker run. `ok` is false only when the checker could
    ## not be run or its output could not be decoded (`error` says why); a file
    ## with diagnostics is still `ok`. `errorCount` counts `sevError` diagnostics
    ## — the CI-relevant number. `ranExit` is aowlparser's process exit code.
    diags*: seq[Diagnostic]
    ok*: bool
    error*: string
    errorCount*: int
    ranExit*: int

proc defaultParserBin*(): string =
  ## Path to the aowlparser binary. Overridable with $AOWLPARSER so the contract
  ## boundary is never hard-wired to one checkout.
  result = ""
  try:
    result = getEnv("AOWLPARSER")
  except:
    result = ""
  if result.len == 0:
    result = "/home/savant/aifparser/bin/aowlparser"

var gTmpCounter = 0

proc tempFile(tag, ext: string): string =
  ## A per-process-unique temp path. Combines the temp dir, a monotonic tick, and
  ## an incrementing counter so repeated calls within one run never collide.
  inc gTmpCounter
  var ticks = 0'i64
  try:
    ticks = getMonoTime().ticks
  except:
    ticks = 0
  var td = "/tmp"
  try:
    td = $getTempDir()
  except:
    td = "/tmp"
  if td.len > 0 and td[td.len - 1] == '/':
    td = substr(td, 0, td.len - 2)
  result = td & "/aowlsuggest_" & tag & "_" & $ticks & "_" & $gTmpCounter & ext

proc shellQuote(s: string): string =
  ## Single-quote a path for safe inclusion in a `sh -c` command line.
  result = "'"
  for i in 0 ..< s.len:
    if s[i] == '\'':
      result.add "'\\''"
    else:
      result.add s[i]
  result.add "'"

proc severityFromStr(s: string): Severity =
  case s
  of "error": sevError
  of "warning": sevWarn
  of "hint": sevHint
  else: sevError

proc parseRelated(n: JsonNode; d: var Diagnostic) =
  for k, v in pairs(n):
    case k
    of "message": d.relMsg = v.getStr
    of "line": d.relLine = int(v.getInt)
    of "col": d.relCol = int(v.getInt)
    else: discard
  d.hasRelated = true

proc parseOne(el: JsonNode; d: var Diagnostic; err: var string) =
  ## Decode one diagnostic object. Values are pulled out DURING iteration: the
  ## JSON node handles are lazy cursors that go stale once the enclosing iterator
  ## advances, so nothing is stored for later.
  d = Diagnostic(severity: sevError, code: "", message: "", line: 0, col: 0,
                 endCol: 0, fix: "", hasRelated: false, relMsg: "",
                 relLine: 0, relCol: 0)
  var sawCode = false
  var sawLine = false
  var sawCol = false
  for k, v in pairs(el):
    case k
    of "severity": d.severity = severityFromStr(v.getStr)
    of "code":
      d.code = v.getStr; sawCode = true
    of "message": d.message = v.getStr
    of "line":
      d.line = int(v.getInt); sawLine = true
    of "col":
      d.col = int(v.getInt); sawCol = true
    of "endCol": d.endCol = int(v.getInt)
    of "fix": d.fix = v.getStr
    of "related": parseRelated(v, d)
    else: discard   # tolerate unknown/future fields
  if not (sawCode and sawLine and sawCol):
    err = "diagnostic missing a required field (code/line/col)"

proc parseDiagnostics*(jsonText: string; err: var string): seq[Diagnostic] =
  ## Decode aowlparser's `--diagnostics:json` array. An empty/`[]` document is a
  ## clean file. `err` is set (and the partial result returned) if the document
  ## is not a JSON array or an element is missing a required field.
  result = @[]
  err = ""
  let trimmed = strip(jsonText)
  if trimmed.len == 0:
    return
  var tree = default(JsonTree)
  try:
    tree = parseJson(jsonText)
  except:
    err = "aowlparser produced output that is not valid JSON"
    return
  var arr = tree.root
  if arr.kind != JArray:
    err = "aowlparser JSON root is not an array"
    return
  for el in items(arr):
    if el.kind != JObject:
      err = "aowlparser JSON array element is not an object"
      return
    var d = default(Diagnostic)
    var e1 = ""
    parseOne(el, d, e1)
    if e1.len > 0:
      err = e1
      return
    result.add d

proc parseCheckOutput*(jsonText: string; exitCode: int): CheckResult =
  ## Turn a raw checker run (its JSON stdout + exit code) into a CheckResult.
  ## Exposed so callers that capture the checker themselves (or replay fixtures)
  ## share the exact decoding path.
  result = CheckResult(diags: @[], ok: true, error: "", errorCount: 0,
                       ranExit: exitCode)
  var err = ""
  result.diags = parseDiagnostics(jsonText, err)
  if err.len > 0:
    result.ok = false
    result.error = err
    return
  var n = 0
  for i in 0 ..< result.diags.len:
    if result.diags[i].severity == sevError: inc n
  result.errorCount = n

proc runCheckerOnFile*(parserBin, file: string): CheckResult =
  ## Run `parserBin check --diagnostics:json <file>`, capturing its JSON via a
  ## temp file (aowlparser emits the whole array on ONE line, and nimony's
  ## execCmdEx line-capture mangles lines longer than its buffer — a file
  ## redirect reads the output whole and is immune). Never raises.
  let outPath = tempFile("out", ".json")
  # execCmd evaluates the string through `sh -c`, so a plain shell redirect sends
  # the checker's JSON straight to our temp file.
  let cmd = shellQuote(parserBin) & " check --diagnostics:json " &
    shellQuote(file) & " > " & shellQuote(outPath) & " 2>/dev/null"
  var code = -1
  try:
    code = execCmd(cmd)
  except:
    return CheckResult(diags: @[], ok: false,
      error: "could not run aowlparser (" & parserBin & ")",
      errorCount: 0, ranExit: -1)
  var outp = ""
  try:
    outp = readFile(outPath)
  except:
    return CheckResult(diags: @[], ok: false,
      error: "could not read aowlparser output", errorCount: 0, ranExit: code)
  try:
    removeFile(path(outPath))
  except:
    discard
  result = parseCheckOutput(outp, code)

proc checkSource*(parserBin, src: string): CheckResult =
  ## Check an in-memory source string by materialising it to a temp `.nim` file
  ## and running the checker over it. This is how the fix engine verifies a
  ## candidate edit without touching the user's file.
  let srcPath = tempFile("cand", ".nim")
  try:
    writeFile(srcPath, src)
  except:
    return CheckResult(diags: @[], ok: false,
      error: "could not write candidate source", errorCount: 0, ranExit: -1)
  result = runCheckerOnFile(parserBin, srcPath)
  try:
    removeFile(path(srcPath))
  except:
    discard

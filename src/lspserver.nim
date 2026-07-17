## lspserver.nim — a minimal but real Language Server over stdio. It speaks
## JSON-RPC 2.0 with LSP's `Content-Length` framing, keeps a document store, and
## publishes diagnostics (and offers quick-fix code actions) sourced entirely
## from aowlparser via the contract layer.
##
## Supported: initialize / initialized / shutdown / exit,
## textDocument/{didOpen,didChange,didSave,didClose}, textDocument/codeAction.
## Text sync is FULL (capability 1): each change carries the whole buffer.

import std/[syncio, json]
import contract, lsp

const serverVersion = "0.2.0"

# ── document store ───────────────────────────────────────────────────────────

type
  Doc = object
    uri: string
    text: string
  Server = object
    parserBin: string
    docs: seq[Doc]

proc setDoc(s: var Server; uri, text: string) =
  for i in 0 ..< s.docs.len:
    if s.docs[i].uri == uri:
      s.docs[i].text = text
      return
  s.docs.add Doc(uri: uri, text: text)

proc getDoc(s: Server; uri: string; text: var string): bool =
  for i in 0 ..< s.docs.len:
    if s.docs[i].uri == uri:
      text = s.docs[i].text
      return true
  return false

proc delDoc(s: var Server; uri: string) =
  var kept: seq[Doc] = @[]
  for i in 0 ..< s.docs.len:
    if s.docs[i].uri != uri: kept.add s.docs[i]
  s.docs = kept

# ── framing ──────────────────────────────────────────────────────────────────

proc parseIntSafe(s: string): int =
  var v = 0
  var any = false
  for i in 0 ..< s.len:
    let c = s[i]
    if c >= '0' and c <= '9':
      v = v * 10 + (ord(c) - ord('0')); any = true
    elif c == ' ' or c == '\t':
      discard
  if any: v else: -1

proc hasPrefixCI(s, pre: string): bool =
  if s.len < pre.len: return false
  for i in 0 ..< pre.len:
    var a = s[i]
    var b = pre[i]
    if a >= 'A' and a <= 'Z': a = chr(ord(a) + 32)
    if b >= 'A' and b <= 'Z': b = chr(ord(b) + 32)
    if a != b: return false
  return true

proc readMessage(body: var string): bool =
  ## Read one framed message. Returns false at EOF. `body` is the JSON payload.
  var contentLength = -1
  var line = ""
  while true:
    var ok = false
    try:
      ok = readLine(stdin, line)
    except:
      return false
    if not ok: return false
    if line.len > 0 and line[line.len - 1] == '\r':
      line = substr(line, 0, line.len - 2)
    if line.len == 0: break   # blank line terminates the headers
    if hasPrefixCI(line, "content-length:"):
      contentLength = parseIntSafe(substr(line, 15, line.len - 1))
  if contentLength <= 0:
    body = ""
    return true
  body = ""
  var remaining = contentLength
  var buf = default(array[4096, char])
  while remaining > 0:
    var want = remaining
    if want > 4096: want = 4096
    var r = 0
    try:
      r = readBuffer(stdin, addr buf[0], want)
    except:
      break
    if r <= 0: break
    for i in 0 ..< r: body.add buf[i]
    remaining = remaining - r
  return true

proc send(payload: string) =
  ## Frame and write a JSON-RPC message to stdout.
  try:
    write stdout, "Content-Length: " & $payload.len & "\r\n\r\n"
    write stdout, payload
    flushFile(stdout)
  except:
    discard

# ── message parsing (immediate extraction; cursors are lazy) ─────────────────

proc parseHeader(root: JsonNode; meth: var string; hasId: var bool;
                 idJson: var string) =
  for k, v in pairs(root):
    case k
    of "method": meth = v.getStr
    of "id":
      hasId = true
      if v.kind == JString: idJson = "\"" & v.getStr & "\""
      else: idJson = $v.getInt
    else: discard

proc parseDidOpen(root: JsonNode; uri, text: var string) =
  for k, v in pairs(root):
    if k == "params":
      for k2, v2 in pairs(v):
        if k2 == "textDocument":
          for k3, v3 in pairs(v2):
            case k3
            of "uri": uri = v3.getStr
            of "text": text = v3.getStr
            else: discard

proc parseDidChange(root: JsonNode; uri, text: var string) =
  for k, v in pairs(root):
    if k == "params":
      for k2, v2 in pairs(v):
        if k2 == "textDocument":
          for k3, v3 in pairs(v2):
            if k3 == "uri": uri = v3.getStr
        elif k2 == "contentChanges":
          for el in items(v2):
            for k3, v3 in pairs(el):
              if k3 == "text": text = v3.getStr   # FULL sync: whole buffer

proc parseUriOnly(root: JsonNode; uri: var string) =
  for k, v in pairs(root):
    if k == "params":
      for k2, v2 in pairs(v):
        if k2 == "textDocument":
          for k3, v3 in pairs(v2):
            if k3 == "uri": uri = v3.getStr

proc parseCodeAction(root: JsonNode; uri: var string; loLine, hiLine: var int) =
  for k, v in pairs(root):
    if k == "params":
      for k2, v2 in pairs(v):
        if k2 == "textDocument":
          for k3, v3 in pairs(v2):
            if k3 == "uri": uri = v3.getStr
        elif k2 == "range":
          for k3, v3 in pairs(v2):
            if k3 == "start":
              for k4, v4 in pairs(v3):
                if k4 == "line": loLine = int(v4.getInt)
            elif k3 == "end":
              for k4, v4 in pairs(v3):
                if k4 == "line": hiLine = int(v4.getInt)

# ── behaviour ────────────────────────────────────────────────────────────────

proc publishDiagnostics(s: Server; uri, text: string) =
  let res = checkSource(s.parserBin, text)
  # On a checker failure, publish an empty list rather than stale diagnostics.
  let arr =
    if res.ok: diagnosticsArrayForUri(uri, text, res.diags)
    else: "[]"
  send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\"," &
    "\"params\":{\"uri\":\"" & uri & "\",\"diagnostics\":" & arr & "}}")

proc handle(s: var Server; body: string; shouldExit: var bool) =
  if body.len == 0: return
  var tree = default(JsonTree)
  try:
    tree = parseJson(body)
  except:
    return
  var meth = ""
  var hasId = false
  var idJson = "null"
  parseHeader(tree.root, meth, hasId, idJson)
  case meth
  of "initialize":
    send("{\"jsonrpc\":\"2.0\",\"id\":" & idJson & ",\"result\":{" &
      "\"capabilities\":{\"textDocumentSync\":1,\"codeActionProvider\":true}," &
      "\"serverInfo\":{\"name\":\"aowlsuggest\",\"version\":\"" & serverVersion &
      "\"}}}")
  of "initialized":
    discard
  of "shutdown":
    send("{\"jsonrpc\":\"2.0\",\"id\":" & idJson & ",\"result\":null}")
  of "exit":
    shouldExit = true
  of "textDocument/didOpen":
    var uri = ""
    var text = ""
    parseDidOpen(tree.root, uri, text)
    if uri.len > 0:
      setDoc(s, uri, text)
      publishDiagnostics(s, uri, text)
  of "textDocument/didChange":
    var uri = ""
    var text = ""
    parseDidChange(tree.root, uri, text)
    if uri.len > 0:
      setDoc(s, uri, text)
      publishDiagnostics(s, uri, text)
  of "textDocument/didSave":
    var uri = ""
    parseUriOnly(tree.root, uri)
    var text = ""
    if uri.len > 0 and getDoc(s, uri, text):
      publishDiagnostics(s, uri, text)
  of "textDocument/didClose":
    var uri = ""
    parseUriOnly(tree.root, uri)
    if uri.len > 0:
      delDoc(s, uri)
      # clear diagnostics for the closed document
      send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\"," &
        "\"params\":{\"uri\":\"" & uri & "\",\"diagnostics\":[]}}")
  of "textDocument/codeAction":
    var uri = ""
    var loLine = 0
    var hiLine = 1000000000
    parseCodeAction(tree.root, uri, loLine, hiLine)
    var text = ""
    var actions = "[]"
    if uri.len > 0 and getDoc(s, uri, text):
      let res = checkSource(s.parserBin, text)
      if res.ok:
        actions = codeActionsForUri(uri, text, res.diags, true, loLine, hiLine)
    if hasId:
      send("{\"jsonrpc\":\"2.0\",\"id\":" & idJson & ",\"result\":" & actions & "}")
  else:
    # Unknown request: respond with a null result so the client isn't left
    # hanging; notifications (no id) are simply ignored.
    if hasId:
      send("{\"jsonrpc\":\"2.0\",\"id\":" & idJson & ",\"result\":null}")

proc runLspServer*(parserBin: string): int =
  ## Blocking stdio LSP loop. Returns the process exit code (0 on clean `exit`).
  var s = Server(parserBin: parserBin, docs: @[])
  var body = ""
  var shouldExit = false
  while true:
    if not readMessage(body): break   # EOF
    handle(s, body, shouldExit)
    if shouldExit: break
  return 0

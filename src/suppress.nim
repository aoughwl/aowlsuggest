## suppress.nim — honour inline suppression comments so a project can silence a
## diagnostic it has accepted. This scans SOURCE LINES for a marker; it does not
## parse Nim (the marker is found by substring, requiring a preceding '#').
##
## Markers (in a `#` comment):
##   # aowlsuggest:ignore                  suppress every diagnostic on this line
##   # aowlsuggest:ignore[code,code]       suppress only these codes on this line
##   # aowlsuggest:ignore-next             suppress everything on the NEXT line
##   # aowlsuggest:ignore-next[code,code]  suppress these codes on the next line

import std/strutils
import contract

type
  SuppressSpec = object
    active: bool
    isNext: bool        ## targets the following line, not this one
    allCodes: bool      ## no [..] list ⇒ suppress every code
    codes: seq[string]

proc parseLine(lineText: string): SuppressSpec =
  result = SuppressSpec(active: false, isNext: false, allCodes: true, codes: @[])
  let marker = "aowlsuggest:ignore"
  let idx = find(lineText, marker)
  if idx < 0: return
  # require the marker to sit inside a comment (a '#' somewhere before it)
  if find(substr(lineText, 0, idx - 1), "#") < 0: return
  result.active = true
  var p = idx + marker.len
  if p + 5 <= lineText.len and substr(lineText, p, p + 4) == "-next":
    result.isNext = true
    p = p + 5
  if p < lineText.len and lineText[p] == '[':
    result.allCodes = false
    var q = p + 1
    var cur = ""
    while q < lineText.len and lineText[q] != ']':
      if lineText[q] == ',':
        if cur.len > 0: result.codes.add strip(cur)
        cur = ""
      else:
        cur.add lineText[q]
      inc q
    if cur.len > 0: result.codes.add strip(cur)

proc specSuppresses(spec: SuppressSpec; code: string): bool =
  if not spec.active: return false
  if spec.allCodes: return true
  for i in 0 ..< spec.codes.len:
    if spec.codes[i] == code: return true
  return false

proc filterSuppressed*(src: string; diags: seq[Diagnostic]):
    tuple[kept: seq[Diagnostic]; suppressed: int] =
  ## Drop diagnostics silenced by an inline marker on their own line or an
  ## `ignore-next` marker on the line above.
  let lines = splitLines(src)
  var kept: seq[Diagnostic] = @[]
  var n = 0
  for i in 0 ..< diags.len:
    let d = diags[i]
    var drop = false
    if d.line - 1 >= 0 and d.line - 1 < lines.len:
      let own = parseLine(lines[d.line - 1])
      if not own.isNext and specSuppresses(own, d.code):
        drop = true
    if not drop and d.line - 2 >= 0 and d.line - 2 < lines.len:
      let prev = parseLine(lines[d.line - 2])
      if prev.isNext and specSuppresses(prev, d.code):
        drop = true
    if drop: inc n
    else: kept.add d
  result = (kept, n)

## textedit.nim — a tiny source-text model: byte-offset edits, line/col mapping,
## and a unified diff. Nothing here understands Nim; it only splices text at
## positions the contract layer hands us (all from aowlparser).

import std/strutils

type
  TextEdit* = object
    ## Replace the half-open byte range `[startOff, endOff)` of a source string
    ## with `replacement`. A pure insertion has `startOff == endOff`. `label`
    ## is a human tag ("insert ':'") for diffs and code actions.
    startOff*: int
    endOff*: int
    replacement*: string
    label*: string

proc lineStarts*(src: string): seq[int] =
  ## Byte offset at which each 1-based source line begins. `result[0]` is the
  ## start of line 1 (always 0). A trailing line after a final '\n' is included
  ## so `line == result.len` maps to end-of-file.
  result = @[0]
  for i in 0 ..< src.len:
    if src[i] == '\n':
      result.add i + 1

proc lineColToOffset*(src: string; starts: seq[int]; line, col: int): int =
  ## Map a 1-based line / 0-based column to a byte offset, clamped into range.
  if line < 1: return 0
  if line - 1 >= starts.len: return src.len
  var off = starts[line - 1] + col
  if off < 0: off = 0
  if off > src.len: off = src.len
  result = off

proc lineEndOffset*(src: string; starts: seq[int]; line: int): int =
  ## Byte offset of the '\n' terminating `line` (or `src.len` for the last,
  ## unterminated line). This is the position just past the line's content,
  ## before its newline.
  if line < 1 or line - 1 >= starts.len: return src.len
  var i = starts[line - 1]
  while i < src.len and src[i] != '\n':
    inc i
  result = i

proc lineContentEndOffset*(src: string; starts: seq[int]; line: int): int =
  ## Like `lineEndOffset`, but backed up past any trailing spaces / tabs / CR so
  ## an "append to the line" insertion lands right after the last real character.
  var e = lineEndOffset(src, starts, line)
  while e > 0 and (src[e-1] == ' ' or src[e-1] == '\t' or src[e-1] == '\r'):
    dec e
  result = e

proc applyEdit*(src: string; e: TextEdit): string =
  ## Apply one edit, returning the new string. Out-of-range offsets are clamped.
  var a = e.startOff
  var b = e.endOff
  if a < 0: a = 0
  if b > src.len: b = src.len
  if b < a: b = a
  result = substr(src, 0, a - 1) & e.replacement & substr(src, b, src.len - 1)

proc applyEdits*(src: string; edits: seq[TextEdit]): string =
  ## Apply several NON-OVERLAPPING edits in a single left-to-right pass over the
  ## source, so no splice shifts another's offsets.
  # insertion sort an index permutation (moving ints, not the string-bearing
  # edits themselves) by startOff ascending — edit counts are tiny.
  var idx: seq[int] = @[]
  for i in 0 ..< edits.len: idx.add i
  for i in 1 ..< idx.len:
    let cur = idx[i]
    var j = i - 1
    while j >= 0 and edits[idx[j]].startOff > edits[cur].startOff:
      let moved = idx[j]
      idx[j + 1] = moved
      dec j
    idx[j + 1] = cur
  result = ""
  var pos = 0
  for k in 0 ..< idx.len:
    let e = edits[idx[k]]
    var a = e.startOff
    if a < pos: a = pos   # clamp overlap defensively
    result.add substr(src, pos, a - 1)
    result.add e.replacement
    pos = e.endOff
    if pos < a: pos = a
  result.add substr(src, pos, src.len - 1)

# ── Unified diff ─────────────────────────────────────────────────────────────

type
  DiffOpKind = enum doEqual, doDel, doAdd
  DiffOp = object
    kind: DiffOpKind
    text: string

proc lcsOps(a, b: seq[string]): seq[DiffOp] =
  ## Longest-common-subsequence edit script over lines. O(m*n) DP — fine for the
  ## single-file diffs `fix --dry-run` produces.
  let m = a.len
  let n = b.len
  # dp[i][j] = LCS length of a[i..] and b[j..]
  var dp: seq[seq[int]] = @[]
  for i in 0 .. m:
    var row: seq[int] = @[]
    for j in 0 .. n:
      row.add 0
    dp.add row
  for i in countdown(m - 1, 0):
    for j in countdown(n - 1, 0):
      if a[i] == b[j]:
        dp[i][j] = dp[i+1][j+1] + 1
      elif dp[i+1][j] >= dp[i][j+1]:
        dp[i][j] = dp[i+1][j]
      else:
        dp[i][j] = dp[i][j+1]
  result = @[]
  var i = 0
  var j = 0
  while i < m and j < n:
    if a[i] == b[j]:
      result.add DiffOp(kind: doEqual, text: a[i]); inc i; inc j
    elif dp[i+1][j] >= dp[i][j+1]:
      result.add DiffOp(kind: doDel, text: a[i]); inc i
    else:
      result.add DiffOp(kind: doAdd, text: b[j]); inc j
  while i < m:
    result.add DiffOp(kind: doDel, text: a[i]); inc i
  while j < n:
    result.add DiffOp(kind: doAdd, text: b[j]); inc j

proc unifiedDiff*(aName, bName, a, b: string; context = 3): string =
  ## A git-style unified diff between `a` and `b`. Returns "" when identical.
  if a == b: return ""
  let al = splitLines(a)
  let bl = splitLines(b)
  let ops = lcsOps(al, bl)
  # Mark which ops are "changes" (non-equal); build hunks of changes plus
  # `context` equal lines of padding, merging hunks that overlap.
  var isChange: seq[bool] = @[]
  for i in 0 ..< ops.len:
    isChange.add (ops[i].kind != doEqual)
  # find hunk spans over the op list
  result = "--- " & aName & "\n+++ " & bName & "\n"
  var idx = 0
  var aLine = 1   # 1-based line number in a
  var bLine = 1
  # Precompute, per op, the a/b line numbers it consumes.
  var aNums: seq[int] = @[]
  var bNums: seq[int] = @[]
  var ca = 1
  var cb = 1
  for i in 0 ..< ops.len:
    aNums.add ca
    bNums.add cb
    case ops[i].kind
    of doEqual: inc ca; inc cb
    of doDel: inc ca
    of doAdd: inc cb
  while idx < ops.len:
    if not isChange[idx]:
      inc idx
      continue
    # start of a change run; extend the hunk with leading/trailing context and
    # merge subsequent change runs separated by <= 2*context equal lines.
    var hunkStart = idx
    # back up context lines
    var s = hunkStart
    var back = 0
    while s > 0 and back < context:
      dec s; inc back
    var e = idx
    while true:
      # advance e over this change run
      while e < ops.len and isChange[e]: inc e
      # look ahead: if another change within 2*context equal lines, absorb it
      var look = e
      var gap = 0
      while look < ops.len and not isChange[look] and gap < context * 2:
        inc look; inc gap
      if look < ops.len and isChange[look] and gap < context * 2:
        e = look
      else:
        break
    # trailing context
    var te = e
    var fwd = 0
    while te < ops.len and not isChange[te] and fwd < context:
      inc te; inc fwd
    # emit hunk header
    var aCount = 0
    var bCount = 0
    for k in s ..< te:
      case ops[k].kind
      of doEqual: inc aCount; inc bCount
      of doDel: inc aCount
      of doAdd: inc bCount
    let aStart = if te > s: aNums[s] else: aLine
    let bStart = if te > s: bNums[s] else: bLine
    result.add "@@ -" & $aStart & "," & $aCount & " +" & $bStart & "," &
      $bCount & " @@\n"
    for k in s ..< te:
      case ops[k].kind
      of doEqual: result.add " " & ops[k].text & "\n"
      of doDel: result.add "-" & ops[k].text & "\n"
      of doAdd: result.add "+" & ops[k].text & "\n"
    idx = te

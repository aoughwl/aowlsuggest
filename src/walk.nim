## walk.nim — expand a mix of file and directory arguments into a concrete list
## of `.nim` files, honouring `--exclude` glob patterns. Purely filesystem work;
## it never opens or interprets a file's contents.

import std/[os, dirs, paths, strutils]

proc globMatch*(pat, s: string): bool =
  ## Match `s` against a glob `pat` supporting `*` (any run, incl. empty) and `?`
  ## (one char). Everything else is literal. Iterative with `*` backtracking.
  var pi = 0
  var si = 0
  var star = -1
  var mark = 0
  while si < s.len:
    if pi < pat.len and (pat[pi] == '?' or pat[pi] == s[si]):
      inc pi; inc si
    elif pi < pat.len and pat[pi] == '*':
      star = pi; mark = si; inc pi
    elif star != -1:
      pi = star + 1; inc mark; si = mark
    else:
      return false
  while pi < pat.len and pat[pi] == '*': inc pi
  result = pi == pat.len

proc baseName(path: string): string =
  var i = path.len - 1
  while i >= 0 and path[i] != '/':
    dec i
  result = substr(path, i + 1, path.len - 1)

proc isExcluded*(path: string; excludes: seq[string]): bool =
  ## A path is excluded if any pattern matches its full text OR its base name.
  let bn = baseName(path)
  for i in 0 ..< excludes.len:
    if globMatch(excludes[i], path) or globMatch(excludes[i], bn):
      return true
  return false

proc walkInto(dir: string; excludes: seq[string]; acc: var seq[string]) =
  ## Recurse a directory, collecting non-excluded `.nim` files. Excluded
  ## directories are pruned (not descended). Symlinks are not followed.
  if isExcluded(dir, excludes): return
  var entries: seq[(bool, string)] = @[]   # (isDir, path)
  try:
    for kind, p in walkDir(path(dir)):
      let ps = $p
      if kind == pcDir:
        entries.add (true, ps)
      elif kind == pcFile:
        entries.add (false, ps)
  except:
    return   # unreadable directory: skip quietly
  for i in 0 ..< entries.len:
    let (isDir, ps) = entries[i]
    if isDir:
      walkInto(ps, excludes, acc)
    else:
      if endsWith(ps, ".nim") and not isExcluded(ps, excludes):
        acc.add ps

proc collectFiles*(paths: seq[string]; excludes: seq[string]): seq[string] =
  ## Expand `paths` (files and/or directories) into a sorted, de-duplicated list
  ## of `.nim` files. An explicit file argument is included even if it is
  ## excluded (the user named it directly); directory contents honour excludes.
  var acc: seq[string] = @[]
  for i in 0 ..< paths.len:
    let p = paths[i]
    if dirExists(p):
      walkInto(p, excludes, acc)
    elif fileExists(p):
      acc.add p
    else:
      # not on disk — keep it so the caller can report a clear "cannot read".
      acc.add p
  # insertion sort ascending (paths lists are small; avoids a self-aliasing
  # element swap the borrow checker rejects by copying through a temp binding).
  for i in 1 ..< acc.len:
    let cur = acc[i]
    var j = i - 1
    while j >= 0 and acc[j] > cur:
      let moved = acc[j]
      acc[j + 1] = moved
      dec j
    acc[j + 1] = cur
  # de-duplicate the sorted list
  result = @[]
  for i in 0 ..< acc.len:
    if i == 0 or acc[i] != acc[i-1]:
      result.add acc[i]

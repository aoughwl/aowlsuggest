## jsonout.nim — minimal JSON string building. We emit JSON by hand (as
## aowlparser does) so the exact shape is under our control; escaping matches
## the JSON spec.

proc jsonEscape*(s: string): string =
  result = ""
  for i in 0 ..< s.len:
    let c = s[i]
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\t': result.add "\\t"
    of '\r': result.add "\\r"
    else:
      if c < ' ':
        const hexd = "0123456789ABCDEF"
        result.add "\\u00"
        result.add hexd[(ord(c) shr 4) and 0xF]
        result.add hexd[ord(c) and 0xF]
      else:
        result.add c

proc jStr*(s: string): string =
  ## A quoted, escaped JSON string literal.
  "\"" & jsonEscape(s) & "\""

## explain.nim — a curated knowledge base for aowlparser's diagnostic codes:
## what each one means, a minimal bad/good example, and whether aowlsuggest can
## repair it automatically.
##
## This is DERIVED from aowlparser's diagnostic set (its src/ and tests/diag.sh)
## and must be kept in sync with it — it is documentation, never a second source
## of truth. `knownCode` lets callers tell a code we describe from one we don't,
## so an unknown (newly added) code degrades gracefully instead of masquerading
## as described.

type
  CodeInfo* = object
    code*: string
    title*: string
    explanation*: string
    badExample*: string
    goodExample*: string
    autofixable*: bool

proc knowledgeBase*(): seq[CodeInfo] =
  result = @[
    CodeInfo(code: "assignment-in-condition",
      title: "Assignment '=' where a comparison was meant",
      explanation: "A bare '=' at the top level of an if/elif/while/when " &
        "condition assigns rather than compares — almost always a typo for '=='.",
      badExample: "if x = 5:", goodExample: "if x == 5:", autofixable: true),
    CodeInfo(code: "mismatched-bracket",
      title: "Closing bracket does not match its opener",
      explanation: "A ')' / ']' / '}' closes a different kind of bracket than " &
        "the one that opened. The opener is reported as a related location.",
      badExample: "let a = (1 + 2]", goodExample: "let a = (1 + 2)",
      autofixable: true),
    CodeInfo(code: "unmatched-close",
      title: "Closing bracket with no opener",
      explanation: "A ')' / ']' / '}' appears with no matching open bracket.",
      badExample: "x)", goodExample: "x", autofixable: true),
    CodeInfo(code: "unclosed-bracket",
      title: "Opening bracket never closed",
      explanation: "A '(' / '[' / '{' is opened but never closed before " &
        "end of input.", badExample: "let a = (1 + 2",
      goodExample: "let a = (1 + 2)", autofixable: true),
    CodeInfo(code: "expected-colon",
      title: "Block header missing its ':'",
      explanation: "A construct that introduces an indented body (if, for, " &
        "proc, block, …) needs a ':' before the body.",
      badExample: "if c\n  echo 1", goodExample: "if c:\n  echo 1",
      autofixable: true),
    CodeInfo(code: "expected-condition",
      title: "Condition keyword with no condition",
      explanation: "if/elif/while/when is immediately followed by ':' with no " &
        "condition expression.", badExample: "elif:", goodExample: "elif cond:",
      autofixable: false),
    CodeInfo(code: "expected-in",
      title: "'for' header missing 'in'",
      explanation: "A 'for' loop needs 'in' between its variables and the " &
        "iterable.", badExample: "for x 1 .. 3:", goodExample: "for x in 1 .. 3:",
      autofixable: false),
    CodeInfo(code: "expected-indented-body",
      title: "Block header with no indented body",
      explanation: "A ':' opened a block but no more-indented body followed.",
      badExample: "if c:\nx = 1", goodExample: "if c:\n  x = 1",
      autofixable: false),
    CodeInfo(code: "missing-routine-equals",
      title: "Routine has a body but no '='",
      explanation: "A proc/func/method/iterator with an indented body must be " &
        "introduced with '='. A bare forward declaration is fine without one.",
      badExample: "proc f()\n  echo 1", goodExample: "proc f() =\n  echo 1",
      autofixable: true),
    CodeInfo(code: "expression-expected",
      title: "Expression expected",
      explanation: "An operator, comma, or dot has no operand after it, or a " &
        "comma slot is empty.", badExample: "let x = 1 +",
      goodExample: "let x = 1 + 2", autofixable: false),
    CodeInfo(code: "identifier-expected",
      title: "Identifier expected",
      explanation: "'let'/'const' must be followed by a name (or '(' for a " &
        "tuple unpack).", badExample: "let proc", goodExample: "let x = proc () = discard",
      autofixable: false),
    CodeInfo(code: "invalid-character-literal",
      title: "Invalid character literal",
      explanation: "A char literal must hold exactly one character; '' is empty.",
      badExample: "let c = ''", goodExample: "let c = ' '", autofixable: false),
    CodeInfo(code: "unterminated-char",
      title: "Character literal not closed",
      explanation: "A character literal is missing its closing quote.",
      badExample: "let c = 'a", goodExample: "let c = 'a'", autofixable: true),
    CodeInfo(code: "unterminated-string",
      title: "String literal not closed",
      explanation: "A string literal has no closing quote before end of line/input.",
      badExample: "let s = \"hello", goodExample: "let s = \"hello\"",
      autofixable: false),
    CodeInfo(code: "unterminated-comment",
      title: "Block comment not closed",
      explanation: "A '#[' block comment has no matching ']#'.",
      badExample: "echo 1 #[ never closed", goodExample: "echo 1 #[ closed ]#",
      autofixable: false),
    CodeInfo(code: "unterminated-backtick",
      title: "Accent-quoted identifier not closed",
      explanation: "A `` ` ``-quoted identifier has no closing backtick.",
      badExample: "let `a = 1", goodExample: "let `a b` = 1", autofixable: false),
    CodeInfo(code: "invalid-escape-sequence",
      title: "Invalid string escape",
      explanation: "A backslash escape in a string is not a recognised sequence.",
      badExample: "let s = \"a\\qb\"", goodExample: "let s = \"a\\nb\"",
      autofixable: false),
    CodeInfo(code: "invalid-unicode-escape",
      title: "Invalid unicode escape",
      explanation: "A \\u{...} escape is empty or malformed.",
      badExample: "let s = \"\\u{}\"", goodExample: "let s = \"\\u{1F600}\"",
      autofixable: false),
    CodeInfo(code: "invalid-number",
      title: "Malformed numeric literal",
      explanation: "A number has a bad prefix, doubled or trailing underscore, " &
        "or missing digits.", badExample: "let x = 1__0", goodExample: "let x = 1_000",
      autofixable: false),
    CodeInfo(code: "invalid-int-literal",
      title: "Malformed integer literal",
      explanation: "An integer literal is written in an invalid form.",
      badExample: "echo 0O5", goodExample: "echo 0o5", autofixable: false),
    CodeInfo(code: "invalid-identifier",
      title: "Malformed identifier",
      explanation: "An identifier has a leading/trailing or doubled underscore.",
      badExample: "var a__b = 1", goodExample: "var a_b = 1", autofixable: false),
    CodeInfo(code: "number-out-of-range",
      title: "Number out of range for its type",
      explanation: "An integer literal exceeds the range of its typed suffix.",
      badExample: "let x = 0x123'u8", goodExample: "let x = 0xFF'u8",
      autofixable: false),
    CodeInfo(code: "tabs-not-allowed",
      title: "Tab character used",
      explanation: "Tabs are not allowed outside strings/comments; use spaces. " &
        "A mid-line tab can be auto-fixed; an indentation tab needs a human.",
      badExample: "if true:\n\techo 1", goodExample: "if true:\n  echo 1",
      autofixable: true),
    CodeInfo(code: "mixed-indent",
      title: "Mixed tabs and spaces in indentation",
      explanation: "One line's indentation mixes tabs and spaces.",
      badExample: "if c:\n \techo 1", goodExample: "if c:\n  echo 1",
      autofixable: false),
    CodeInfo(code: "indent-width",
      title: "Indent not a multiple of the configured width",
      explanation: "Advisory: a line's indent isn't a multiple of --indent-width.",
      badExample: "", goodExample: "", autofixable: false),
    CodeInfo(code: "indent-consistency",
      title: "Inconsistent indent step",
      explanation: "Advisory: a line's indent isn't a multiple of the file's " &
        "derived indent step.", badExample: "", goodExample: "", autofixable: false),
  ]

proc lookup*(code: string; found: var bool): CodeInfo =
  found = false
  let kb = knowledgeBase()
  for i in 0 ..< kb.len:
    if kb[i].code == code:
      found = true
      return kb[i]
  result = CodeInfo(code: code, title: "", explanation: "", badExample: "",
                    goodExample: "", autofixable: false)

proc knownCode*(code: string): bool =
  var f = false
  discard lookup(code, f)
  result = f

proc shortDescription*(code: string): string =
  ## One-line description for a code (its title), or the code itself if unknown.
  var f = false
  let info = lookup(code, f)
  result = if f: info.title else: code

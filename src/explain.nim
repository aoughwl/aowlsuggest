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
    CodeInfo(code: "comparison-in-binding",
      title: "Comparison '==' where an assignment was meant",
      explanation: "A '==' where a let/const binding's '=' belongs compares " &
        "rather than assigns — the mirror of assignment-in-condition, and " &
        "almost always a typo for '='.",
      badExample: "let x == 5", goodExample: "let x = 5", autofixable: true),
    CodeInfo(code: "walrus-in-binding",
      title: "Walrus ':=' where a Nim binding wants '='",
      explanation: "':=' is the Pascal/Go assignment operator; a Nim " &
        "let/const/var binding assigns with a plain '='. (':=' lexes as one " &
        "operator, distinct from a ':' type annotation.)",
      badExample: "let x := 5", goodExample: "let x = 5", autofixable: true),
    CodeInfo(code: "double-colon",
      title: "'::' scope resolution — Nim qualifies with '.'",
      explanation: "'::' (a C++ scope-resolution habit, `std::vector`) is not " &
        "valid Nim. NOT auto-fixed: the intended repair is '.' (qualify a name, " &
        "`std.vector`) or a single ':' (a mistyped annotation) — only you know " &
        "which, so it is offered as a suggestion.",
      badExample: "std::vector", goodExample: "std.vector", autofixable: false),
    CodeInfo(code: "c-brace-body",
      title: "C-style '{ }' block body — Nim uses an indented body",
      explanation: "Nim writes a routine body as '= <indented statements>', not " &
        "'{ … }' braces (a C/Java/JS/Rust habit). NOT auto-fixed: turning the " &
        "braces into an indented block is a reformat only you should confirm.",
      badExample: "proc f() { echo 1 }", goodExample: "proc f() =\n  echo 1",
      autofixable: false),
    CodeInfo(code: "foreign-function-keyword",
      title: "'fn' / 'function' / 'fun' is not a Nim keyword — use 'proc'",
      explanation: "Nim defines a routine with 'proc' (or func/method/…), not the " &
        "Rust 'fn', JS 'function' or Kotlin 'fun' keyword, and uses an indented " &
        "body after '=' rather than a '{ }' block. NOT auto-fixed: 'proc name() = " &
        "<indented body>' replaces both the keyword and the whole brace body, a " &
        "reformat only you should confirm.",
      badExample: "fn main() {\n  echo 1\n}", goodExample: "proc main() =\n  echo 1",
      autofixable: false),
    CodeInfo(code: "foreign-block-keyword",
      title: "'class' / 'struct' / 'namespace' … is not a Nim keyword",
      explanation: "Nim declares a type with 'type Name = object' (or ref object / " &
        "enum / concept), not the 'class'/'struct'/'interface'/'impl'/'trait' block " &
        "of another language, and a module is a FILE — there is no 'namespace'/" &
        "'module' block. NOT auto-fixed: mapping the '{ }' block to a 'type … = " &
        "object' (or an import) is a design choice only you should make.",
      badExample: "class Foo {\n  x: int\n}", goodExample: "type Foo = object\n  x: int",
      autofixable: false),
    CodeInfo(code: "stray-end",
      title: "Stray 'end' — Nim uses indentation",
      explanation: "'end' is a reserved keyword with no statement form (a " &
        "Ruby/Pascal/Lua block terminator). Nim delimits blocks by indentation, " &
        "so aowlsuggest removes the stray 'end'.",
      badExample: "…block…\nend", goodExample: "…block…", autofixable: true),
    CodeInfo(code: "mut-not-a-keyword",
      title: "'mut' is not a keyword — a mutable binding is 'var'",
      explanation: "Nim has no 'mut' keyword (the Rust mutable-binding habit). A " &
        "mutable binding is introduced with 'var'. aowlsuggest rewrites " &
        "'let/var/const mut x' to 'var x'. A variable literally named 'mut' " &
        "('let mut = 5') and the 'x: var int' type modifier are left untouched.",
      badExample: "let mut x = 5", goodExample: "var x = 5", autofixable: true),
    CodeInfo(code: "go-var-notype",
      title: "'var x int' — a typed binding needs a ':'",
      explanation: "Nim writes a typed binding as 'name: Type', not the " &
        "Go/Java/C#/Swift 'name type'. aowlsuggest inserts the ':' — " &
        "'var x int' becomes 'var x: int'. An export marker is preserved " &
        "('var x* int' → 'var x*: int').",
      badExample: "var x int", goodExample: "var x: int", autofixable: true),
    CodeInfo(code: "angle-bracket-generics",
      title: "'<T>' angle-bracket generics — Nim uses '[T]'",
      explanation: "Nim writes generic parameters in square brackets, not the " &
        "C++/Java/Rust/TS angle brackets. aowlsuggest rewrites 'proc f<T>()' to " &
        "'proc f[T]()' (finding the matching '>').",
      badExample: "proc f<T>()", goodExample: "proc f[T]()", autofixable: true),
    CodeInfo(code: "arrow-return-type",
      title: "'->' return-type arrow — Nim uses ': type'",
      explanation: "Nim declares a routine's return type after a colon, not " &
        "with a '->' arrow (a Rust/Python-3/C++ habit). aowlsuggest rewrites " &
        "'proc f() -> T' to 'proc f(): T'.",
      badExample: "proc f() -> int", goodExample: "proc f(): int", autofixable: true),
    CodeInfo(code: "else-if-not-elif",
      title: "'else if' is not Nim — use 'elif'",
      explanation: "Nim's condition-chain keyword is 'elif'; 'else' must be " &
        "followed directly by ':'. Writing 'else if' (a C/Python habit) is " &
        "always malformed. aowlsuggest collapses it to 'elif'.",
      badExample: "else if b:", goodExample: "elif b:", autofixable: true),
    CodeInfo(code: "c-style-operator",
      title: "C boolean operator '&&' / '||' — use 'and' / 'or'",
      explanation: "Nim spells boolean and/or as the words 'and'/'or', not " &
        "'&&'/'||'. Opt in with --style:c-operators. NOT auto-fixed: '&&'/'||' " &
        "are definable operators and 'and'/'or' bind at a different precedence, " &
        "so the rewrite is offered as a suggestion for you to confirm.",
      badExample: "if a && b:", goodExample: "if a and b:", autofixable: false),
    CodeInfo(code: "redundant-semicolon",
      title: "Redundant trailing ';'",
      explanation: "Nim separates statements by newline, so a trailing ';' at " &
        "the end of a statement is redundant. Opt in with --style:semicolons; " &
        "aowlsuggest deletes it. Only a STATEMENT-LEVEL ';' is flagged — a ';' " &
        "inside (...) is a parameter separator and is left alone.",
      badExample: "let x = 5;", goodExample: "let x = 5", autofixable: true),
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
    CodeInfo(code: "missing-type-equals",
      title: "Type has a body but no '='",
      explanation: "A type declaration has an indented body (fields, or " &
        "'object'/'enum' members) but no '=' to introduce it. The right " &
        "completion ('= object' / '= enum' / '= …') can't be inferred, so it " &
        "is reported rather than guessed.",
      badExample: "type T\n  x: int", goodExample: "type T = object\n  x: int",
      autofixable: false),
    CodeInfo(code: "of-without-value",
      title: "'of' branch has no value to match",
      explanation: "An 'of' branch (in a case statement or an object variant) " &
        "has a ':' with no value between 'of' and it — there is nothing to " &
        "match against.", badExample: "case x\nof:\n  discard",
      goodExample: "case x\nof 1:\n  discard", autofixable: false),
    CodeInfo(code: "empty-variant-branch",
      title: "Object-variant branch has an empty body",
      explanation: "An object-variant 'of' branch declares no fields; a branch " &
        "body must contain at least a field, or 'nil'/'discard' for an " &
        "intentionally empty one.",
      badExample: "case k\nof A: nil\nof B:", goodExample: "case k\nof A: nil\nof B: nil",
      autofixable: false),
    CodeInfo(code: "enum-member-not-identifier",
      title: "Enum member is not an identifier",
      explanation: "An enum body contains something other than a member name " &
        "(e.g. a keyword like 'when'). Enum members must be plain identifiers; " &
        "conditional members aren't allowed.",
      badExample: "type E = enum\n  when x: a", goodExample: "type E = enum\n  a, b",
      autofixable: false),
    CodeInfo(code: "func-in-type-description",
      title: "'func' used in a type description",
      explanation: "'func' can't appear in a type position (field/param/alias " &
        "types); use 'proc (...) {.noSideEffect.}'. Not auto-fixed because a " &
        "bare 'proc' would silently drop the no-side-effect guarantee 'func' " &
        "implies.",
      badExample: "var x: func (): int",
      goodExample: "var x: proc (): int {.noSideEffect.}", autofixable: false),
    CodeInfo(code: "unknown-byte",
      title: "Illegal byte in source",
      explanation: "An unknown/illegal byte was found and skipped. Deleting it " &
        "could change intent (it may be corrupted text), so it is reported " &
        "rather than auto-removed.",
      badExample: "let x = 1\x00", goodExample: "let x = 1", autofixable: false),
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
      autofixable: true),
    CodeInfo(code: "unterminated-comment",
      title: "Block comment not closed",
      explanation: "A '#[' block comment has no matching ']#'.",
      badExample: "echo 1 #[ never closed", goodExample: "echo 1 #[ closed ]#",
      autofixable: true),
    CodeInfo(code: "unterminated-backtick",
      title: "Accent-quoted identifier not closed",
      explanation: "A `` ` ``-quoted identifier has no closing backtick. Not " &
        "auto-fixed: a backtick identifier may hold spaces and operators, so " &
        "where the closer belongs is ambiguous — aowlsuggest suggests it instead.",
      badExample: "let `a = 1", goodExample: "let `a` = 1", autofixable: false),
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
      explanation: "An integer literal is written in an invalid form. A base " &
        "prefix spelled with an uppercase letter ('0O'/'0B') can be auto-fixed " &
        "by lowercasing it.",
      badExample: "echo 0O5", goodExample: "echo 0o5", autofixable: true),
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
    CodeInfo(code: "trailing-whitespace",
      title: "Trailing whitespace",
      explanation: "A line has spaces or tabs before its newline. Opt in with " &
        "--style:trailing-whitespace (or --pedantic); aowlsuggest then deletes " &
        "the trailing run — a whitespace-only, program-preserving fix.",
      badExample: "let x = 1␠␠␠", goodExample: "let x = 1", autofixable: true),
    CodeInfo(code: "line-ending",
      title: "Line ending does not match the configured policy",
      explanation: "A line's ending (LF vs CRLF) doesn't match the asserted " &
        "convention. Opt in with --style:lf (or --style:crlf); aowlsuggest " &
        "rewrites the terminator — a whitespace-only fix.",
      badExample: "let x = 1<CR><LF>  (under --style:lf)",
      goodExample: "let x = 1<LF>", autofixable: true),
    CodeInfo(code: "missing-final-newline",
      title: "File does not end with a newline",
      explanation: "The source does not end with a trailing newline. Opt in " &
        "with --style:final-newline (or --pedantic); aowlsuggest appends one.",
      badExample: "…last line (no newline)", goodExample: "…last line\\n",
      autofixable: true),
    CodeInfo(code: "bom-rejected",
      title: "Leading UTF-8 BOM rejected",
      explanation: "A leading UTF-8 byte-order mark was found. Opt in with " &
        "--style:bom to reject it; aowlsuggest then strips the 3 BOM bytes " &
        "(the default check strips the BOM silently and reports nothing).",
      badExample: "<EF BB BF>let x = 1", goodExample: "let x = 1",
      autofixable: true),
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

proc hasGuidance*(code: string): bool =
  ## Whether a diagnostic of this code will ALWAYS carry something actionable —
  ## an auto-fix, aowlparser's own `fix` hint, or a KB fallback suggestion. The
  ## completeness invariant (tested): no known code should be a bare diagnostic
  ## with no advice. A new aowlparser code that lands here without guidance is a
  ## signal to add a suggestion for it.
  var f = false
  let info = lookup(code, f)
  if not f: return false
  if info.autofixable: return true
  if suggestionFor(code).len > 0: return true
  for i in 0 ..< parserFixCodes.len:
    if parserFixCodes[i] == code: return true
  return false

const parserFixCodes* = [
  ## Codes aowlparser itself attaches a `fix` hint to (so they always surface as
  ## a suggestion even without a KB entry). Kept in sync with aowlparser's
  ## emission; used only by `hasGuidance` for the completeness invariant.
  "assignment-in-condition", "expected-colon", "missing-routine-equals",
  "missing-type-equals", "expected-condition", "expected-in", "of-without-value",
  "expected-indented-body", "func-in-type-description", "empty-variant-branch",
  "enum-member-not-identifier", "invalid-number", "c-style-operator",
  "double-colon", "c-brace-body", "foreign-function-keyword", "go-var-notype",
  "foreign-block-keyword"]

proc suggestionFor*(code: string): string =
  ## A crisp, actionable hint for the lexer VALUE errors that aowlparser doesn't
  ## attach a `fix` to (a bad escape, an out-of-range number, an illegal byte).
  ## aowlsuggest surfaces this as a fallback suggestion so no diagnostic is left
  ## without guidance — but only when aowlparser itself gave none (its own fix is
  ## context-specific and always wins). Nothing here is auto-APPLIED: these are
  ## repairs only a human can make, so they stay suggestions by construction.
  case code
  of "unterminated-backtick":
    "add the closing backtick (`` ` ``) right after the identifier name"
  of "unknown-byte":
    "remove or replace the illegal byte"
  of "invalid-identifier":
    "identifiers start with a letter or '_' and can't contain that character"
  of "invalid-escape-sequence":
    "use a valid escape, e.g. \\n \\t \\r \\\\ \\\" or \\xNN (or a raw string r\"…\")"
  of "invalid-unicode-escape":
    "write a unicode escape as \\uXXXX (four hex digits) or \\u{…}"
  of "invalid-character-literal":
    "a char literal holds exactly one character, e.g. 'a' or '\\n'"
  of "number-out-of-range":
    "the literal exceeds its type's range — use a wider type or a smaller value"
  of "identifier-expected":
    "a name is required here — provide a valid identifier"
  of "expression-expected":
    "a value is missing — supply an expression (or delete the stray operator/comma)"
  of "mixed-indent":
    "indent with only spaces or only tabs on a line, never both"
  of "indent-width":
    "indent by a consistent multiple (e.g. 2 spaces per level)"
  of "indent-consistency":
    "match the file's indent step — keep the same spaces-per-level throughout"
  else:
    ""

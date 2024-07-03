# Language Reference

## Sifu-Specific Terminology and Grammar

#### Nouns

- Atom - anything not separated by the lexer, such as `1`, `"asd"`, or `Foo`.
- Term - a single atom or nested apps, separated by whitespace like `1`, `(Fn 123 "asd")`,
or `Foo`.
- Sub-term: a term inside an app, which is the containing term
- Key - an uppercase word atom
- Var - a lowercase word atom, matches and stores a match-specific term. During
rewriting, whenever the var is encountered again, it is rewritten to this
term. A Var pattern matches exactly one term, including nested patterns. It
only makes sense to match anything after trying to match something specific, so
Vars always successfully match (if there is a Var) after a Key or Subpat match
fails.
- Apps - a list of terms, nested by parenthesis
- Tuple - anything surrounded by parenthesis
- Ast - the Sifu specific data type of the generic Pattern data structure. Sifu
parses every token as a Token, which is a term with meta-information, and Apps
can be nested, so together they form the abstract syntax tree.
- Pattern - a trie of apps, nested by braces like `{ F, G -> 2 }`. Simple
patterns form sets like `{1, 2, 3}` or hashmaps like `{F -> 1, G -> 2}`.
- Match
  1. an expression of the form `into : from` where
    - into is the expression to match into
    - from is the pattern to match from
  2. the result of evaluating a match, consisting of selecting and rewriting.
- Arrow
  1. an expression of the form `from -> into` where
    - from is the expression to rewrite from, which was matched
    - into is the expression to rewrite into, which is the evaluation
  2. an encoding in a pattern that represents an arrow after its insertion in
that pattern, like the arrow in `{F -> 123}`
- Value - the right side of an arrow, the part rewritten to
- Commas - special operator that delimits separate keys/arrows in patterns
- Newline - separates apps, unless before a trailing operator or within a nested
paren or brace.
- Quotes - code surrounded with (`). Not evaluated, only treated as data.
- Ops - a special kind of Term that has different parsing
- Infix - shorthand for an Op that is user defined
- Builtin - a builtin operator (there are no keywords). Builtins are the only
operators with precedence in Sifu. This precedence is as follows: 
> semicolons < long match, long arrow < comma < infix < short match, short arrow
  - Commas and Semis - these delimit separate expressions within a specific level of nesting. Commas are high precedence, while Semicolons are low. 

#### Verbs

- Current scope - the set of all parent patterns and the current but only the
current expression and above
- Select - the first phase during matching when looking up an expression that
match keys in the pattern
- Evaluate - given an expression, match it against the current scope and rewrite
to the first match's value. Repeats until no match, no value, or the value is
equal to the current expression.
- Return: a shorthand for "evaluate to after matching from a tag"
- Function: a nickname for multi-term patterns that start with a constant (the
"function" name) and take "arguments" as variables in its subsequent terms.


---

## Expressions

### Terms

### Apps
`Foo` is an App of one term, `(Foo)` is an App of an App of a term.
By default, all expressions in Sifu form an app until either an infix or pattern is parsed.


### Parentheses
Parentheses do not specify precedence, they force their contained
expression into a single-term App. This has a sometimes surprising consequence:
single-terms inside parentheses are singleton apps instead of terms. While
this is weird for expressions, is makes sense for matching, and consistency in
general. If the key `(Foo Bar)` doesn't match `Foo Bar`, then `(Foo)` shouldn't
match `Foo`.

(These technically make the language into a Lisp, but don't tell anyone, I want
_some_ users)

### Infix Operators

### Lists

Lists are represented the same as in Haskell, where `[1,2,3]` becomes an app of cons with the empty list literal: `1 :> 2 :> 3 :> []`. Tuples are implemented in the same way, but have different type checking semantics.

---

## Patterns

### Literals

The simplest patterns are single-term literals, and resemble constants in other
languages:
`Foo -> 123`
This pattern would only match an Ast with a single term:
`Foo`, which would return `123`.

Multi-term literals aren't that much different, only they match multiple terms:
`Foo Bar Baz -> "*-oriented programming is overrated"`

Nested patterns are Apps that contain other Apps:
`(Foo Bar) Baz -> 42`
This will only match `(Foo Bar) Baz`, and not `Foo Bar Baz`.

### Variables

A variable pattern matches any corresponding term in the key. For example, the entry `Fn arg => 4` would match `Fn MyArg`, `Fn 123`, etc. Here, the second term binds to the second term of the key. It would not match `Fn`, or `Fn Arg1 Arg2` because a key must always be the same length of a pattern to match.

---

## Matching

---

## Evaluation and Termination

All Sifu programs terminate. Recursive patterns must therefore either make some sort of progress, or stop trying to match. Sifu looks for progress by checking that for all recursive calls in the body, they have at least one term that is _contained_ by an app in the corresponding term in the key (structural recursion). This forces any computation to remove a layer of nesting from the key, which invariably reduces it.

For example, consider the `Map` function which is defined pretty much identically to a typical functional language:
```
# `[]` is the empty list literal
Map fn [] -> []
# `:>` is the cons operator
Map fn (x :> xs) -> fn x :> Map fn xs
```
This will match expressions like `Map (+1) [1,2,3]`, which after desugaring into `Map (+1) (1 :> 2 :> 3 :> [])` matches and binds `x` to the app `1` and `xs` to the app `2 :> 3 :> []`. The recursive call will terminate because it contains at least one term, `xs`, that is a sub-term of its corresponding term in the key, `(x :> xs)`.

Recursive entries that do not make progress are definable, but when matched will only rewrite other terms, not the recursive entry. For example, the following is allowed:
```
Foo x y -> Foo y x
```
An expression like `Foo 1 2` would match, and return `Foo 2 1`.

Sifu must also guard against infinite loops that don't have direct recursive
calls. Consider, for example, the following entries:
```
F -> G
G -> F
```
To prevent a match to either `F` or `G` from recursing forever, patterns only match entries defined before the current one. So after defining these two entries, `F` will evaluate to `G`, then stop, and `G` will evaluate to `F`, match the first entry, and finally return `G` again.

---

## Semantics and Syntax Isomorphism

All syntax in Sifu can be parsed into a Pattern, then mapped back into the original syntax (although it will be desugared). This implies that _all_ syntax has semantics, i.e. parentheses have meaning.

## Parsing

parsing

## Type Checking as Pattern matching on Patterns

To type check a Sifu program, ensure each expression will match at least once.

For example, consider the following definitions modeling boolean algebra:
```
Bool => { True, False }

And (True : Bool) (True : Bool) => True
And (_ : Bool) (_ : Bool) => False 
```
Then an expression like this should also have type `Bool`:
```
And False True
```
To type check it, we need to show each argument will match its parameter at least once. Both `False : Bool` and `True : Bool` match, so this program is checked.

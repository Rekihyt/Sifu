# Language Reference

## Sifu-Specific Terminology

- Terms: a syntax atom like `1`, `"asd"`, or `Foo`.
- App, Applications: a concatenated sequence of terms, like `F x 1`
- Ast: an Ast is a specific term data type that is then concatenated into Apps. Sifu parses every token as a Term, and Apps can be nested, so together they form an abstract syntax tree.
- Pattern: a specification for how to match a particular Ast. Patterns and Asts are intimately connected, because to match a nested structure, patterns must be nested in the same way.
- Ast: A near synonym for Pattern but implies usage as data, not computation. It is also a tree, whereas Patterns are more like tries.
- Return: a shorthand for "evaluate to"
- Function: a nickname for multi-term patterns that start with a constant (the "function" name) and take "arguments" as variables in its subsequent terms.
- Entry: a definition of a pattern with a value, like `Foo -> Bar`.
  - Key: the left-hand side (`Foo`)
  - Val, Value, Body: the right-hand side (`Bar`) 
- Sub-term: a term inside an app, which is the containing term
- Match: an expression with a pattern that it will be matched with.
`Foo : Bool` will match `Foo` against the pattern `Bool`, but first needs to match `Bool` until it gets a pattern (like `{True, False}`).

---

## Expressions

### Terms

### Apps
`Foo` is an App of one term, `(Foo)` is an App of an App of a term.

### Parentheses
Parentheses do more than just specify precedence, they force their contained expression into a single-term App. This has a somewhat unexpected consequence: single-terms inside parentheses are apps instead of terms. While this is weird for expressions, is makes sense for matching. If the key `(Foo Bar)` doesn't match `Foo Bar`, then `(Foo)` shouldn't match `Foo`.

(These technically make the language into a Lisp, but don't tell anyone, I want _some_ users)

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

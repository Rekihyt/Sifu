## Sifu

### Names

Simply Functional. Pavl?

You can't make mistakes if you don't make decisions.

I would tag the effort I put into Sifu as the product of the sum of my labor.

Bougie, adj. A feature is first class, or else it doesn't get through the door.

Englsh can also be wrtten n pontfree style

Always look for dualities. Then look again because you didn't look twice.

Sifu is a DSL for general purpose programming. It is also a general purpose tool for building DSLs. We have all the buzzwords here.

You wrote a language to write your video game in. I wrote a language to write my language in. We are not the same.

Metaprogramming is the natural result of a language which doesn't special-case itself.

A computer manipulates symbols. Why limit the main interface we have with computers to not use arbitrary symbols?

The more your language's implementation differs from its AST (imo, homoiconicity), the more complex its implementation and macro system.

The problem with OOP is that it tries to apply a data structure, the tree, to a model of computation that is fundamentally a graph. It isn't a terrible idea to treat all data or computation as a tree, it just doesn't work for the cycles that exist in turing-complete OOP languages.

Semantics should guide syntax. The more a language's syntax differs from its semantics, the more a programmer must do to translate their thoughts to and from code.

While computer science has benefited immensely by being pioneered by very smart people, language design, on the other hand, has suffered tremendously. Smart people are too willing to accept a complexity tradeoff that is a bad idea in the long run. Turing's use of the word "power" and its implications as a desireable trait has significantly misled compiler writers.

Comptime optimality: a metric of a compiler that measures the typical ratio of code that is executed at compile time over the total amount that could be. 

Fruit trees aren't real, only fruit tries exist.

Most ideas in Sifu are from other languages. For example, religiously capitalizing nouns comes from the other best language, German.

Complexity is a vampire. If you give it permission to enter your home, it will eventually return at night to devour you.

If a language can describe a feature without introducing additional complexity, it _has_ that feature.

The trend in declarative programming is just a different way of valuing homoiconicity.

Complexity = Information ^ 2

Programming languages today try to do two separate things at once: they model a form of computation (bit ops, memory, Non-network IO), and they talk about these computations (function calls, types, Network IO). But these are two separate things and they require two separate tools. A great example of this is the Python ecosystem: all the computation is done by a language good at it (C or C++), and the talking about these computations is left to a language good at that, namely Python. It is easier to have to separate languages than trying to do both even though both languages were designed as general purpose.

A computation model that facilitates language, not vice-versa.

### Ideas

- core language is just a rewrite engine
  - computation is a pattern match
  - logic operators `&`, `|`, `->`
  - tag operator `=>`
  - match / set membership / typeof `:`
  - variables are tags `x => 2`
  - "fields" are just type level tags (i.e. for a tagged product) `MyRecord => {{x => Int, y => Bool}}` (double set is necessary here for a value of type `MyRecord` to be _in_ its definition)
  - builtin sets, which are used to implement types
  - builtin hashmaps, which are used to implement records
  - hashmaps of types (tags) can trivially implement row types
  - type checking is just a pattern match on patterns
  - compliler treats type values as compile time and interprets them to type check. the interpreter treats them as normal sets
- Strats are literals preceded by the `$` symbol that can perform operations outside of the Sifu language spec. These are implemented as compiler extensions, and can interact with the user, for example by throwing compile errors. Strats should focus primarily on _how_ an expression evaluates instead of _what_ it evaluates to. For example, file IO, spawn/join threads. When pattern matching, strats in the match of a tag are matched as usual, but when encountered on the right they evaluated by invoking their matching compiler plugin, with any apps as args.
  - `$ lazy`: don't evaluate the expression until necessary
  - `$lazy 2` evaluate 2 expression deep
  - `$strict` force all evaluations to whatever depth
  - `$strict val` force evaluations until val, then evaluate it
  - `$lazy val` force evaluations until val, then stop
  - `$opt-level n`: optimize the expression at level `n`
    - $opt-0-none default, most straitforward translation possible
    - $opt-1-readable for readable source code
    - $opt-2-fast-readable for optimize, but preserve readability
    - $opt-3-fast optimize, no readability
    - $opt-4-all use all optimizations
    - Map custom semantics
    - Map an imported c function that returns a negative on error to a result type.
    - The strat ident "$" evaluates to all strategies currently in scope (being applied)
    ```
    open "@stdio.h" @int-to-result
    ```
    - Map a function like `printf` to a default effectful type
  - Customize memory usage with an @heap or @stack
  - `@import`: tell the compiler to find this tag in the default package manager's global hashmap

- when a strat `@strat` is passed as an argument to the compiler/interpreter, it is applied to the toplevel dict. By default, a Sifu project folder has a main source file with an optional dirs of source dirs / files

- Effect system as a library
  - Limit memory usage for a function with a memory effect
  - Effects that need special OS level support are built in

- Errors should efficiently communicate as much meta-information and context as possible. Grouped into a bar like [ Parsing 1 / Rewrite 0 / Types 3 / ...], where if there is an error message of the group, its shown in red. If the error is recoverable the bar continues on with possibly more errors, if not its stops there. Parsing errors should include possible causes not just fixes.

- A database for Sifu is just an Ast that stores an arbitrary value type. There could be typeclasses that tell the compiler how to store the values, i.e. if they are of fixed size they don't need separate allocation.

- No imports, instead use `open` on a source file, which is just a hash
  - file structure implies generated hashmap:
    - files: hash of tags in the file
    - folders: hash of file names to files contents
  - `open` is just a macro that expands definitions into the current scope
- lambda is always 1arg->1arg. to pass/return multiple values, use tuples `x -> x & 3`
- functions can take product or sum types
  - when a function `(A & B) -> C` is called with A, it returns `B -> C`
  - when a function `(A | B) -> C` is called with A, it returns C. This is because `A | B -> C & C @= (A -> C) & (B -> C)` and after applying `A`, the result is `C & B->C`. Then, by discarding `B -> C` (tuple indexing) to get `C`.
  - typically a function from `Int | Bool` would return another `|` type instead of one value. The order of values then determines which type the function was called with. For example:
  ```
  f : Int | Bool -> String | String
    => x : Int | y : Bool -> intToStr x | boolToStr y
    # pointfree: intToStr & boolToStr
  ```
  This doesn't happen automatically because the programmer might not always want the information of which type was used to be lost. For example, to write a bijection with `f`, maybe for some parser / pretty printer combo, one could define:
  ```
  g : (String | String) -> (Int | Bool)
    => i-str | b-str -> strToInt i-str | strToBool b-str
    # pointfree: strToInt & strToBool
  ```
- macro that abstracts many "of" patterns where a special operator is used in lines, like where and "=" or case and "=>".
  - these are term-rewriting macros
- A type is a set of sets. A set of tags forms a hash,  Any tagged type is implicitly coercible to an untagged, ordered type, but not vice-versa. This is so that functions can't accidentally take a similar type, but also to make tagged types easy to work with.
- anonymous record: a list of types
- record: a list of type tags
- anonymous variant: a set of types
- variant: a set of type tags
  MyRecord => [
    x => Int -> Bool,
    y => String,
  ]
  MyAnonRecord => [
    Int,
    Int | Bool,
    Int -> Bool,
  ]
  MyVariant => {
    String & String,
    Int | Bool,
  }
  MyAnonVariant => [
    x => Int,
    y => Int | Bool,
  ]
  ```
- record / sum types can be tagged
  ```
  MyVariant: variant of
    x: Int
    y: Int | Bool
    f: Int -> Bool

  MyProduct = product of
    x: Int
    y: Int | Bool
  ```

- case, let, etc. are macros too:
  ```
  case x of
    2 -> 2
  let of
    x = 3
  ```
lambda x y of
  x + y
- Optimization Semantics
  - Customize what a function compiles to:
  ```
  # Without effects, b unifies with a
  # With effects, b unifies with m a
  # In the impl for while, transforms the do ast into a monad bind chain
  while
    : a -> (a -> Bool) -> (a -> b) -> b
  main = while 0 (@ 10) { i - do
    print i
    i + 1
  }
  ```

- Evaluation model: no unlimited recursion, each evaluation must terminate
  - A rewrite rule terminates if:
    - The only recursive calls are to itself with a structurally reduced match
    - There are no cycles, where the same ast is matched more than once (with the exception of recursion)
      - Cycles are detected at compile time. Before a tag is added, its value is matched recursively against the current pattern state. Each recursive call is checked to not match the original key's pattern.
  - Infinite loops are implemented in layers, where they aren't allowed in pure computations but are allowed in process level or higher.
  - Both the lower level, dynamic rewriting language and the high level statically typed language are available to a programmer. The former for rapid prototyping and metaprogramming, and the latter for safety and speed.
- Replacement for effects?: layers like pure (single thread, no IO), threaded (multi thread, no IO), process (multi thread, IO), consoleIO and/or guiIO, deviceIO (file IO, gpus, etc), networkIO
  layers answer the question: who does the program talk to?
  layers are their own module in the project?


- Stdlib
  - Hash maps can be specified by defined operator "=>" like: hashmap ("key" => "val", ... )
  - The function might pattern match like so:
    ```
    hashmap (k => v) & next = HashMap (k, v) @ hashmap next
    hashmap k => v = HashMap (k, v)
    ```
    The type is therefore inferred as `N-Tuple k => v -> HashMap (k, v)`. The type `N-Tuple (k => v)` describes a product of one or more `(k => v)`.
  - Stdlib docs can be retrieved like any other tag. Docs attached to a tag are retrieved together, while standalone tags for tutorials might point exclusively to a doc comment.

- Equivalent of tuples for sum types:
  - $A \cup B$ @= (a & b)
  - $A \cap B$ @= (a | b)
  Records are named product types:
  ```
  # Create a newtype from a tuple type of (A, B) with labels x and y.
  MyTupleType => {
    I64,
    Utf8,
  }
  # Create a product from a tuple type of (x: A, y: B) with labels x and y.
  MyProductType => {
    x => I64,
    y => Utf8,
  }
  ```

```
# The compile time function `Effects` gathers up all effects inside the function into the form `E1 & E2 & ... En`. checkEffects then expects a return type of `Effects (E1 & ...) a`.
` ast -> effects ast >- checkEffects `
fizzBuzz
  : Int x -> Effects StdIO Unit
  = print -< x % 2 == 0

-- Since booleans are just a sum type `True | False`, we can do boolean algebra with type ops:
```
  True | False => True
  True & False => False
  False -> True => True
```
main
  : IO Unit
  = fizzBuzz 10 >- runEffect

# Generated code after macros:
fizzBuzz
  : I64 x -> Effects StdIO Unit
  = print -< x % 2 == 0

# Compiles to:
void fizz_buzz(i64 x) {
  printf("%d\n", x % 2 == 0);
}

```

- Comments are expressions:
  - Double quoted string is a function taking as many arguments as it has format specifiers
  - A double quoted string applied to an expression is a doc comment.
  - Doc comments
  - '#' for line comments
  - Compiler needs a switch to not ignore comments during evaluation

### Core Language: a subset of Sifu that consists of (|), (,), (=), (->) and is interpreted by the Haskell compiler during macro expansion into the Rich Ast. This lets things like section operators (x+) work, by parsing as (App x +) then transforming into (App + x).
- Ops
  - (|) The or operator, creates a value that is either the fst or snd arg, with type Fst | Snd
  - (&) The and operator, creates a value that is both the fst and snd arg, with type Fst & Snd
  @!-- - (!) The not operator on types, creates a value that is  --
  - (=) assignment
  - (->) lambda creation
  - (|) and (&) work on Bools because an overload is defined for them

- If / Else
  - if is just a function from Bool to (True | False)
    then is a function from True -> A
    else is a function from False -> A
  - equivalent to:
  ```
  if (== 2) product of:
    True -> "eq 2"
    False -> "nq 2"
  ```
    where `if (== 2)` becomes a function `Int -> Bool`, and is applied to a product `True -> Str, False -> Str`
  - or:
  ```
  if (== 2)
    then "eq 2"
    else "nq 2"
  ```

- Function application
Functions only apply to one argument. To pass multiple arguments, use tuples.
  - f (x, y) or f (x & y)
  - f g x => f (g x) apply the function f to (g x)


### TODO:
- fix sections left section / function app conflict
- sections must be converted into lambdas

### Compile steps

1. Expand macros. `Ast -> Rich Ast`

2. Expand partially applied infix operators into functions.

3. Expand infix trees, i.e. Infix "->" to ELambda. `Ast -> Labelled Ast`

4. Convert ast to paradigm codegen. `Labelled Ast -> Functional or Imperative Codegen`

5. Convert paradigm codegen into language specific codegen.

6. Eval codegen. `Codegen -> Text`

---

## Language Implementation

### Macros

In Sifu, all computation, even function application, is enabled by tags. Tags tell the compiler when to replace one expression with another, usually a variable or type. When a tag contains any backtick-quoted expressions (anything inside \`\`), it matches any expression of the same form and becomes a term-rewriting macro. These quoted variables are tags themselves that correspond to some value within the expression that matches the pattern.
For example:
```
x & y => ... # matches literals x and y
`x` & `y` => ... # matches any `&` expression, binding x and y to its two values.
```

### Patterns

A pattern match must therefore do three things:
1. Eq/Hash to the same thing for different forms of the same pattern (patterns like ``` `x` & `y` ``` and ``` `z` & `w` ```)
2. Map its named variables to a consistent, ordered set of variables.
3. Evaluate its body in a temporarily modified environment containing the variable bindings as tags.

### Requirements

1. Patterns must hash uniquely, yet any pattern must match vars
2. Patterns must overwrite each other when one is more general
3. Variables must match any ast
4. Variables of different names but same place must evaluate the same way
5. Variables always have one value, but that value may represent multiple computations using || with comma seperators. These are then pattern matched like lists but with a resulting expression that computes the cartesian product.

### Merge Algorithm

1. PLit hashes uniquely, just based on Ast's default hash. This is for patterns like `2 & x`, for which there is only one unique ast.
2. When merging two literal patterns, replace their smallest branch difference with a PMap hashmap, which maps their unique differences to other asts. If the two nodes are entirely difference (their roots are not equal) the PMap is at the top level.
3. To merge a literal into an existing map, because literals are always unique and have no subpatterns, it can simply be inserted.
4.
5. Anything merged with a var is instead discarded if it comes after the var (so you can try to match the more specific case first then fallback to the var).
6. Patterns like `PApp` must handle nested patterns, so instead of mapping to a `PLit`, they map to another `PMap`.

Application is just an operator, but uses juxtaposition instead of a symbol.

A key is a pattern that matches and returns its value.
An element is a pattern that matches but doesn't evaluate to anything.

two <= POp +  three <= POp +  five <= POp +
  PLit 2        PLit 2          POp /
  PLit 3        POp *             PLit 1
                  PLit 4          PLit 2
                  PLit 5        POp -
                                  PLit 2
                                  PLit 3

1 => PLeaf
+ => POp
  { 3 => Leaf, 2 => Leaf, 1 => Leaf }
  {
    3 => Leaf
    4 => Leaf
    * => POp {
      { 2 => Leaf }
      PVar v0
    }
  }

1 + (2 * 3) => one
POp +
  {1,2*3} => one
  {1}

[1]
[+ 3 4]

For each entry in the map, lookup versions of the tree with that entry and remove them recursively
3 + (2 * `v`)
3 + (2 * 6)
3 + (2 * 5)
3 + (2 * (7 - 8))
Prune PLit 6, PLit 5 and POp [-] (PLit 7) (PLit 8)

1 => one
2 + 3 => two
3 + 4 => three
3 + (2 * 6) => four
3 + (2 * 5) => five
3 + (2 * (7 - 8)) => five
3 + (2 * `v0`) => vour, [`v0`]

{
  1 => PLeaf
  + => POp
    { 2 => PLeaf }
    { 3 => PLeaf }
}

{
  2 => PLeaf
  + => POp
    {
      2 => PLeaf
      3 => PLeaf
    }
}

isBranch 2 + (3 + 4)?
  find op + => true
    find 2 => true
    find + => false

Sections?
[+]
{
  + => POp PLeaf PLeaf
}

[+1], [-1]
{
  + => POp PLeaf { 1 => PLeaf }
  - => POp {+ => L} { 1 => PLeaf }
}

For indexing, create a PatternKey from an Ast using the Pattern tree. Following a path through the tree, if there ever isn't a matching branch, the entire match fails. If there is a fully matching branch (not necessarily to a leaf) then lookup the PatternKey in the map. If a branch is a var, replace the ast value with the var counter, and increment the counter. Append the ast value to the varlist.
3 + (2 * "asd") becomes 3 + (2 * `v0`)
At the end, if there is a match, rewrite it using the varlist by replacing the vars with the ast at their index.

To add patterns, follow the tree until either the ast matches, in which enter the ast into the map, otherwise follow it until a leaf. Then transform the leaf into a pattern tree matching the subtree remaining in the ast.

of [1,2,3] => "asd"
of [1,`x`,3] => "zxc"

POf [
  PLit 1
  PLit 2
  PLit 3
] => "asd"

POf [
  PLit 1
  PLit `x`
  PLit 3
] => "zxc"


-- | These should be added as part of the stdlib
-- | factorRAnd (A -> B) & (A -> C) @= A & A -> (B & C)
-- | factorROr  (A -> B) | (A -> C) @= A | A -> (B | C)
-- | factorLAnd (A -> C) & (B -> C) @= (A | B) -> C & C
-- | factorLOr  (A -> C) | (B -> C) @= (A & B) -> C | C
-- |
-- |
-- | Function application
-- | (A -> B) A   => B
-- | (A op)       => App op A
-- |
-- | `(A -> B -> C) (A & B) => C` apply function to first value
-- | `((B -> C) & B)` by rewriting A
-- | `((B -> C) B` recurse on patterns like `(A -> _) & A`
-- | `C` normal form.
-- |
-- | `(A -> B -> C) (A & D) => (B -> C) & D`
-- | `((B -> C) & D)` by rewriting A
-- | no recursive app, B /= D
-- | normal form.
-- |
-- | Reduce first elem. `A` must be the first element in the sum type.
-- | `(A -> C) (A | B) => C | B`
-- | `(A -> C) (A & B) => C & B`
-- | `(A -> C) (A -> B) => error` While `A -> (C & B)` is possible, its not needed, use (&) instead of app.
-- |
-- | `(A -> B -> C) (A | B) => (B -> C) | B`
-- | `(A -> B) (A | B) => (B | B)` where the order of the sum type determines if
-- | the function was applied. `B | B` is therefore _not_ reducible as in logic.
-- |
-- | Idempotent preservation
-- | `(A -> B) (A | B) => B | B`
-- | `(A -> B) (A & B) => B & B`
-- |
-- | Product application. Distributes over both (|) and (&).
-- | `(A -> B & C -> D) (A | C) => B | D`
-- | `(A -> B & C -> D) (A & C) => B & D`
-- | `(A -> B & C -> D) (A -> C) => error`
-- |

When adding a pattern, the interpreter will return a list of all tags replaced by it. New patterns return [], existing literal and var patterns return a list of one or more.

When matching a literal pattern


## Debugging

### Graphical

- Interactively update a graphviz file based on the file/interpreter's state. When a new tag is added or an expression is matched, the paths in the pattern are traced.


### Numbers

Integers are implemented using a variant of Church numerals for the pattern
calculus, where an App of empty apps is used. The length represents the integer
value.


### Tags

Tags model lambdas when applied to other terms.
```
(x -> x + 2) 2 # would return 4
(x y -> x + y) 2 3 # would return 5
```

Tags in lists and sets/maps are an exception, and aren't evaluated.


### Effects and FFI as Drivers

Drivers are effect handlers written in the host language that are called when certain patterns are matched. Driver calls always begin with `@`, which is elided from the name to get the foreign function. These are then called with the values that the pattern matched with. Checking that a driver function signature matches its pattern is done at comptime. Effectful expression only allows moving of values out of a match when they are wrapped in another effectful expression, as doing otherwise would discard the effect.

Builtin functions are just FFI calls to a stdlib defined in the host language
(the language the compiler is written in). 
```
x + y => @add x y # call Zig's `Add` function, passing x and y as arguments
BitCast type bytes => @"@bitCast" type bytes # calls Zig's `@bitCast` function 
```
Zig FFI calls are type-checked at compile-time.

While pure, normal patterns use `->`, effectful patterns are defined with a double-arrow tag (`=>`). They contain at least one effectful FFI call in a sub- pattern. Normal patterns can call and be called by effectful functions?

- This affects variables, as they could take either kind of pattern

Normal patterns can only call effectful ones by taking them as variables.

Every pattern stores a boolean representing if it is an effect or not.

Since pretty much everything is an effect in Sifu, the pure language could run on a machine that doesn't even support addition, only strings. Perhaps a cpu could be designed around this?

### Reverse operators

The tag operators in Sifu (`->`, `=>`) have reverse versions with the exact same semantics. They are just there for consistency (they can't be redefined) but maybe also for clarity in some cases. Consider importing from a file, one might think of it more as "taking" some definitions from a namespace:

```
sifu_defs <- sifu_defs : Sifu
```
This is exactly the same as `Sifu sifu_defs -> Sifu sifu_defs` but perhaps more
readable. Its not actually, `sifu_defs : Sifu -> Sifu sifu_defs` is clearer.


# FOCUS ON THE MVP

The goal is simplicity!
- Patterns are just patterns, they don't handle effects, ffi, etc.

[x] Finalize the Ast/Pattern datastructures.
[x] Decide how to deal with lit/var/term fiasco

## Gradual compilation

By default, the compiler will try to compile as many definitions as possible. However, it should be possible to compile any pattern individually on a case by case basis. This could be really interesting with Zig's upcoming binary patching.

### Computations vs Tuples

These must be different, because computations are fundamentally more reducable than tuples.
```
# Compute a value, taking advantage of `(x) -> x` to reduce the value:
1 + (2 + 3)

# Match a tuple of the empty tuple, which shouldn't reduce:
⟨⟨⟩⟩ -> ...
```

---

- Tags in a list should behave like a record

- Effectful functions should take () as a parameter

- `+123` should be a signed value, and just `123` unsigned

- Markdown should be a doc node, with each line of text an entry into a list. Code/Docs can contains docs which can contain code, etc.

- 

---

### Problems

- Sometimes we want to ask, what is the type of x? It makes sense that identifying a type should behave the same as any other computation.
  1. Whenever anything matches, the resulting expression includes the type like so `expr : Type`. Then matches must not simplify. This would be interesting to turn off in interpreted mode, and on when compiled.
  2. Perhaps type inference is looking up types but not values?
  3. Store some kind of lookup table?? Seems sus
  4. ->> Match the pattern `(x : _)`, although this is O(N)
- Some patterns shouldn't be rewritten, like the second `Int` here: `x : Int -> x : Int`. 
  1. ->> Do not rewrite patterns on the right side of matches in the key and/or resolved patterns i.e. those that were a Val that was looked up. 
- What is the type of infix operators / functions?
- Multiple definitions of matches need to be tried instantly, not linearly.
  ```
  x : Int -> x
  y : Bool -> y
  n : Int : Num -> n
  m : Float : Num -> m
  l : _ : Num -> l
  ```
  1. A match pattern is also a map, to various patterns
  2. ->> A value gathers evidence of its type and keeps it around as a match. Then match patterns match `:` like any other operator.
  3. ->> matching must be dynamic, for things like matching multiple dependent types, so add (:) as a builtin match operator as a fallback if (2) doesn't match. This will take O(N) time because each subpattern must be matched in order. It might be ok to disallow this when compiling, or explicitly opt-in. 
- Pointfree definitions aren't typeable until applied to something. They resemble copy-pasting.

- Pattern matching is basically string matching on terms instead of chars. It therefore has the same problem of substring search, where we will need KMP or something  to avoid O(N^2) worst-case matching.

- Being able to pattern match on apps, instead of nested ops, is very important for efficiency, because it is array based vs linked list. 

- Union, Set Difference, and friends must be definable by matching on sets and creating new ones based on their elements.

- Matching must be efficient, with both left-to-right and other kinds of recursion.

- Sifu must support graphs, and their algorithms.

- Common Monads in Haskell should be embedded somewhere in the language, or arise naturally

- Infix operators lose information about precedence when concatenated. For example, (x & y) | (w & z) isn't equal to x & y | w & z
  1. Make infix operators stop? idk
  2. Ignore this issue and require parens (probably necessary)
  3. Add builtin precedence (eww)
  4. Make variables only match terms, not apps
  5. Preserve apps during binding/matching, i.e. rewrite to (x & y) | (w & z)

- Allowing {} to be made _after_ matching means dynamically creating patterns
  1. Probably just ok, maybe even desirable in order to talk about {} syntax without making a pattern.
  2. Asts should store patterns though, otherwise the semantics of patterns as tokens doesn't match that of the data structure.
    - Not a problem if we don't use Asts after Pattern-Construction phase.
  3. Don't even have an Ast, just parse patterns directly
    - Asts are more efficient, as they aren't linked lists
    - Metaprogramming? Dynamic creation of arbitrary asts before they are given meaning lets you define syntax
    - Asts aren't more efficient, everything must be a pattern eventually.
    - The only place Asts may be useful are as Vals

- Everything must be an App by default. This makes it weird to define empty apps, because `()` for example is a _non-empty_ app of an empty app.
  1. Make patterns match Apps by default as well.
  2. Allow defining doubleline separated empty apps such as `Empty -> ` only at top-level scope.
    - This is awful for multiple short definitions, not an option, use single line + no indent as a sep
    - For interpreter, Alt-Enter gives attached newline capability
  3. Any other empty apps are treated as partial applications of tags, using the previously defined `Empty` when needed.

- Patterns that share the same prefix aren't exactly obvious how they match:
  ```
  Foo -> 123
  Foo Bar -> 456
  ```
  How would the above match `Foo Bar`? `456`, or `123 Bar`?

- Variable identifiers take up all lowercase idents
  1. Use sigils instead, ugly but simple and effective
  2. Infer variables from previous patterns
    - elegant but dangerous
    - requires ide support in large codebase
    - requires context
  3. Use sigils, but infer variables in entry vals
    - Introduces shadowing

- Variables must match multiple times, modeling cartesian products. These matches form a flattened trie? A trie could be seen as all the different matching trees as one. This leads me to the conclusion that a dynamic webpage is a trie...
  1. Use `,` and `;` to encode a flattened match.
  2. Return a pruned sub-pattern instead of an AST, only containing the terms that matched

---

```python
# "The essence of programming is composition"
#    - Bartosz Milewski
#
# An example of how instead of a keyword, `Case` is just a function that takes a list of functions, so its branches are composable.
HandleEq Eq -> DoSomethingWhenEq
HandleGtOrLt (_ : { Gt, Lt }) -> DoSomethingElse

ComposeBranches (ord : Ord) -> Case [
  HandleEq,
  HandleGtOrLt,
] ord
# This will type check because the type of Case is the union of all its function's when matched against its second argument. In this case, that is { Eq } \/ { Gt, Lt }, which is equal to Ord.
```

---

### Left to Right pattern matching evaluation

Patterns should be matched starting from the left most term and greedily
consuming as many submatches as possible. When replaced, matching begins at the
current location, but not before.

```
Foo -> 321
Foo Foo -> 123
Bar -> Foo
Foo Bar -> 456

Foo Foo # select Foo, select its Foo with val 123
Foo Bar # select Foo, select its Bar with val 456
Bar Foo # select Bar, try and fail to match its Foo, then fallback to 123 321
Bar Bar # select Bar, try and fail to match its Bar, then fallback to Bar. select Bar for Bar Bar
```

---

Pattern keys must also contain patterns, otherwise subpatterns (types) aren't possible.
Pattern values must also contain patterns, in other words patterns must be built once during insert, not multiple times each rewrite.

---

Computations should be unions and products (pattern tries) as well, not single or even multiple values.
For example, consider these patterns:
```
And bar -> bar, bar
Or foo -> foo; foo
```
When matching something like `And (Or 123)`, the result should be `123; 123, 123; 123`

---

### Tooling

- Factor `Map` code action, that matches lists where all elements are the same prefix

- To/From other data formats, like JSON


---

Make frequent dynamic arrays/allocations to be optional, by having compile time switches for max token len, max line len, etc. 

---

Maybe add regex-like variables for apps, such as zero-many, one-or-more,
optional, etc? A sufficiently smart compiler might be able to transform operator
patterns into these.

---

New code added is affected by previous code but not vice versa. It does not
change the behavior or meaning of previous code. Example of match patterns being
known by insert time:
```
P1 -> {1,2,3}
x : P1 -> 123
y : P2 -> 456 # Insert error, P2 doesn't evaluate to a pattern.
P2 -> P1 # Alias P2


```
---

Do NOT force pointer's on Keys and Vars. If the user has a large type, they can
make it a pointer.

---

Evaluation must sub-evaluate nested apps recursively greedily i.e.
```
G x -> x
F -> G
F x -> 456
F 123 # Should become 456
(F) 123 # Should become G 123, then 123

```

---

Precedence should minimize parentheis in common use cases. This increases
readability and lowers mental overhead, as well as aids incremental compilation.

```
F : A -> B : C
F -> G : A 
F (x : Int) (y: Int) -> G x y
```

The operator `::` for a match with low precendence is necessary. One case is
when matching on arrows, like:
```
  A -> 1 :: { A -> 1, B, C }
```
Using `(A -> 1) : {...}` instead doesn't work, because the arrow `A -> 1` isn't
a subapp in the pattern. More generally, parenthesis are only a tool to express
nesting structure, not precedence.

The operator `-->` is also probably needed for commas

The operators `=>` and `==>` are probably needed to decrease levels of nesting,
because sometimes 0 is desired. They would make `->` map only to its first
app as a singleton not an array. This might make some precedence operators
redundant.

Two operators for matching are probably necessary too. `*:` maybe?

The operator `...` or `*` is necessary for globbing. Matching using it needs
some kind of substring search algorithm for apps though (but probably not for
patterns). It could be combined like `{*}` to denote the current pattern or
everything in scope.

Single arrow: rewrite to first match, looking back or else self
Double arrow: rewrite to all matches in order looking back or else empty. 

Commas might be better as a way to append instead of separate apps. An append
operator would also be good to enable treating apps of a single pattern as just
a pattern.
```

# Make apps of length 1 map to a singleton 
(x) -> x
# This now evaluates into a basic trie without nesting.
{ 1 -> A, 2 -> B, 3 -> C }
# Make keys of length 1 map to a singleton key
(x) -> y --> x -> y
```

---

### Arrow

On deletion of an arrow, all following entries in the pattern must be replayed
to ensure they are still valid. This synchronizes perfectly with using
references to save memory, as it ensures they are always valid, or else not
re-added.

### Match

A match is of the form `QueryApp : Expr`, where Expr is an Apps or Pattern.

#### Inserting a Match as a key in a Pattern
1. Expr is evaluated in the current pattern context.
2. The evaluated Expr is checked that it is a pattern (if not, the insert fails).
3. The `query -> eval` arrow is inserted into a pattern.
4. The `eval -> next` arrow is inserted. 

#### Evaluating a Match as an expression
1. `QueryApp` is matched against the pre-evaluated expression
2. The number of results are multiplied with the parent match (list monad style). 

---

Add rainbow colors to app and pattern pretty printer
Parse commas the same as newlines for consistency

---

Sifu is a lisp, but the syntax treats everything as a list by default.

---

Syntax is important for any language. The choice between syntax implementations
isn't, but rather the fact that there are multiple possible ones
to begin with for some feature is a possible code smell of that feature.

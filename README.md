# Sifu, A Concatenative Language Based on Tries


### Main Ideas
  
  - Computation is a pattern match

  - A computation returns 0, 1, or many values

  - No turing completeness, everything terminates by matching tags less than (or equal, with other checks) to themselves

  - Core language is just a dynamic pattern-matching/rewrite engine
    - only builtins are triemap entries (tags `=>`) and triemap queries (matches `:`)
    - match / set membership / typeof is the same thing (`:`)
    - files are just triemaps with entries separated by newlines
    - no keywords other than the two builtin ops
    - any characters are valid to the parser (punctuation chars are values, like in Forth)
    - values are literals, i.e. upper-case idents, ints, and match only themselves
    - vars match anything (lower-case idents)

  - Values and Variables
    - variables are just tags `x => 2` and match anything
    - values are as well `Val1 => 2` and are treated as literals (strings are just an escaped value)

  - Types
    - types are just triemaps of values
    - "fields" are just type level tags
    - hashmaps of types can trivially implement row types
    - type checking is just a pattern match

  - Compiler builds on the core language, using it as a library
    - complilation is simply creating perfect hashmaps instead of dynamic ones

## Examples
  ```python
  # Implement some simple types
  Ord => { Gt, Eq, Lt }
  Bool => { True, False }

  # A function `IsEq` that takes an ord, and returns True if it is Eq. `_` is
  # just another var, meant to be unused. 
  IsEq Eq => True
  IsEq _ => False

  # A function that compares bools using Case, a function that takes a list of
  # tags and another arg and applies them against the arg until one matches:
  Compare (b1 : Bool) (b2 : Bool) => Case [
      (True, False) => Gt,
      (False, True) => Lt,
      _ => Eq,
    ] (b1, b2)
  ```

## Roadmap

- ### Core Language
  
  - [x] Parser/Lexer </input>

  - [ ] TrieMap Construction </input>

  - [ ] TrieMap Error handling </input>

  - [ ] TrieMap Matching </input>

- ### Compiler

  - [ ] Basic Stdlib using the Core Language </input>

  - [ ] File Parsing </input>

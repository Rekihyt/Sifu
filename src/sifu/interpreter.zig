const ast = @import("ast.zig");
const Ast = ast.Ast;
const Span = ast.Span;
const Term = ast.Term;
const Lit = ast.Lit;
const Pattern = @import("../pattern.zig").Pattern(
    Term,
    []const u8,
    Ast,
    ?Span,
);

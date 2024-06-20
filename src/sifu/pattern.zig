const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const syntax = @import("syntax.zig");
const Token = syntax.Token(usize);
// pub const Pattern = Ast.Pat;

// / Parse a triemap pattern.
// fn astToPattern(allocator: Allocator, asts: []const Ast) !Pattern {
//     _ = allocator;

//     for (asts) |ast| {
//         _ = ast;
//     }
// }

// / This function is responsible for converting an AST into a Pattern. Sifu's
// / builtin operators determine how this happens.
// / Input - any Ast
// / Output - a map pattern representing a trie.
// pub fn pattern(allocator: Allocator, ast: Ast) !Pattern {
//     return switch (ast) {
//         .apps => |apps| astToPattern(allocator, apps),
//         .token => |token| Pattern{ .lit = token },
//     };
// }

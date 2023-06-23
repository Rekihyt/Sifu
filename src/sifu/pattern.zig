const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const debug = std.debug;
const Ast = @import("ast.zig").Ast(Token);
const syntax = @import("syntax.zig");
const Token = syntax.Token(Location);
const Location = syntax.Location;
const Oom = Allocator.Error;
const Pattern = @import("../pattern.zig")
    .Pattern([]const u8, []const u8, Ast);

/// Parse a triemap pattern.
fn astToPattern(allocator: Allocator, asts: []const Ast) Oom!Pattern {
    _ = allocator;

    for (asts) |ast| {
        _ = ast;
    }
}

/// This function is responsible for converting an AST into a Pattern. Sifu's
/// builtin operators determine how this happens.
/// Input - any Ast
/// Output - a map pattern representing a trie.
pub fn pattern(allocator: Allocator, ast: Ast) Oom!Pattern {
    return switch (ast) {
        .apps => |apps| astToPattern(allocator, apps),
        .token => |token| Pattern{ .lit = token },
    };
}

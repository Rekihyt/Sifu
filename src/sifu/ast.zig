const std = @import("std");
const testing = std.testing;
const syntax = @import("syntax.zig");
const util = @import("../util.zig");
// Store the position of the token in the source as a usize
const Token = syntax.Token(usize);
const Term = syntax.Term;
const Type = syntax.Type;
const Wyhash = std.hash.Wyhash;
const mem = std.mem;
const StringContext = std.array_hash_map.StringContext;

/// The Sifu-specific interpreter Ast, using Tokens as keys and strings as
/// values.
pub const Ast = Pat.Node;
pub const Pat = @import("../pattern.zig").PatternWithContext(
    Token,
    []const u8,
    util.IntoArrayContext(Token),
    StringContext,
);

test "simple ast to pattern" {
    const term = Token{
        .type = .Name,
        .lit = "My-Token",
        .context = 0,
    };
    _ = term;
    const ast = Ast{
        .key = .{
            .type = .Name,
            .lit = "Some-Other-Token",
            .context = 20,
        },
    };
    _ = ast;
    // _ = Pattern.ofTokenType(term, ast);
}

test "Token equality" {
    const t1 = Token{
        .type = .Name,
        .lit = "Asdf",
        .context = 0,
    };
    const t2 = Token{
        .type = .Name,
        .lit = "Asdf",
        .context = 1,
    };

    try testing.expect(t1.eql(t2));
    try testing.expectEqual(t1.hash(), t2.hash());
}

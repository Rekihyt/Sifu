const std = @import("std");
const testing = std.testing;
const syntax = @import("syntax.zig");
const Location = syntax.Location;
const Token = syntax.Token(Location);
const Term = syntax.Term;
const Type = syntax.Type;
pub const Ast = @import("../ast.zig").Ast(
    Token,
    []const u8,
    null,
);

test "simple ast to pattern" {
    const term = Token{
        .type = .Val,
        .lit = "My-Token",
        .context = .{ .uri = null, .pos = 0 },
    };
    _ = term;
    const ast = Ast{
        .key = .{
            .type = .Val,
            .lit = "Some-Other-Token",
            .context = .{ .uri = null, .pos = 20 },
        },
    };
    _ = ast;
    // _ = Pattern.ofTokenType(term, ast);
}

const std = @import("std");
const testing = std.testing;
const Ast = @import("sifu/ast.zig").Ast;
const syntax = @import("sifu/syntax.zig");
const Location = syntax.Location;
const Token = syntax.Token(Location);
const Term = syntax.Term;
const Type = syntax.Type;

test "Submodules" {
    _ = @import("sifu.zig");
    _ = @import("util.zig");
    _ = @import("pattern.zig");
}

test "equal strings with different pointers or pos should be equal" {
    const str1 = "abc";
    const str2 = try testing.allocator.dupe(u8, str1);
    defer testing.allocator.free(str2);

    const term1 = Token{
        .type = .Val,
        .lit = "Some-Val",
        .context = Location{ .pos = 0, .uri = null },
    };
    const term2 = Token{
        .type = .Val,
        .lit = "Some-Val",
        .context = Location{ .pos = 1, .uri = null },
    };

    try testing.expect(term1.eql(term2));
}

test "equal strings with different values should not be equal" {
    const str1 = "abc";
    const str2 = try testing.allocator.dupe(u8, str1);
    defer testing.allocator.free(str2);

    const term1 = Token{
        .type = .Val,
        .lit = "Term1",
        .context = Location{ .pos = 0, .uri = null },
    };
    const term2 = Token{
        .type = .Val,
        .lit = "Term2",
        .context = Location{ .pos = 0, .uri = null },
    };

    try testing.expect(!term1.eql(term2));
}

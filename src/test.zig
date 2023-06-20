const std = @import("std");
const testing = std.testing;
const ast = @import("sifu/ast.zig");
const Token = ast.Token;
const Location = ast.Location;

test "Submodules" {
    _ = @import("sifu.zig");
    _ = @import("util.zig");
    _ = @import("pattern.zig");
}

test "equal strings with different pointers or pos should be equal" {
    const str1 = "abc";
    const str2 = try testing.allocator.dupe(u8, str1);
    defer testing.allocator.free(str2);

    const term1 = Token(Location){
        .type = .Val,
        .lit = "Some-Val",
        .context = Location{ .pos = 0, .uri = null },
    };
    const term2 = Token(Location){
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

    const term1 = Token(Location){
        .type = .Val,
        .lit = "Term1",
        .context = Location{ .pos = 0, .uri = null },
    };
    const term2 = Token(Location){
        .type = .Val,
        .lit = "Term2",
        .context = Location{ .pos = 0, .uri = null },
    };

    try testing.expect(!term1.eql(term2));
}

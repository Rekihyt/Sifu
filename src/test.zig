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

test "equal strings with different pointers, len, or pos should be equal" {
    const str1 = "abc";
    const str2 = try testing.allocator.dupe(u8, str1);
    defer testing.allocator.free(str2);

    const term1 = Token(Location){
        .lit = .val,
        .context = Location{ .len = 0, .pos = 0 },
    };
    const term2 = Token(Location){
        .lit = .val,
        .context = Location{ .len = 1, .pos = 1 },
    };

    try testing.expect(term1.eql(term2));
}

test "equal strings with different kinds should not be equal" {
    const str1 = "abc";
    const str2 = try testing.allocator.dupe(u8, str1);
    defer testing.allocator.free(str2);

    const term1 = Token(Location){
        .lit = .val,
        .context = Location{ .len = 0, .pos = 0 },
    };
    const term2 = Token(Location){
        .lit = .val,
        .context = Location{ .len = 0, .pos = 0 },
    };

    try testing.expect(!term1.eql(term2));
}

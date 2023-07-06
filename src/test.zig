const std = @import("std");
const testing = std.testing;
const Ast = @import("sifu/ast.zig").Ast(Token);
const syntax = @import("sifu/syntax.zig");
const Location = syntax.Location;
const Token = syntax.Token(Location);
const Term = syntax.Term;
const Type = syntax.Type;
const ArenaAllocator = std.heap.ArenaAllocator;
const Lexer = @import("sifu/lexer.zig");
const parse = @import("sifu/parser.zig").parse;
const Pattern = Ast.Pattern;

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
        .lit = str1,
        .context = Location{ .pos = 0, .uri = null },
    };
    const term2 = Token{
        .type = .Val,
        .lit = str2,
        .context = Location{ .pos = 1, .uri = null },
    };

    try testing.expect(term1.eql(term2));
}

test "equal contexts with different values should not be equal" {
    const term1 = Token{
        .type = .Val,
        .lit = "Foo",
        .context = Location{ .pos = 0, .uri = null },
    };
    const term2 = Token{
        .type = .Val,
        .lit = "Bar",
        .context = Location{ .pos = 0, .uri = null },
    };

    try testing.expect(!term1.eql(term2));
}

test "Pattern: simple vals" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var lexer = Lexer.init("Aa Bb Cc \n\n 123");

    const key = (try parse(allocator, &lexer)).?.apps;
    const val = (try parse(allocator, &lexer)).?.apps;
    var actual = Pattern{};
    const updated = try Ast.insert(key, allocator, actual, val);
    _ = updated;
    var expected = Pattern{};
    var expected_a = Pattern{};
    var expected_b = Pattern{};
    var expected_c = Pattern{
        .val = val,
    };
    try expected.map.put(allocator, "Aa", expected_a);
    try expected_a.map.put(allocator, "Bb", expected_b);
    try expected_b.map.put(allocator, "Cc", expected_c);
    // std.debug.print("{?}\n", .{expected});
    // std.debug.print("{?}\n", .{actual});
    try testing.expect(expected.eql(expected));

    try testing.expect(!expected_a.eql(expected_b));
    try testing.expect(!expected.eql(expected_c));
    try testing.expect(!expected.eql(expected_a));

    std.debug.print(" \n", .{});
    debugPattern("", expected, 0);
    debugPattern("Aa", expected_a, 0);
    debugPattern("", actual, 0);

    try testing.expect(expected.eql(actual));
}

fn debugPattern(key: []const u8, pattern: Pattern, indent: usize) void {
    for (0..indent) |_|
        std.debug.print(" ", .{});

    if (pattern.val) |val| {
        std.debug.print("{s} |", .{key});
        for (val) |ast|
            std.debug.print("{s}, ", .{ast.token.lit});

        std.debug.print("| -> {s}\n", .{"{"});
    } else std.debug.print("{s} -> {s}\n", .{ key, "{" });

    for (pattern.map.keys(), pattern.map.values()) |next_key, next| {
        debugPattern(next_key, next, indent + 4);
    }
    for (0..indent) |_|
        std.debug.print(" ", .{});

    std.debug.print("{s}\n", .{"}"});
}

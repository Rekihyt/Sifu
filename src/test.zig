const std = @import("std");
const testing = std.testing;
const Ast = @import("sifu/ast.zig").Ast;
const syntax = @import("sifu/syntax.zig");
const Location = syntax.Location;
const Token = syntax.Token(Location);
const Term = syntax.Term;
const Type = syntax.Type;
const ArenaAllocator = std.heap.ArenaAllocator;
const fs = std.fs;
const Lexer = @import("sifu/Lexer.zig");
const parse = @import("sifu/parser.zig").parse;
const Pattern = Ast.Pat;
const io = std.io;
const print = std.debug.print;

// for debugging with zig test --test-filter, comment this import
const verbose_tests = @import("build_options").verbose_tests;
// const stderr = if (true)
const stderr = if (verbose_tests)
    std.io.getStdErr().writer()
else
    std.io.null_writer;

test "Submodules" {
    _ = @import("sifu.zig");
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
    var fbs = io.fixedBufferStream("Aa Bb Cc \n\n 123");
    var reader = fbs.reader();
    var lexer = Lexer.init(allocator);

    const key = (try parse(allocator, &lexer, reader)).?.apps;
    _ = key;
    var val = (try parse(allocator, &lexer, reader)).?;
    var actual = Pattern{};
    // TODO: match patterns instead
    // const updated = try Ast.insert(key, allocator, &actual, val);
    var expected = Pattern{};
    var expected_a = Pattern{};
    var expected_b = Pattern{};
    var expected_c = Pattern{
        .val = &val,
    };
    // Reverse order because patterns are values, not references
    try expected_b.map.put(allocator, "Cc", expected_c);
    try expected_a.map.put(allocator, "Bb", expected_b);
    try expected.map.put(allocator, "Aa", expected_a);
    try testing.expect(expected.eql(expected));

    try testing.expect(!expected_b.eql(expected_a));
    try testing.expect(!expected_a.eql(expected_b));
    try testing.expect(!expected.eql(expected_c));
    try testing.expect(!expected.eql(expected_a));

    try testing.expect(expected.eql(actual));

    // TODO: match patterns instead
    // try testing.expectEqual(
    //     @as(?*const Ast, val),
    //     try Ast.match(key, allocator, actual),
    // );
    // try testing.expectEqual(
    //     @as(?*const Ast, null),
    //     try Ast.match(key, allocator, expected_c),
    // );

    // Test branching
    fbs = io.fixedBufferStream("Aa Bb2 \n\n 456");
    var lexer2 = Lexer.init(allocator);
    reader = fbs.reader();
    const key2 = (try parse(allocator, &lexer2, reader)).?.apps;
    const val2 = &(try parse(allocator, &lexer2, reader)).?;
    try expected.map.getPtr("Aa").?
        .map.put(allocator, "Bb2", Pattern{ .val = val2 });
    _ = try Ast.insert(key2, allocator, &actual, val2);

    try testing.expect(expected.eql(actual));
    try testing.expectEqual(
        @as(?*const Ast, val2),
        try Ast.match(key2, allocator, actual),
    );
    try stderr.print(" \n", .{});
    try expected.print(stderr);
    try actual.print(stderr);
}

const std = @import("std");
const testing = std.testing;
const Pat = @import("sifu/ast.zig").Pat;
const Ast = Pat.Node;
const syntax = @import("sifu/syntax.zig");
const Token = syntax.Token(usize);
const Term = syntax.Term;
const Type = syntax.Type;
const ArenaAllocator = std.heap.ArenaAllocator;
const fs = std.fs;
const Lexer = @import("sifu/Lexer.zig");
const parse = @import("sifu/parser.zig").parse;
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
        .context = 0,
    };
    const term2 = Token{
        .type = .Val,
        .lit = str2,
        .context = 1,
    };

    try testing.expect(term1.eql(term2));
}

test "equal contexts with different values should not be equal" {
    const term1 = Token{
        .type = .Val,
        .lit = "Foo",
        .context = 0,
    };
    const term2 = Token{
        .type = .Val,
        .lit = "Bar",
        .context = 0,
    };

    try testing.expect(!term1.eql(term2));
}

test "Pattern: simple vals" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fbs = io.fixedBufferStream("Aa Bb Cc -> 123");
    var reader = fbs.reader();
    var lexer = Lexer.init(allocator);

    const ast = (try parse(allocator, &lexer, reader)).?;
    const key = ast.apps[1];
    var node = ast.apps[2];
    var actual = Pat{};
    // TODO: match patterns instead
    // const updated = try Ast.insert(key, allocator, &actual, node);
    var expected = Pat{};
    var expected_a = Pat{};
    var expected_b = Pat{};
    var expected_c = Pat{
        .node = &node,
    };
    const token_aa = Token{ .lit = "Aa", .type = .Val, .context = 0 };
    const token_bb = Token{ .lit = "Bb", .type = .Val, .context = 3 };
    const token_bb2 = Token{ .lit = "Bb2", .type = .Val, .context = 123 };
    const token_cc = Token{ .lit = "Cc", .type = .Val, .context = 6 };

    // Reverse order because patterns are values, not references
    try expected_b.map.put(
        allocator,
        token_cc,
        expected_c,
    );
    try expected_a.map.put(
        allocator,
        token_bb,
        expected_b,
    );
    try expected.map.put(
        allocator,
        token_aa,
        expected_a,
    );
    try testing.expect(expected.eql(expected));

    try testing.expect(!expected_b.eql(expected_a));
    try testing.expect(!expected_a.eql(expected_b));
    try testing.expect(!expected.eql(expected_c));
    try testing.expect(!expected.eql(expected_a));

    try testing.expect(!expected.eql(actual));
    _ = try actual.insert(allocator, key.apps, &node);
    try testing.expect(expected.eql(actual));

    // TODO: match patterns instead
    // try testing.expectEqual(
    //     @as(?*const Ast, node),
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
    const key2 = (try parse(allocator, &lexer2, reader)).?;
    var node2 = (try parse(allocator, &lexer2, reader)).?;
    try expected.map.getPtr(token_aa).?
        .map.put(allocator, token_bb2, Pat{ .node = &node2 });

    try testing.expect(!expected.eql(actual));
    _ = try actual.insert(allocator, key2.apps, &node2);

    try testing.expect(expected.eql(actual));
    // TODO: convert matchPrefix to match
    // try testing.expectEqual(
    // node2,
    // try actual.matchPrefix(allocator, key2),
    // );
    try stderr.print(" \n", .{});

    try expected.write(stderr);
    try actual.write(stderr);
}

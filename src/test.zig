const std = @import("std");
const testing = std.testing;
const syntax = @import("sifu/syntax.zig");
const Token = syntax.Token(usize);
const Term = syntax.Term;
const Type = syntax.Type;
const Trie = @import("sifu/trie.zig").Trie;
const Node = Trie.Node;
const Pattern = Trie.Pattern;
const ArenaAllocator = std.heap.ArenaAllocator;
const Lexer = @import("sifu/Lexer.zig")
    .Lexer(io.FixedBufferStream([]const u8).Reader);
const parse = @import("sifu/parser.zig").parse;
const io = std.io;
const util = @import("util.zig");
const print = util.print;
const err_stream = util.err_stream;

test "Submodules" {
    _ = @import("sifu.zig");
}

test "equal strings with different pointers or pos should be equal" {
    const str1 = "abc";
    const str2 = try testing.allocator.dupe(u8, str1);
    defer testing.allocator.free(str2);

    const term1 = Token{
        .type = .Name,
        .lit = str1,
        .context = 0,
    };
    const term2 = Token{
        .type = .Name,
        .lit = str2,
        .context = 1,
    };

    try testing.expect(term1.eql(term2));
}

test "equal contexts with different values should not be equal" {
    const term1 = Token{
        .type = .Name,
        .lit = "Foo",
        .context = 0,
    };
    const term2 = Token{
        .type = .Name,
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
    var lexer = Lexer.init(allocator, fbs.reader());

    const ast = try parse(allocator, &lexer);
    const key = ast.arrow.from;
    var val = try Node.createPattern(allocator, ast.arrow.into);
    var actual = Trie{};
    // TODO: match tries instead
    // const updated = try Node.insert(key, allocator, &actual, val);
    var expected = Trie{};
    var expected_a = Trie{};
    var expected_b = Trie{};
    const expected_c = Trie{
        .val = val,
    };
    const token_aa = Token{ .lit = "Aa", .type = .Name, .context = 0 };
    const token_bb = Token{ .lit = "Bb", .type = .Name, .context = 3 };
    const token_bb2 = Token{ .lit = "Bb2", .type = .Name, .context = 123 };
    const token_cc = Token{ .lit = "Cc", .type = .Name, .context = 6 };

    // Reverse order because tries are values, not references
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
    _ = try actual.insertPattern(allocator, key, val.*);
    try expected.write(err_stream);
    try err_stream.writeByte('\n');
    try actual.write(err_stream);
    try err_stream.writeByte('\n');
    try testing.expect(expected.eql(actual));

    // TODO: match tries instead
    // try testing.expectEqual(
    //     @as(?*const Node, val),
    //     try Node.match(key, allocator, actual),
    // );
    // try testing.expectEqual(
    //     @as(?*const Node, null),
    //     try Node.match(key, allocator, expected_c),
    // );

    // Test branching
    fbs = io.fixedBufferStream("Aa Bb2 \n\n 456");
    var lexer2 = Lexer.init(allocator, fbs.reader());
    const key2 = try parse(allocator, &lexer2);
    var val2 = try parse(allocator, &lexer2);
    try expected.map.getPtr(token_aa).?
        .map.put(
        allocator,
        token_bb2,
        Trie{ .val = &val2 },
    );

    try testing.expect(!expected.eql(actual));
    _ = try actual.insert(allocator, key2, val2);

    try testing.expect(expected.eql(actual));

    try testing.expect(val.eql(actual.matchUniquePattern(key).?.*));
    try testing.expect(val2.eql(actual.matchUnique(key2).?.*.val.?.*));
    try testing.expectEqual(@as(?*Trie.Node, null), actual.matchUniquePattern(key[0..1]));
    try testing.expectEqual(@as(?*Trie.Node, null), actual.matchUniquePattern(key2.pattern[0..1]));
    try expected.write(err_stream);
    try actual.write(err_stream);
}

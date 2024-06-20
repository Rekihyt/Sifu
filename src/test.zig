const std = @import("std");
const testing = std.testing;
const Pat = @import("sifu/ast.zig").Pat;
const Ast = Pat.Node;
const syntax = @import("sifu/syntax.zig");
const Token = syntax.Token(usize);
const Term = syntax.Term;
const Type = syntax.Type;
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
    var val = try Ast.createApps(allocator, ast.arrow.into);
    var actual = Pat{};
    // TODO: match patterns instead
    // const updated = try Ast.insert(key, allocator, &actual, val);
    var expected = Pat{};
    var expected_a = Pat{};
    var expected_b = Pat{};
    const expected_c = Pat{
        .val = val,
    };
    const token_aa = Token{ .lit = "Aa", .type = .Name, .context = 0 };
    const token_bb = Token{ .lit = "Bb", .type = .Name, .context = 3 };
    const token_bb2 = Token{ .lit = "Bb2", .type = .Name, .context = 123 };
    const token_cc = Token{ .lit = "Cc", .type = .Name, .context = 6 };

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
    _ = try actual.insertApps(allocator, key, val.*);
    try expected.write(err_stream);
    try err_stream.writeByte('\n');
    try actual.write(err_stream);
    try err_stream.writeByte('\n');
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
    var lexer2 = Lexer.init(allocator, fbs.reader());
    const key2 = try parse(allocator, &lexer2);
    var val2 = try parse(allocator, &lexer2);
    try expected.map.getPtr(token_aa).?
        .map.put(
        allocator,
        token_bb2,
        Pat{ .val = &val2 },
    );

    try testing.expect(!expected.eql(actual));
    _ = try actual.insert(allocator, key2, val2);

    try testing.expect(expected.eql(actual));

    try testing.expect(val.eql(actual.matchUniqueApps(key).?.*));
    try testing.expect(val2.eql(actual.matchUnique(key2).?.*.val.?.*));
    try testing.expectEqual(@as(?*Pat.Node, null), actual.matchUniqueApps(key[0..1]));
    try testing.expectEqual(@as(?*Pat.Node, null), actual.matchUniqueApps(key2.apps[0..1]));
    try expected.write(err_stream);
    try actual.write(err_stream);
}

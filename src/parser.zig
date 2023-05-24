const std = @import("std");
const mem = std.mem;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;
const Lexer = @import("lexer.zig");
const Token = @import("token.zig");
const Ast = @import("ast.zig").Ast;

/// Parse all tokens in the string `source`.
pub fn parse(allocator: Allocator, source: []const u8) !*Ast {
    var lexer = Lexer.init(source);
    _ = lexer;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const x = try Ast.create(allocator, Ast.Kind{ .val = "val1" });
    errdefer x.destroy(allocator);
    // var root = Ast.createApps(
    //     allocator,
    // );
    // errdefer root.deinit();

    // while (lexer.next()) |token| {
    // try root.append(
    //     switch (token.token_type) {
    //         else => Ast{
    //             .token = token,
    //             .kind = Ast.Kind{
    //                 .comment = try allocator.dupe(u8, token.str),
    //             },
    //         },
    //     },
    // );
    // try Asts.append(parser.parseComment(next));
    // }
    return x;
    // return root.toOwnedSlice();
}

/// Like the lexer, the parser tries to make as few decisions as possible.
/// All tokens are accepted. Tokens like unclosed parenthesis are valid, as
/// are operators missing any operands. These errors will be handled right
/// after parsing, during the trie forming stage. The top-level construct is
/// an a list of nodes separated by newlines, whose elements will be entries
/// into a trie in the next phase.
pub const Parser = struct {
    /// Lexer that tokenized all tokens and is used to retrieve the next token
    lexer: Lexer,

    // / Parses the current token into an integer literal Ast
    // fn parseIntLit(self: *Parser) Ast {
    //     const literal = try self.allocator.create(Ast.IntLit);
    //     const string_number = self.source[self.current.start..self.current.end];
    //     const value = try std.fmt.parseInt(usize, string_number, 10);

    //     literal.* = .{ .token = self.current, .value = value };
    //     return Ast{ .int_lit = literal };
    // }
};

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualSlices = testing.expectEqualSlices;

test "memory" {
    const asts = try parse(testing.allocator, "Asd");
    defer asts.destroy(testing.allocator);
}

test "Parse val" {
    const input = "FooBar";

    const ast = try parse(testing.allocator, input);
    errdefer testing.allocator.free(ast);

    try expect(ast.len == 1);

    try expect(ast[0].token.token_type == .val);
    try expectEqualSlices(u8, ast[0].kind.val, input);
}

// test "Parse integer literal" {
//     const input = "124";
//     const tree = try parse(testing.allocator, input);
//     defer tree.deinit();

//     try expect(tree.Asts.len == 1);
//     const literal = tree.Asts[0].expression.value.int_lit;
//     try expect(literal.token.token_type == .integer);
//     try expect(literal.value == 124);
// }

// test "Parse infix expressions - identifier" {
//     const input = "foobar + foobarz";
//     const tree = try parse(testing.allocator, input);
//     defer tree.deinit();

//     try expect(tree.Asts.len == 1);
//     try expectEqualSlices(u8, "foobar", infix.left.identifier.value);
//     try expectEqualSlices(u8, "foobarz", infix.right.identifier.value);
//     try expect(infix.operator == .add);
// }

// test "String expression" {
//     const input = "\"Hello, world\"";

//     const tree = try parse(testing.allocator, input);
//     defer tree.deinit();

//     try expect(tree.Asts.len == 1);

//     const string = tree.Asts[0].expression.value.string_lit;
//     try expectEqualSlices(u8, "Hello, world", string.value);
// }

// test "Comment expression" {
//     const input = "//This is a comment";

//     const tree = try parse(testing.allocator, input);
//     defer tree.deinit();

//     try expect(tree.Asts.len == 1);

//     const comment = tree.Asts[0].comment;
//     try testing.expectEqualStrings("This is a comment", comment.value);
// }

/// The parser for Sifu tries to make as few decisions as possible. Mostly,
/// it greedily lexes seperators like commas into their own ast nodes,
/// separates vars and vals based on the first character's case, and lexes
/// numbers. There are no errors, any utf-8 text is parsable.
///
// Simple syntax enables lexing and parsing at the same time. Parsing begins
// with a new `App` ast node. Each term is lexed, parsed into a `Token`, then added
// to the top-level `Ast`.
// Pattern construction happens after this, as does error reporting on invalid
// asts.
//
const Parser = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const panic = std.debug.panic;
const util = @import("../util.zig");
const fsize = fsize;
const ast = @import("ast.zig");
const Location = ast.Location;
const Lit = ast.Lit;
const Ast = ast.Ast(Location);
const Token = ast.Token(Location);
const Set = util.Set;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const ArrayList = std.ArrayList;
const Oom = Allocator.Error;
const Order = std.math.Order;
const mem = std.mem;
const math = std.math;
const Pattern = @import("../pattern.zig")
    .Pattern(Token(Location), []const u8, Ast(Location));
const Lexer = @import("lexer.zig");

/// The allocator for each pattern
arena: ArenaAllocator,

lexer: Lexer,

/// Creates a new parser using the given source code
pub fn init(allocator: Allocator, lexer: Lexer) Parser {
    var arena = ArenaAllocator.init(allocator);
    return Parser{
        .arena = arena,
        .lexer = lexer,
    };
}

pub fn deinit(self: *Parser) void {
    self.arena.deinit();
}

/// This function is responsible for actually giving meaning to the AST
/// by converting it into a Pattern. Sifu builtin operators change how
/// this happens.
/// Input - an Ast of apps parsed by the function in `Parser`. These
/// should have placed infix operators correctly by nesting them into
/// apps.
/// Output - a map pattern representing the file as a trie.
fn pattern(self: *Parser) Oom!?Pattern {
    // return try self.arena.allocator().dupe(u8, self.source[pos..self.pos]);

    // return if (std.fmt.parseUnsigned(usize, self.source[pos..self.pos], 10)) |i|
    //     i
    // else |err| switch (err) {
    //     error.InvalidCharacter => unreachable, // we only consumed digits
    //     else => |e| e, // recapture to narrow the error type
    // };

    // return try std.fmt.parseFloat(fsize, self.source[pos..self.pos], 10) catch
    //     unreachable; // we only consumed digits, and maybe one decimal point
    _ = self;
}

/// Returns the next token but does not increase the Parser's position, or
/// returns null if there are no more characters left to .
// fn peek(self: Parser) ?u8 {
//     return if (self.pos < self.source.len)
//         self.source[self.pos]
//     else
//         null;
// }

/// Advances one token, or panics (should only be called after `peek`)
// fn consume(self: *Parser) void {
//     if (self.peek()) |char| {
//         self.pos += 1;
//         switch (char) {
//             '\n' => {
//                 self.col = 1;
//                 self.line += 1;
//             },
//             else => self.col += 1,
//         }
//     } else @panic("Attempted to advance to next Ast but EOF reached");
// }

const testing = std.testing;
const meta = std.meta;
const verbose_tests = @import("build_options").verbose_tests;
const stderr = if (verbose_tests)
    std.io.getStdErr().writer()
else
    std.io.null_writer;

fn expectEqualApps(expected: Ast, actual: Ast) !void {
    try stderr.writeByte('\n');
    try testing.expect(.apps == expected);
    try testing.expect(.apps == actual);

    // This is redundant, but it makes any failures easier to trace
    for (expected.apps, actual.apps) |expected_elem, actual_elem| {
        try expected_elem.print(stderr);
        try stderr.writeByte('\n');

        try actual_elem.print(stderr);
        try stderr.writeByte('\n');

        if (@enumToInt(expected_elem) == @enumToInt(actual_elem)) {
            switch (expected_elem) {
                .token => |token| {
                    try testing.expectEqual(
                        @as(Order, .eq),
                        token.order(actual_elem.token),
                    );
                    try testing.expectEqualDeep(
                        token.term,
                        actual_elem.token.term,
                    );
                },
                .apps => try expectEqualApps(expected_elem, actual_elem),
            }
        } else {
            try stderr.writeAll("Asts of different types not equal");
            try testing.expectEqual(expected_elem, actual_elem);
            // above line should always fail
            std.debug.panic(
                "Asserted asts were equal despite different types",
                .{},
            );
        }
    }
    // Variants of this seem to cause the compiler to error with GenericPoison
    // try testing.expectEqual(@as(Order, .eq), expected.order(actual));
}

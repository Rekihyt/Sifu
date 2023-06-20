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
    .Pattern(Token, []const u8, Ast);
const Lexer = @import("lexer.zig");

/// The allocator for each pattern
arena: ArenaAllocator,

lexer: Lexer,

/// Creates a new parser using the given source code.
/// Allocates pointers to memory owned by the lexer, but does not modify it.
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

/// Parse a triemap pattern.
pub fn parseMap(self: *Parser) Oom!?Pattern {
    _ = self;
}

pub fn parseVar(self: *Parser) Oom!?Pattern {
    _ = self;
}

pub fn parseMatch(self: *Parser) Oom!?Pattern {
    _ = self;
}

pub fn parseApps(self: *Parser) Oom!?Pattern {
    _ = self;
}

/// This function is responsible for actually giving meaning to the AST
/// by converting it into a Pattern. Sifu builtin operators change how
/// this happens.
/// Input - any Ast
/// Output - a map pattern representing the file as a trie.
pub fn parsePattern(self: *Parser) Oom!?Pattern {
    // return try self.arena.allocator().dupe(u8, self.source[pos..self.pos]);

    // return if (std.fmt.parseUnsigned(usize, self.source[pos..self.pos], 10)) |i|
    //     i
    // else |err| switch (err) {
    //     error.InvalidCharacter => unreachable, // we only consumed digits
    //     else => |e| e, // recapture to narrow the error type
    // };

    // return try std.fmt.parseFloat(fsize, self.source[pos..self.pos], 10) catch
    //     unreachable; // we only consumed digits, and maybe one decimal point
    if (try self.lexer.nextToken()) |token| {
        const lit = token.lit;
        _ = lit;
        switch (token.type) {
            else => {},
        }
    }
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

test "simple val" {
    var lexer = Lexer.init(testing.allocator, "Asdf");
    defer lexer.deinit();

    var parser = Parser.init(testing.allocator, lexer);
    defer parser.deinit();

    const pattern = (try parser.parsePattern()).?;
    try testing.expectEqualStrings(pattern.kind.lit.lit, "Asdf");
}

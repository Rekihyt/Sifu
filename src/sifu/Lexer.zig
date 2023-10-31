/// The lexer for Sifu tries to make as few decisions as possible. Mostly,
/// it greedily lexes seperators like commas into their own ast nodes,
/// separates vars and vals based on the first character's case, and lexes
/// numbers. There are no errors, any utf-8 text is parsable.

// Parsing begins with a new `App` ast node. Each term is lexed, parsed into
// a `Token`, then added  to the top-level `Ast`. Pattern construction happens
// after this, as does error reporting on invalid asts.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const panic = std.debug.panic;
const util = @import("../util.zig");
const fsize = fsize;
const pattern = @import("pattern.zig");
const Ast = pattern.AstType;
const Lit = Ast.Lit;
const syntax = @import("syntax.zig");
const Token = syntax.Token(usize);
const Term = syntax.Term;
const Type = syntax.Type;
const Set = util.Set;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const ArrayList = std.ArrayList;
const Order = std.math.Order;
const mem = std.mem;
const math = std.math;
const assert = std.debug.assert;
const debug = std.debug;

pub fn Lexer(comptime Reader: type) type {
    return struct {
        /// A element buffer to hold chars for the current token
        buff: ArrayListUnmanaged(u8) = .{},
        /// The position in the stream used as context
        pos: usize = 0,
        /// Current line in the source
        line: usize = 0,
        /// Current column in the source
        col: usize = 1,
        /// Current token being parsed in the source
        token: ?Token = null,
        /// A single element buffer to hold a char for `peekChar`
        char: ?u8 = null,
        /// The allocator used for tokenizing
        allocator: Allocator,
        /// The reader providing input
        reader: Reader,

        pub const Self = @This();

        /// Creates a new lexer using the given allocator
        pub fn init(allocator: Allocator, reader: Reader) Self {
            return .{ .allocator = allocator, .reader = reader };
        }

        pub fn peek(
            self: *Self,
        ) !?Token {
            if (self.token == null)
                self.token = try self.next();

            return self.token;
        }

        pub fn next(
            self: *Self,
        ) !?Token {
            // Return the current token, if it exists
            if (self.token) |token| {
                defer self.token = null;
                return token;
            }
            try self.skipSpace();
            const char = try self.peekChar() orelse
                return null;

            const pos = self.pos;
            try self.consume(); // tokens always have at least 1 char
            // Parse separators greedily. These can be vals or infixes, it
            // doesn't matter.
            const token_type: Type = switch (char) {
                '\n' => .NewLine,
                // ',' => .NewLine, // Treat Escape as "continue on newline"
                '+', '-' => if (try self.peekChar()) |next_char|
                    if (isDigit(next_char))
                        try self.integer()
                    else
                        try self.infix()
                else
                    .Infix,
                '#' => try self.comment(),
                else => if (isSep(char))
                    .Val
                else if (isInfix(char))
                    try self.infix()
                else if (isUpper(char) or char == '@')
                    try self.value()
                else if (isLower(char) or char == '_' or char == '$')
                    try self.variable()
                else if (isDigit(char))
                    try self.integer()
                else if (char == 0xAA)
                    panic("Buffer Overflow debug char (0xAA) consumed\n", .{})
                else
                    // This is a debug error only, as we shouldn't encounter an error
                    // during lexing
                    panic(
                        \\Lexer Bug: Unknown character '{c}' (0x{X}) at line {}, col {}.
                        \\Note: Unicode not supported yet.
                    , .{ char, char, self.line, self.col }),
            };
            // defer self.buff = .{};
            return Token{
                .type = token_type,
                .lit = try self.buff.toOwnedSlice(self.allocator),
                .context = pos,
            };
        }

        /// Returns the next character but does not increase the Lexer's position, or
        /// returns null if there are no more characters left.
        fn peekChar(self: *Self) !?u8 {
            if (self.char == null)
                self.char = self.reader.readByte() catch |e| switch (e) {
                    error.EndOfStream => return null,
                    else => return e,
                };

            return self.char;
        }

        /// Advances one character, reading it into the current token list buff.
        fn consume(self: *Self) !void {
            const char = try self.nextChar();
            try self.buff.append(self.allocator, char);
        }

        /// Advances one character, or panics (should only be called after `peekChar`)
        fn nextChar(self: *Self) !u8 {
            const char = if (self.char) |char|
                char
            else
                try self.peekChar() orelse panic(
                    "Lexer Bug: Attempted to advance to next AST but EOF reached.",
                    .{},
                );
            self.char = null; // clear peek buffer
            self.pos += 1;
            if (char == '\n') {
                self.col = 1;
                self.line += 1;
            } else self.col += 1;

            return char;
        }

        /// Skips whitespace except for newlines until a non-whitespace character is
        /// found. Not guaranteed to skip anything. Newlines are separators, and thus
        /// treated as tokens.
        fn skipSpace(self: *Self) !void {
            while (try self.peekChar()) |char|
                switch (char) {
                    ' ', '\t', '\r' => _ = try self.nextChar(),
                    else => break,
                };
        }

        fn nextIdent(self: *Self) !void {
            while (try self.peekChar()) |next_char|
                if (isIdent(next_char))
                    try self.consume()
                else
                    break;
        }

        fn value(self: *Self) !Type {
            try self.nextIdent();
            return .Val;
        }

        fn variable(self: *Self) !Type {
            try self.nextIdent();
            return .Var;
        }

        /// Reads the next infix characters
        fn infix(self: *Self) !Type {
            while (try self.peekChar()) |next_char|
                if (isInfix(next_char))
                    try self.consume()
                else
                    break;

            return .Infix;
        }

        /// Reads the next digits and/or any underscores
        fn integer(self: *Self) !Type {
            while (try self.peekChar()) |next_char|
                if (isDigit(next_char) or next_char == '_')
                    try self.consume()
                else
                    break;

            return .I;
        }

        /// Reads the next characters as number. `parseFloat` only throws
        /// `InvalidCharacter`, so this function cannot fail.
        fn float(self: *Self) !Type {
            self.int();
            if (try self.peekChar() == '.') {
                try self.consume();
                self.int();
            }

            return .F;
        }

        /// Reads a value wrapped in double-quotes from the current character. If no
        /// matching quote is found, reads until EOF.
        fn string(self: *Self) !Type {
            while (try self.peekChar() != '"')
                try self.consume();

            return .Str;
        }

        /// Reads until the end of the line or EOF
        fn comment(self: *Self) !Type {
            while (try self.peekChar()) |next_char|
                if (next_char != '\n')
                    try self.consume()
                else
                    // Newlines that terminate comments are also terms, so no
                    // `consume` here
                    break;

            return .Comment;
        }

        /// Returns true if the given character is a digit. Does not include
        /// underscores.
        fn isDigit(char: u8) bool {
            return switch (char) {
                '0'...'9' => true,
                else => false,
            };
        }

        fn isUpper(char: u8) bool {
            return switch (char) {
                'A'...'Z' => true,
                else => false,
            };
        }

        fn isLower(char: u8) bool {
            return switch (char) {
                'a'...'z' => true,
                else => false,
            };
        }

        fn isSep(char: u8) bool {
            return switch (char) {
                // zig fmt: off
        ',', ';', '(', ')',
        '[', ']', '{', '}',
        '"', '\'', '`', 
        // zig fmt: on
                => true,
                else => false,
            };
        }

        fn isInfix(char: u8) bool {
            return switch (char) {
                // zig fmt: off
        '.', ':', '-', '+', '=', '<', '>', '%',
        '^', '*', '&', '|', '/', '\\', '@', '!',
        '?', '~',
        // zig fmt: on
                => true,
                else => false,
            };
        }

        fn isSpace(char: u8) bool {
            return char == ' ' or
                char == '\t' or
                char == '\n';
        }

        fn isIdent(char: u8) bool {
            return !(isSpace(char) or isSep(char));
        }
    };
}

const testing = std.testing;
const io = std.io;
const meta = std.meta;
const verbose_tests = @import("build_options").verbose_tests;
// const stderr = if (false)
const stderr = if (verbose_tests)
    std.io.getStdErr().writer()
else
    std.io.null_writer;

const fs = std.fs;

fn expectEqualTokens(
    comptime input: []const u8,
    expecteds: []const []const u8,
) !void {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var fbs = io.fixedBufferStream(input);
    const reader = fbs.reader();
    var lex = Lexer(@TypeOf(reader)).init(arena.allocator(), reader);

    for (expecteds) |expected| {
        const next_token = (try lex.next()).?;
        try stderr.print("{s}\n", .{next_token.lit});
        try testing.expectEqualStrings(
            expected,
            next_token.lit,
        );
    }
}

test "Term: Vals" {
    const input =
        \\A B C
        \\Word-43
        \\Word-asd-_9182--+
        \\Random123
        \\Ssag-123+d
    ;
    const expecteds = &.{
        "A",         "B",  "C",                 "\n",
        "Word-43",   "\n", "Word-asd-_9182--+", "\n",
        "Random123", "\n", "Ssag-123+d",
    };
    try expectEqualTokens(input, expecteds);
}

test "Term: Val and Infix splitting" {
    const input = "\t\n\n\t\r\r\t\t  -Sd+-\t\n\t  +>-VB-NM+\t\n";
    const expecteds = &.{
        "\n", "\n",  "-",      "Sd+-",
        "\n", "+>-", "VB-NM+", "\n",
    };
    try expectEqualTokens(input, expecteds);
}

test "Term: Vars" {
    const input =
        \\a word-43 word-asd-+_9182-
        \\random123
        \\_sd
    ;
    const expecteds = &.{
        "a",         "word-43", "word-asd-+_9182-", "\n",
        "random123", "\n",      "_sd",
    };
    try expectEqualTokens(input, expecteds);
}

test "Term: Not Vars" {
    const input =
        \\Asdf
        \\-Word-43-
        \\Word-asd-+_2-
        \\Random_123_
    ;
    const expecteds = &.{
        "Asdf", "\n",            "-",  "Word-43-",
        "\n",   "Word-asd-+_2-", "\n", "Random_123_",
    };
    try expectEqualTokens(input, expecteds);
}

test "Term: comma seperators" {
    const input =
        \\As,dr,f
        \\-Wor,d-4,3-
        \\Word-,asd-,+_2-
        \\Rando,m_123_\
        \\
    ;
    const expecteds = &.{
        "As", ",",   "dr",    ",",     "f",    "\n",
        "-",  "Wor", ",",     "d-4",   ",",    "3",
        "-",  "\n",  "Word-", ",",     "asd-", ",",
        "+",  "_2-", "\n",    "Rando", ",",    "m_123_\\",
        "\n",
    };
    try expectEqualTokens(input, expecteds);
}

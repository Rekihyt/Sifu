/// The lexer for Sifu tries to make as few decisions as possible. Mostly,
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
const Lexer = @This();

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
const assert = std.debug.assert;
const debug = std.debug;

/// Source code that is being parsed
source: []const u8,
/// Current pos in the source
pos: usize = 0,
/// Current line in the source
line: usize = 0,
/// Current column in the source
col: usize = 1,
/// The allocator for each term
arena: ArenaAllocator,

/// Creates a new lexer using the given source code
pub fn init(allocator: Allocator, source: []const u8) Lexer {
    var arena = ArenaAllocator.init(allocator);
    return Lexer{
        .arena = arena,
        .source = source,
    };
}

pub fn deinit(self: *Lexer) void {
    self.arena.deinit();
}

/// Memory valid until deinit is called on this lexer
pub fn apps(self: *Lexer) !Ast {
    var result = ArrayListUnmanaged(Ast){};
    const allocator = self.arena.allocator();

    while (try self.nextToken()) |token| {
        // The current list becomes the first argument to the infix, then we
        // add any following asts to that
        if (token.type == .Infix) {
            var infix_apps = ArrayListUnmanaged(Ast){};
            try infix_apps.append(allocator, Ast.of(token));
            try infix_apps.append(allocator, Ast{
                .apps = try result.toOwnedSlice(allocator),
            });
            result = infix_apps;
        } else try result.append(allocator, Ast.of(token));
    }
    return Ast{ .apps = try result.toOwnedSlice(allocator) };
}

/// This function is the responsibility of the Lexer, because it is the dual
/// to parsing.
pub fn print(self: anytype, writer: anytype) !void {
    switch (self) {
        .apps => |asts| if (asts.len > 0 and asts[0] == .token) {
            const token = asts[0].token;
            if (token.type == .Infix) {
                // An infix always forms an App with at least 2
                // nodes, the second of which must be an App (which
                // may be empty)
                assert(asts.len >= 2);
                assert(asts[1] == .apps);
                try writer.writeAll("(");
                try print(asts[1], writer);
                try writer.writeByte(' ');
                try writer.writeAll(token.lit);
                if (asts.len >= 2)
                    for (asts[2..]) |arg| {
                        try writer.writeByte(' ');
                        try print(arg, writer);
                    };
                try writer.writeAll(")");
            } else if (asts.len > 0) {
                try print(asts[0], writer);
                for (asts[1..]) |it| {
                    try writer.writeByte(' ');
                    try print(it, writer);
                }
            } else try writer.writeAll("()");
        },
        .token => |token| try writer.print("{s}", .{token.lit}),
    }
}

/// Parses the source and returns the next sequence of terms forming an App,
/// adding them to the arraylist.
pub fn nextToken(self: *Lexer) Oom!?Token {
    self.skipWhitespace();
    const char = self.peek() orelse
        return null;

    const pos = self.pos;
    self.consume(); // tokens always have at least 1 char
    // Parse separators greedily. These can be vals or infixes, it
    // doesn't matter.
    const token_type: Token.Type = if (isSep(char))
        .Val
    else if (isInfix(char))
        self.infix()
    else if (isUpper(char) or char == '@')
        self.value()
    else if (isLower(char) or char == '_' or char == '$')
        self.variable()
    else if (isDigit(char))
        self.integer()
    else switch (char) {
        '+', '-' => if (self.peek()) |next|
            if (isDigit(next))
                self.integer()
            else
                self.infix()
        else
            .Val,
        '#' => self.comment(),
        else =>
        // This is a debug error only, as we shouldn't encounter an error
        // during lexing
        panic(
            \\Lexer Bug: Unknown character '{c}' at line {}, col {}.
            \\Note: Unicode no supported yet.
        ,
            .{ char, self.line, self.col },
        ),
    };
    const len = self.pos - pos;
    return Token{
        .type = token_type,
        .lit = try self.arena.allocator().dupe(
            u8,
            self.source[pos .. pos + len],
        ),
        .context = .{ .pos = pos, .uri = null },
    };
}

/// Returns the next character but does not increase the Lexer's position, or
/// returns null if there are no more characters left.
fn peek(self: Lexer) ?u8 {
    return if (self.pos < self.source.len)
        self.source[self.pos]
    else
        null;
}

/// Advances one character, or panics (should only be called after `peek`)
fn consume(self: *Lexer) void {
    if (self.peek()) |char| {
        self.pos += 1;
        if (char == '\n') {
            self.col = 1;
            self.line += 1;
        } else self.col += 1;
    } else panic(
        "Lexer Bug: Attempted to advance to next AST but EOF reached.",
        .{},
    );
}

/// Skips whitespace until a non-whitespace character is found. Not guaranteed
/// to skip anything. Newlines are separators, and thus treated as tokens.
fn skipWhitespace(self: *Lexer) void {
    while (self.peek()) |char|
        switch (char) {
            ' ', '\t', '\r' => self.consume(),
            else => break,
        };
}

fn consumeIdent(self: *Lexer) void {
    while (self.peek()) |next_char|
        if (isIdent(next_char))
            self.consume()
        else
            break;
}

fn value(self: *Lexer) Token.Type {
    self.consumeIdent();
    return .Val;
}

fn variable(self: *Lexer) Token.Type {
    self.consumeIdent();
    return .Var;
}
/// Reads the next infix characters
fn infix(self: *Lexer) Token.Type {
    while (self.peek()) |next_char|
        if (isInfix(next_char))
            self.consume()
        else
            break;

    return .Val;
}

/// Reads the next digits and/or any underscores
fn integer(self: *Lexer) Token.Type {
    while (self.peek()) |next_char|
        if (isDigit(next_char) or next_char == '_')
            self.consume()
        else
            break;

    return .I;
}

/// Reads the next characters as number. `parseFloat` only throws
/// `InvalidCharacter`, so this function cannot fail.
fn float(self: *Lexer) Token.Type {
    self.int();
    if (self.peek() == '.') {
        self.consume();
        self.int();
    }

    return .F;
}

/// Reads a value wrapped in double-quotes from the current character. If no
/// matching quote is found, reads until EOF.
fn string(self: *Lexer) Token.Type {
    while (self.peek() != '"')
        self.consume();

    return .Str;
}

/// Reads until the end of the line or EOF
fn comment(self: *Lexer) Token.Type {
    while (self.peek()) |next_char|
        if (next_char != '\n')
            self.consume()
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
        ',', ';', '\n',
        '(', ')', '[', ']', '{', '}',
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
    try testing.expectEqual(expected.apps.len, actual.apps.len);

    // This is redundant, but it makes any failures easier to trace
    for (expected.apps, actual.apps) |expected_elem, actual_elem| {
        try print(expected_elem, stderr);
        try stderr.writeByte('\n');

        try print(actual_elem, stderr);
        try stderr.writeByte('\n');

        if (@enumToInt(expected_elem) == @enumToInt(actual_elem)) {
            switch (expected_elem) {
                .token => |token| {
                    try testing.expectEqual(
                        @as(Order, .eq),
                        token.order(actual_elem.token),
                    );
                    try testing.expectEqualDeep(
                        token.lit,
                        actual_elem.token.lit,
                    );
                },
                .apps => try expectEqualApps(expected_elem, actual_elem),
            }
        } else {
            try stderr.writeAll("Asts of different types not equal");
            try testing.expectEqual(expected_elem, actual_elem);
            // above line should always fail
            debug.panic(
                "Asserted asts were equal despite different types",
                .{},
            );
        }
    }
    // Variants of this seem to cause the compiler to error with GenericPoison
    // try testing.expectEqual(@as(Order, .eq), expected.order(actual));
}

fn expectEqualTokens(input: []const u8, expecteds: []const []const u8) !void {
    var lexer = Lexer.init(testing.allocator, input);
    defer lexer.deinit();

    for (expecteds) |expected| {
        const next_token = (try lexer.nextToken()).?;
        try stderr.print("{s}\n", .{next_token.lit});
        try testing.expectEqualStrings(
            expected,
            next_token.lit,
        );
    }
}

test "All Asts" {
    const input =
        \\Val1,5;
        \\var1.
        \\Infix -->
        \\5 < 10.V
        \\1 + 2.0
        \\$strat
        \\
        \\10 == 10
        \\10 != 9
        \\"foo".len
        \\[1, 2]
        \\{"key":1}
        \\// a comment
        \\||
        \\()
    ;
    const expected = .{ .apps = &.{
        .{ .token = .{
            .type = .Val,
            .lit = "Val1",
            .context = .{ .pos = 0, .uri = null },
        } },
        .{ .token = .{
            .type = .Val,
            .lit = ",",
            .context = .{ .pos = 4, .uri = null },
        } },
        .{ .token = .{
            .type = .I,
            .lit = "5",
            .context = .{ .pos = 5, .uri = null },
        } },
        .{ .token = .{
            .type = .Val,
            .lit = ";",
            .context = .{ .pos = 6, .uri = null },
        } },
    } };
    // TODO: test full input string
    var lexer = Lexer.init(testing.allocator, input[0..7]);
    defer lexer.deinit();

    const actual = try lexer.apps();

    try expectEqualApps(expected, actual);
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

test "App: simple vals" {
    var lexer = Lexer.init(testing.allocator, "Aa Bb Cc");
    defer lexer.deinit();
    const expected = Ast{
        .apps = &.{
            Ast{ .token = .{
                .type = .Val,
                .lit = "Aa",
                .context = .{ .pos = 0, .uri = null },
            } },
            Ast{ .token = .{
                .type = .Val,
                .lit = "Bb",
                .context = .{ .pos = 3, .uri = null },
            } },
            Ast{ .token = .{
                .type = .Val,
                .lit = "Cc",
                .context = .{ .pos = 6, .uri = null },
            } },
        },
    };
    const actual = try lexer.apps();

    for (expected.apps, actual.apps) |expected_ast, actual_ast| {
        try testing.expectEqualStrings(
            expected_ast.token.lit,
            actual_ast.token.lit,
        );
        try testing.expectEqual(
            expected_ast.token.context.pos,
            actual_ast.token.context.pos,
        );
    }
}

test "App: simple op" {
    var lexer = Lexer.init(testing.allocator, "1 + 2");
    defer lexer.deinit();
    const expected = Ast{ .apps = &.{
        Ast{
            .token = .{
                .type = .Infix,
                .lit = "+",
                .context = .{ .pos = 2, .uri = null },
            },
        },
        Ast{ .apps = &.{
            Ast{
                .token = .{
                    .type = .I,
                    .lit = "1",
                    .context = .{ .pos = 0, .uri = null },
                },
            },
        } },
        Ast{
            .token = .{
                .type = .I,
                .lit = "2",
                .context = .{ .pos = 4, .uri = null },
            },
        },
    } };
    const actual = try lexer.apps();

    try expectEqualApps(expected, actual);
}

test "App: simple ops" {
    var lexer = Lexer.init(testing.allocator, "1 + 2 + 3");
    defer lexer.deinit();
    const expected = Ast{ .apps = &.{
        Ast{ .token = .{
            .type = .Infix,
            .lit = "+",
            .context = .{ .pos = 6, .uri = null },
        } },
        Ast{ .apps = &.{
            Ast{ .token = .{
                .type = .Infix,
                .lit = "+",
                .context = .{ .pos = 2, .uri = null },
            } },
            Ast{ .apps = &.{
                Ast{ .token = .{
                    .type = .I,
                    .lit = "1",
                    .context = .{ .pos = 0, .uri = null },
                } },
            } },
            Ast{ .token = .{
                .type = .I,
                .lit = "2",
                .context = .{ .pos = 4, .uri = null },
            } },
        } },
        Ast{ .token = .{
            .type = .I,
            .lit = "3",
            .context = .{ .pos = 8, .uri = null },
        } },
    } };
    const actual = try lexer.apps();
    try expectEqualApps(expected, actual);
}

test "App: simple op, no first arg" {
    var lexer = Lexer.init(testing.allocator, "+ 2");
    defer lexer.deinit();
    const expected = Ast{ .apps = &.{
        Ast{
            .token = .{
                .type = .Infix,
                .lit = "+",
                .context = .{ .pos = 2, .uri = null },
            },
        },
        Ast{ .apps = &.{} },
        Ast{
            .token = .{
                .type = .I,
                .lit = "2",
                .context = .{ .pos = 4, .uri = null },
            },
        },
    } };
    const actual = try lexer.apps();
    try expectEqualApps(expected, actual);
}

test "App: simple op, no second arg" {
    var lexer = Lexer.init(testing.allocator, "1 +");
    defer lexer.deinit();
    const expected = Ast{ .apps = &.{
        Ast{
            .token = .{
                .type = .Infix,
                .lit = "+",
                .context = .{ .pos = 2, .uri = null },
            },
        },
        Ast{ .apps = &.{
            Ast{ .token = .{
                .type = .I,
                .lit = "1",
                .context = .{ .pos = 0, .uri = null },
            } },
        } },
    } };
    const actual = try lexer.apps();
    try expectEqualApps(expected, actual);
}

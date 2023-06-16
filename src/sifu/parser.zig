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
const Span = ast.Span;
const Lit = ast.Lit;
const Ast = ast.Ast(Span);
const Token = ast.Token(Span);
const Set = util.Set;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const ArrayList = std.ArrayList;
const Oom = Allocator.Error;
const Order = std.math.Order;
const mem = std.mem;
const math = std.math;

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

/// Creates a new parser using the given source code
pub fn init(allocator: Allocator, source: []const u8) Parser {
    var arena = ArenaAllocator.init(allocator);
    return Parser{
        .arena = arena,
        .source = source,
    };
}

pub fn deinit(self: *Parser) void {
    self.arena.deinit();
}

/// Memory valid until deinit is called on this parser
pub fn apps(self: *Parser) !Ast {
    var result = ArrayListUnmanaged(Ast){};
    const allocator = self.arena.allocator();

    while (try self.nextToken()) |token| {
        switch (token.term) {
            .lit => |lit| switch (lit) {
                // The current list becomes the first argument to the infix, then we
                // add any following asts to that
                .infix => {
                    var infix_apps = ArrayListUnmanaged(Ast){};
                    try infix_apps.append(allocator, Ast.of(token));
                    try infix_apps.append(allocator, Ast{
                        .apps = try result.toOwnedSlice(allocator),
                    });
                    result = infix_apps;
                },
                else => try result.append(allocator, Ast.of(token)),
            },
            .@"var" => try result.append(allocator, Ast.of(token)),
        }
    }
    return Ast{ .apps = try result.toOwnedSlice(allocator) };
}

/// Parses the source and returns the next sequence of terms forming an App,
/// adding them to the arraylist.
fn nextToken(self: *Parser) Oom!?Token {
    self.skipWhitespace();
    const pos = self.pos;
    const char = self.peek() orelse return null;

    self.consume();
    // If the type here is inferred, Zig may claim it depends on runtime val
    const term: Token.Term = if (isLower(char) or char == '_')
        .{ .@"var" = try self.@"var"(pos) }
    else
        .{
            .lit = switch (char) {
                // Parse separators greedily. These are vals, but for efficiency
                // stored as u8's.
                '\n', ',', '.', ';', '(', ')', '{', '}', '[', ']', '"', '`' => Lit{
                    .sep = char,
                },
                '#' => .{ .comment = try self.comment(pos) },
                '+', '-' => if (self.peek()) |next_char|
                    if (isDigit(next_char)) .{
                        // Cannot fail, we saw at least one int
                        .int = self.int(pos) catch unreachable,
                    } else .{ .infix = try self.infix(pos) }
                else
                    // This block is here for readability, it could be unified
                    // with the previous `else` block's call to `infix`
                    .{
                        .infix = if (char == '+') "+" else "-",
                    },
                else => if (isUpper(char) or char == '$') .{
                    .val = try self.val(pos),
                } else if (isDigit(char)) .{
                    .int = self.int(pos) catch panic(
                        \\Parser Error: Arbitrary width integers not supported
                        \\yet: '{s}' at line {}, col {}"
                    , .{ self.source[pos..self.pos], self.line, self.col }),
                } else if (isInfix(char)) .{
                    .infix = try self.infix(pos),
                } else
                // This is a debug error only, as we shouldn't encounter an error
                // during lexing
                panic(
                    "Parser Error: Unknown character '{c}' at line {}, col {}",
                    .{ char, self.line, self.col },
                ),
            },
        };
    return Token{
        .term = term,
        .ctx = .{
            .pos = pos,
            .len = self.pos - pos,
        },
    };
}

/// Returns the next character but does not increase the Parser's position, or
/// returns null if there are no more characters left to .
fn peek(self: Parser) ?u8 {
    return if (self.pos < self.source.len)
        self.source[self.pos]
    else
        null;
}

/// Advances one character, or panics (should only be called after `peek`)
fn consume(self: *Parser) void {
    if (self.peek()) |char| {
        self.pos += 1;
        switch (char) {
            '\n' => {
                self.col = 1;
                self.line += 1;
            },
            else => self.col += 1,
        }
    } else @panic("Attempted to advance to next Ast but EOF reached");
}

/// Skips whitespace until a non-whitespace character is found. Not guaranteed
/// to skip anything. Newlines are separators, and thus treated as AstAst.
fn skipWhitespace(self: *Parser) void {
    while (self.peek()) |char| {
        switch (char) {
            ' ', '\t', '\r' => self.consume(),
            else => break,
        }
    }
}

/// Reads the next characters as a val
fn val(self: *Parser, pos: usize) Oom![]const u8 {
    while (self.peek()) |char|
        if (isIdent(char))
            self.consume()
        else
            break;

    return try self.arena.allocator().dupe(u8, self.source[pos..self.pos]);
}

/// Reads the next characters as an var
fn @"var"(self: *Parser, pos: usize) Oom![]const u8 {
    while (self.peek()) |char|
        if (isIdent(char))
            self.consume()
        else
            break;

    return try self.arena.allocator().dupe(u8, self.source[pos..self.pos]);
}

/// Reads the next characters as an identifier.
fn infix(self: *Parser, pos: usize) Oom![]const u8 {
    while (self.peek()) |char|
        if (isInfix(char))
            self.consume()
        else
            break;

    return try self.arena.allocator().dupe(u8, self.source[pos..self.pos]);
}

fn consumeDigits(self: *Parser) void {
    while (self.peek()) |next_char|
        if (isDigit(next_char))
            self.consume()
        else
            break;
}

/// Reads the next characters as number.
///
/// Errors:
/// `Overflow` - if the number cannot fit in a `usize`, and should be stored as
///    a `largeInt`.
fn int(self: *Parser, pos: usize) error{Overflow}!usize {
    self.consumeDigits();

    return if (std.fmt.parseUnsigned(usize, self.source[pos..self.pos], 10)) |i|
        i
    else |err| switch (err) {
        error.InvalidCharacter => unreachable, // we only consumed digits
        else => |e| e, // recapture to narrow the error type
    };
}

/// Reads the next characters as number. `parseFloat` only throws
/// `InvalidCharacter`, so this function cannot fail.
fn float(self: *Parser, pos: usize) fsize {
    self.consumeDigits();
    if (self.peek() == '.') {
        self.consume();
        self.consumeDigits();
    }

    return try std.fmt.parseFloat(fsize, self.source[pos..self.pos], 10) catch
        unreachable; // we only consumed digits, and maybe one decimal point
}

/// Reads a value wrappen in double-quotes from the current character
fn string(self: *Parser, pos: usize) Oom![]const u8 {
    while (self.peek()) |next_char| {
        self.consume(); // ignore the last double-quote
        if (next_char == '"')
            break;
    }

    return try self.arena.allocator().dupe(u8, self.source[pos..self.pos]);
}

/// Reads until the end of the line or EOF
fn comment(self: *Parser, pos: usize) Oom![]const u8 {
    while (self.peek()) |next_char|
        if (next_char != '\n')
            self.consume()
        else
            // Newlines that terminate comments are also terms, so no
            // `consume` here
            break;

    // `pos + 1` to ignore the '#'
    return try self.arena.allocator().dupe(u8, self.source[pos + 1 .. self.pos]);
}

/// Returns true if the given character is a digit
fn isDigit(char: u8) bool {
    return switch (char) {
        // Include underscores for spacing
        '0'...'9', '_' => true,
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

fn isIdent(char: u8) bool {
    return switch (char) {
        // zig fmt: off
        ' ', '\n', '\t', '\r', ',', ';', ':', '.', '^', '*', '=', '<', '>',
        '@', '$', '%', '&', '|', '/', '\\', '`', '[', ']', '(', ')', '{', '}',
        '"',
        => false,
        // zig fmt: on
        else => true,
    };
}

fn isInfix(char: u8) bool {
    return switch (char) {
        // zig fmt: off
        '.', ':', '-', '+', '=', '<', '>', '%', '^', '*', '&', '|', '/', '@',
        => true,
        // zig fmt: on
        else => false,
    };
}

const testing = std.testing;
const meta = std.meta;
const verbose_tests = @import("build_options").verbose_tests;
const writer = if (verbose_tests)
    std.io.getStdErr().writer()
else
    std.io.null_writer;

fn expectEqualApps(expected: Ast, actual: Ast) !void {
    try writer.writeByte('\n');
    try testing.expect(.apps == expected);
    try testing.expect(.apps == actual);

    // This is redundant, but it makes any failures easier to trace
    for (expected.apps, actual.apps) |expected_elem, actual_elem| {
        try expected_elem.print(writer);
        try writer.writeByte('\n');

        try actual_elem.print(writer);
        try writer.writeByte('\n');

        if (@enumToInt(expected_elem) == @enumToInt(actual_elem)) {
            switch (expected_elem) {
                .token => |token| {
                    try testing.expectEqual(
                        @as(Order, .eq),
                        token.compare(actual_elem.token),
                    );
                    try testing.expectEqualDeep(
                        token.term,
                        actual_elem.token.term,
                    );
                },
                .apps => try expectEqualApps(expected_elem, actual_elem),
            }
        } else {
            try writer.writeAll("Asts of different types not equal");
            try testing.expectEqual(expected_elem, actual_elem);
            // above line should always fail
            std.debug.panic(
                "Asserted asts were equal despite different types",
                .{},
            );
        }
    }
    // Variants of this seem to cause the compiler to error with GenericPoison
    // try testing.expectEqual(@as(Order, .eq), expected.compare(actual));
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
    const tests = &.{
        .{ .token = .{
            .term = .{ .lit = .{ .val = "Val1" } },
            .ctx = .{ .pos = 0, .len = 4 },
        } },
        .{ .token = .{
            .term = .{ .lit = .{ .val = "," } },
            .ctx = .{ .pos = 4, .len = 1 },
        } },
        .{ .token = .{
            .term = .{ .lit = .{ .int = 5 } },
            .ctx = .{ .pos = 5, .len = 1 },
        } },
        .{ .token = .{
            .term = .{ .lit = .{ .val = ";" } },
            .ctx = .{ .pos = 6, .len = 1 },
        } },
    };
    _ = tests;

    var parser = Parser.init(testing.allocator, input);
    defer parser.deinit();
}

test "Vals" {
    const val_strs = &[_][]const u8{
        "A",
        "Word-43",
        "Word-asd-cxvlj_9182--+",
        "Random123",
        "Ssag-123+d",
    };

    for (val_strs) |val_str| {
        var parser = Parser.init(testing.allocator, val_str);
        defer parser.deinit();
        const next_token = (try parser.nextToken()).?;

        try writer.print("{s}\n", .{next_token.term.lit.val});

        // Use == here to coerce union to enum
        try testing.expect(.lit == next_token.term);
        try testing.expectEqual(@as(?Token, null), try parser.nextToken());
    }

    // Should be -, Sd+, ++, V
    var parser = Parser.init(testing.allocator, "-Sd+ ++V");
    defer parser.deinit();
    try testing.expectEqualStrings(
        "-",
        (try parser.nextToken()).?.term.lit.infix,
    );
    try testing.expectEqualStrings(
        "Sd+",
        (try parser.nextToken()).?.term.lit.val,
    );
    try testing.expectEqualStrings(
        "++",
        (try parser.nextToken()).?.term.lit.infix,
    );
    try testing.expectEqualStrings(
        "V",
        (try parser.nextToken()).?.term.lit.val,
    );
}

test "Vars" {
    const varStrs = &[_][]const u8{
        "a",
        "word-43",
        "word-asd-cxvlj_9182-",
        "random123",
        "_sd",
    };
    for (varStrs) |varStr| {
        var parser = Parser.init(testing.allocator, varStr);
        defer parser.deinit();
        try testing.expect(.@"var" == (try parser.nextToken()).?.term);
        try testing.expectEqual(@as(?Token, null), try parser.nextToken());
    }

    const notVarStrs = &[_][]const u8{
        "\n\t\r Asdf,",
        "-Word-43-",
        "Word-asd-cxvlj_9182-",
        "Random_123_",
    };
    for (notVarStrs) |notVarStr| {
        var parser = Parser.init(testing.allocator, notVarStr);
        defer parser.deinit();
        while (try parser.nextToken()) |token| {
            try testing.expect(.@"var" != token.term);
        }
    }
}

test "App: simple vals" {
    var parser = Parser.init(testing.allocator, "Aa Bb Cc");
    defer parser.deinit();
    const expected = Ast{
        .apps = &.{
            Ast{ .token = .{
                .term = .{ .lit = .{ .val = "Aa" } },
                .ctx = .{ .pos = 0, .len = 2 },
            } },
            Ast{ .token = .{
                .term = .{ .lit = .{ .val = "Bb" } },
                .ctx = .{ .pos = 3, .len = 2 },
            } },
            Ast{ .token = .{
                .term = .{ .lit = .{ .val = "Cc" } },
                .ctx = .{ .pos = 6, .len = 2 },
            } },
        },
    };
    const actual = try parser.apps();

    for (expected.apps, actual.apps) |expected_ast, actual_ast| {
        try testing.expectEqualStrings(
            expected_ast.token.term.lit.val,
            actual_ast.token.term.lit.val,
        );
        try testing.expect(.val == actual_ast.token.term.lit);
        try testing.expectEqual(expected_ast.token.ctx.pos, actual_ast.token.ctx.pos);
        try testing.expectEqual(expected_ast.token.ctx.len, actual_ast.token.ctx.len);
    }
}

test "App: simple op" {
    var parser = Parser.init(testing.allocator, "1 + 2");
    defer parser.deinit();
    const expected = Ast{ .apps = &.{
        Ast{
            .token = .{
                .term = .{ .lit = .{ .infix = "+" } },
                .ctx = .{ .pos = 2, .len = 1 },
            },
        },
        Ast{ .apps = &.{
            Ast{
                .token = .{
                    .term = .{ .lit = .{ .int = 1 } },
                    .ctx = .{ .pos = 0, .len = 1 },
                },
            },
        } },
        Ast{
            .token = .{
                .term = .{ .lit = .{ .int = 2 } },
                .ctx = .{ .pos = 4, .len = 1 },
            },
        },
    } };
    const actual = try parser.apps();

    try expectEqualApps(expected, actual);
}

test "App: simple ops" {
    var parser = Parser.init(testing.allocator, "1 + 2 + 3");
    defer parser.deinit();
    const expected = Ast{ .apps = &.{
        Ast{ .token = .{
            .term = .{ .lit = .{ .infix = "+" } },
            .ctx = .{ .pos = 6, .len = 1 },
        } },
        Ast{ .apps = &.{
            Ast{ .token = .{
                .term = .{ .lit = .{ .infix = "+" } },
                .ctx = .{ .pos = 2, .len = 1 },
            } },
            Ast{ .apps = &.{
                Ast{ .token = .{
                    .term = .{ .lit = .{ .int = 1 } },
                    .ctx = .{ .pos = 0, .len = 1 },
                } },
            } },
            Ast{ .token = .{
                .term = .{ .lit = .{ .int = 2 } },
                .ctx = .{ .pos = 4, .len = 1 },
            } },
        } },
        Ast{ .token = .{
            .term = .{ .lit = .{ .int = 3 } },
            .ctx = .{ .pos = 8, .len = 1 },
        } },
    } };
    const actual = try parser.apps();
    try expectEqualApps(expected, actual);
}

test "App: simple op, no first arg" {
    var parser = Parser.init(testing.allocator, "+ 2");
    defer parser.deinit();
    const expected = Ast{ .apps = &.{
        Ast{
            .token = .{
                .term = .{ .lit = .{ .infix = "+" } },
                .ctx = .{ .pos = 2, .len = 1 },
            },
        },
        Ast{ .apps = &.{} },
        Ast{
            .token = .{
                .term = .{ .lit = .{ .int = 2 } },
                .ctx = .{ .pos = 4, .len = 1 },
            },
        },
    } };
    const actual = try parser.apps();
    try expectEqualApps(expected, actual);
}

test "App: simple op, no second arg" {
    var parser = Parser.init(testing.allocator, "1 +");
    defer parser.deinit();
    const expected = Ast{ .apps = &.{
        Ast{
            .token = .{
                .term = .{ .lit = .{ .infix = "+" } },
                .ctx = .{ .pos = 2, .len = 1 },
            },
        },
        Ast{ .apps = &.{
            Ast{ .token = .{
                .term = .{ .lit = .{ .int = 1 } },
                .ctx = .{ .pos = 0, .len = 1 },
            } },
        } },
    } };
    const actual = try parser.apps();
    try expectEqualApps(expected, actual);
}
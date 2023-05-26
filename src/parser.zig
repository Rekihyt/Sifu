/// The parser for Sifu tries to make as few decisions as possible. Mostly, it
/// greedily lexes seperators like commas into their own Ast nodes, separates
/// vars and vals based on the first character's case, and lexes numbers.
/// There are no errors, any utf-8 text is parsable.
///
// The simple syntax of the language enables lexing and parsing at the same
// time, so the parser lexes strings, ints, etc. into memory. Parsing always
// begins with a new `App` node. Each token is
// lexed, then a
//
const Parser = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const panic = std.debug.panic;
const Set = @import("util.zig").Set;
const Ast = @import("ast.zig").Ast;
const ArrayList = std.ArrayList;
const fsize = @import("util.zig").fsize;
const Error = Allocator.Error;

/// Source code that is being tokenized
source: []const u8,
/// Current pos in the source
pos: usize = 0,
/// Current line in the source
line: usize = 0,
/// Current column in the source
col: usize = 1,
/// The allocator for each token, which will all be freed when the trie being
/// lexed goes out of scope.
arena: ArenaAllocator,

/// Creates a new parser using the given source code
pub fn init(allocator: Allocator, source: []const u8) Parser {
    return Parser{
        .arena = ArenaAllocator.init(allocator),
        .source = source,
    };
}

pub fn deinit(self: *Parser) void {
    self.arena.deinit();
}

/// Caller owns returned memory.
pub fn appList(self: *Parser) Error!?ArrayList(Ast) {
    var apps_list = ArrayList(Ast).init(self.arena.allocator());

    while (try self.nextToken()) |ast|
        try apps_list.append(ast);

    return apps_list;
}

/// Parses the source and returns the next sequence of terms forming an App,
/// adding them to the arraylist. Allocates the
fn nextToken(self: *Parser) Error!?Ast {
    self.skipWhitespace();
    const pos = self.pos;
    const char = self.peek() orelse return null;

    self.consume();
    // If the type here is inferred, Zig may claim it depends on runtime val
    const kind: Ast.Kind = switch (char) {
        // Parse separators greedily. These are vals, but for efficiency stored as u8's.
        '\n', ',', '.', ';', '(', ')', '{', '}', '[', ']', '"', '`' => .{ .sep = char },
        '#' => .{ .comment = try self.comment(pos) },
        '+', '-' => if (self.peek()) |next_char|
            if (isDigit(next_char)) .{
                .int = self.int(pos) catch unreachable,
            } else .{ .infix = try self.infix(pos) }
        else .{
            // This block is here for readability, it could just be
            // unified with the previous `else` block's call to `infix`
            .infix = if (char == '+') "+" else "-",
        },
        else => if (isUpper(char) or char == '$') .{
            .val = try self.val(pos),
        } else if (isLower(char) or char == '_') .{
            .@"var" = try self.@"var"(pos),
        } else if (isDigit(char)) .{
            .int = self.int(pos) catch panic(
                \\Parser Error: Arbitrary width integers not supported yet:
                \\ '{s}' at line {}, col {}"
            , .{ self.source[pos..self.pos], self.line, self.col }),
        } else if (isInfix(char)) .{
            .infix = try self.infix(pos),
        } else
        // This is a debug error only, as we shouldn't encounter an error during lexing
        panic(
            "Parser Error: Unknown character '{c}' at line {}, col {}",
            .{ char, self.line, self.col },
        ),
    };
    return Ast{
        .kind = kind,
        .pos = pos,
        .len = self.pos - pos,
    };
}

/// Returns the next character but does not increase the Parser's position, or
/// returns null if there are no more characters left to Astize.
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
/// to skip anything. Newlines are separators, and thus treated as Asts.
fn skipWhitespace(self: *Parser) void {
    while (self.peek()) |char| {
        switch (char) {
            ' ', '\t', '\r' => self.consume(),
            else => break,
        }
    }
}

/// Reads the next characters as an val
fn val(self: *Parser, pos: usize) Error![]const u8 {
    while (self.peek()) |char|
        if (isIdent(char))
            self.consume()
        else
            break;

    return try self.arena.allocator().dupe(u8, self.source[pos..self.pos]);
}

/// Reads the next characters as an var
fn @"var"(self: *Parser, pos: usize) Error![]const u8 {
    while (self.peek()) |char|
        if (isIdent(char))
            self.consume()
        else
            break;

    return try self.arena.allocator().dupe(u8, self.source[pos..self.pos]);
}

/// Reads the next characters as an identifier
fn infix(self: *Parser, pos: usize) Error![]const u8 {
    while (self.peek()) |char|
        if (isInfix(char))
            self.consume()
        else
            break;

    return try self.arena.allocator().dupe(u8, self.source[pos..self.pos]);
}

/// Reads the next characters as number
fn int(self: *Parser, pos: usize) !usize {
    while (self.peek()) |nextChar|
        if (isDigit(nextChar))
            self.consume()
        else
            break;

    return if (std.fmt.parseUnsigned(usize, self.source[pos..self.pos], 10)) |i|
        i
    else |err| if (err == error.InvalidCharacter)
        unreachable // we only consumed digits
    else
        err;
}

/// Reads the next characters as number
fn float(self: *Parser, pos: usize) Error!fsize {
    // A float is just and int with an optional period and int immediately
    // after. This could still be implemented better though
    _ = try self.int();
    if (self.peek() == '.') {
        self.consume();
        _ = try self.int();
    }
    return try std.fmt.parseFloat(fsize, self.source[pos..self.pos], 10) catch
        unreachable; // we only consumed digits, and maybe one decimal point
}

/// Reads a value wrappen in double-quotes from the current character
fn string(self: *Parser, pos: usize) Ast {
    while (self.peek()) |nextChar| {
        self.consume(); // ignore the last double-quote
        if (nextChar == '"')
            break;
    }

    return try self.arena.allocator().dupe(u8, self.source[pos..self.pos]);
}

/// Reads until the end of the line or EOF
fn comment(self: *Parser, pos: usize) Error![]const u8 {
    while (self.peek()) |nextChar|
        if (nextChar != '\n')
            self.consume()
        else
            // Newlines that terminate comments are also tokens, so no
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

// TODO: add more tests after committing to using either spans or indices
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
    const tests = &[_]Ast{
        .{ .kind = .{ .val = "Val1" }, .pos = 0, .len = 4 },
        .{ .kind = .{ .val = "," }, .pos = 4, .len = 1 },
        .{ .kind = .{ .int = 5 }, .pos = 5, .len = 1 },
        .{ .kind = .{ .val = ";" }, .pos = 6, .len = 1 },
    };

    var parser = Parser.init(testing.allocator, input);

    for (tests) |unit| {
        const next_term = (try parser.nextToken()).?;

        switch (next_term.kind) {
            .val, .@"var", .comment, .infix => |str| {
                try testing.expectEqualStrings(unit.kind.val, str);
            },
            .int => |i| {
                try testing.expectEqual(unit.kind.int, i);
            },
            else => {},
        }
        try testing.expectEqual(unit.pos, next_term.pos);
        try testing.expectEqual(unit.len, next_term.len);
        // TODO: uncomment when Zig 0.11
        // try testing.expectEqualDeep(unit.kind, next_term.kind);
    }
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
        const next_term = (try parser.nextToken()).?;
        // try std.io.getStdErr().writer().print("{}\n", .{next_term});
        // try std.io.getStdErr().writer().print("{s}\n", .{val_str[next_term.val]});
        try testing.expect(.val == next_term.kind); // Use == here to coerce union to enum
        try testing.expectEqual(@as(?Ast, null), try parser.nextToken());
    }

    var parser = Parser.init(testing.allocator, "-Sd+ ++V"); // Should be -, Sd+, ++, V
    try testing.expectEqualSlices(u8, "-", (try parser.nextToken()).?.kind.infix);
    try testing.expectEqualSlices(u8, "Sd+", (try parser.nextToken()).?.kind.val);
    try testing.expectEqualSlices(u8, "++", (try parser.nextToken()).?.kind.infix);
    try testing.expectEqualSlices(u8, "V", (try parser.nextToken()).?.kind.val);
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
        try testing.expect(.@"var" == (try parser.nextToken()).?.kind);
        try testing.expectEqual(@as(?Ast, null), try parser.nextToken());
    }

    const notVarStrs = &[_][]const u8{
        "\n\t\r Asdf,",
        "-Word-43-",
        "Word-asd-cxvlj_9182-",
        "Random_123_",
    };
    for (notVarStrs) |notVarStr| {
        var parser = Parser.init(testing.allocator, notVarStr);
        while (try parser.nextToken()) |term| {
            _ = term;
            // try testing.expect(.@"var" != term.kind);
        }
    }
}

test "simple App of vals" {
    var parser = Parser.init(testing.allocator, "Aa Bb Cc");
    const asts = &[_]Ast{
        Ast{ .kind = .{ .val = "Aa" }, .pos = 0, .len = 2 },
        Ast{ .kind = .{ .val = "Bb" }, .pos = 3, .len = 2 },
        Ast{ .kind = .{ .val = "Cc" }, .pos = 6, .len = 2 },
    };
    const app_list = (try parser.appList()).?;
    for (asts) |ast, i| {
        try testing.expectEqualStrings(ast.kind.val, app_list.items[i].kind.val);
        try testing.expect(.val == app_list.items[i].kind);
        try testing.expectEqual(ast.pos, app_list.items[i].pos);
        try testing.expectEqual(ast.len, app_list.items[i].len);
    }
}

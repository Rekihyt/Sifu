const std = @import("std");
const testing = std.testing;
const Token = @import("token.zig");
const TokenType = Token.TokenType;
const Allocator = std.mem.Allocator;
const panic = std.debug.panic;

/// Lexer reads the source code and turns it into tokens
const Lexer = @This();

/// Source code that is being tokenized
source: []const u8,
/// Current position in the source
position: usize = 0,
/// Current line in the source
line: usize = 0,
/// Current column in the source
col: usize = 0,

/// Creates a new lexer using the given source code
pub fn init(source: []const u8) Lexer {
    var lexer = Lexer{ .source = source };
    return lexer;
}

/// Parses the source and returns the next token found
pub fn next(self: *Lexer) ?Token {
    self.skipWhitespace();
    const start = self.position;
    const char = self.peek().?;
    self.consume();
    // If the type here is inferred, zig will claim it depends on runtime val
    const token_type: TokenType = switch (char) {
        ',', '.', ';', '(', ')', '{', '}', '[', ']', '"' => .val,
        '$' => .strat,
        '/' => if (self.peek()) |nextChar| blk: {
            if (nextChar == '/') {
                self.consume();
                self.comment();
                break :blk .comment;
            } else {
                self.consume();
                self.infix();
                break :blk .infix;
            }
        } else .infix,
        else => blk: {
            if (isIdentChar(char))
                if (isUpper(char)) {
                    self.val();
                    break :blk .val;
                } else {
                    self.@"var"();
                    break :blk .@"var";
                }
            else if (isDigit(char)) {
                self.int();
                break :blk .integer;
            } else if (isInfix(char)) {
                self.infix();
                break :blk .integer;
            } // This is a debug error only, as we shouldn't encounter an error during lexing
            else panic(
                "Parser Error: Unknown character '{}' at line {}, col {}",
                .{ char, self.line, self.col },
            );
        },
    };

    return Token{
        .token_type = token_type,
        .start = start,
        .end = self.position,
    };
}

/// Tokenizes all tokens found in the input source and returns a list of tokens.
/// Memory is owned by the caller.
pub fn tokenize(self: *Lexer, allocator: Allocator) ![]const Token {
    var token_list = std.ArrayList(Token).init(allocator);
    while (self.next()) |token|
        try token_list.append(token);

    return token_list.toOwnedSlice();
}

/// Returns the next character but does not increase the Lexer's position, or
/// returns null if there are no more characters left to tokenize.
fn peek(self: Lexer) ?u8 {
    return if (self.position < self.source.len)
        self.source[self.position]
    else
        null;
}

/// Advances one character, or panics (should only be called after `peek`)
fn consume(self: *Lexer) void {
    if (self.peek()) |_|
        self.position += 1
    else
        @panic("Attempted to advance to next token but EOF reached");
}

/// Skips whitespace until a non-whitespace character is found. Not guaranteed
/// to skip anything
fn skipWhitespace(self: *Lexer) void {
    while (self.peek()) |char| {
        switch (char) {
            '\n' => {
                self.col = 0;
                self.line += 1;
            },
            ' ', '\t', '\r' => self.col += 1,
            else => break,
        }
        self.consume();
    }
}

/// Reads the next characters as a strat
fn strat(self: *Lexer) void {
    while (self.peek()) |char|
        if (isIdentChar(char) or isDigit(char))
            self.consume()
        else
            break;
}

/// Reads the next characters as an val
fn val(self: *Lexer) void {
    while (self.peek()) |char|
        if (isIdentChar(char))
            self.consume()
        else
            break;
}

/// Reads the next characters as an var
fn @"var"(self: *Lexer) void {
    while (self.peek()) |char|
        if (isIdentChar(char))
            self.consume()
        else
            break;
}

/// Reads the next characters as an identifier
fn infix(self: *Lexer) void {
    while (self.peek()) |char|
        if (isInfix(char))
            self.consume()
        else
            break;
}

/// Reads the next characters as number
fn int(self: *Lexer) void {
    while (self.peek()) |nextChar|
        if (isDigit(nextChar))
            self.consume()
        else
            break;
}

/// Reads the next characters as number
fn double(self: *Lexer) void {
    // A double is just and int with an optional period and int immediately
    // after
    self.int();
    if (self.peek() == '.') {
        self.consume();
        self.int();
    }
}

/// Reads a value wrappen in double-quotes from the current character
fn string(self: *Lexer) void {
    while (self.peek()) |nextChar|
        if (nextChar != '"')
            self.consume()
        else
            break;
}

/// Reads until the end of the line or EOF
fn comment(self: *Lexer) void {
    while (self.peek()) |nextChar|
        if (nextChar != '\n')
            self.consume()
        else
            break;
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

fn isInfix(char: u8) bool {
    return switch (char) {
        // TODO: ".:-^*+=<>$%^*&|/"
        // 'a'...'z' => true,
        else => false,
    };
}

/// True if the char can be a part of a valid identifier
fn isIdentChar(char: u8) bool {
    var buffer: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();
    const invalidChars = " \n\t\r,;:.^*+=<>@$%^&*|/\\`[](){}";

    var map = std.AutoHashMap(u8, void).init(allocator);
    defer map.deinit();

    // One day, this could be a comptime block
    const invalidCharSet = blk: {

        // Add the substrings to the map
        for (invalidChars) |invalidChar| {
            // Add the substring to the map
            map.put(invalidChar, {}) catch unreachable;
        }
        break :blk map;
    };
    return !invalidCharSet.contains(char);
}

test "All supported tokens" {
    const input =
        \\Val1,5;
        \\Infix -->
        \\var1.
        \\5 < 10.
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
    const tests = &[_]Token{
        .{ .token_type = .val, .start = 1, .end = 10 },
        .{ .token_type = .val, .start = 229, .end = 230 },
        .{ .token_type = .comment, .start = 233, .end = 250 },
        .{ .token_type = .val, .start = 251, .end = 254 },
        .{ .token_type = .val, .start = 251, .end = 254 },
    };

    var lexer = Lexer.init(input);

    for (tests) |unit| {
        const next_token = lexer.next().?;

        try testing.expectEqual(unit.start, next_token.start);
        try testing.expectEqual(unit.end, next_token.end);
        try testing.expectEqual(unit.token_type, next_token.token_type);
    }
}

test "Vars" {
    const valStrs = &[_][]const u8{
        "a",
        "word-43",
        "word-asd-cxvlj_9182",
        "random123",
        "_sd",
    };
    for (valStrs) |valStr| {
        var lexer = Lexer.init(valStr);
        _ = lexer;
        // try testing.expectEqual(.@"var", lexer.next().?.token_type);
        // try testing.expect(null == lexer.next());
    }

    const notVarStrs = &[_][]const u8{
        "",
        "\n\t\r Asdf,",
        "-word-43-",
        "Word-asd-cxvlj_9182-",
        "Random_123_",
    };
    for (notVarStrs) |notVarStr| {
        var lexer = Lexer.init(notVarStr);
        _ = lexer;
        // try testing.expectEqual(.val, lexer.next().?.token_type);
        // try testing.expect(null == lexer.next());
    }
}

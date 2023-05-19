const std = @import("std");
const testing = std.testing;
const Token = @import("token.zig");
const Allocator = std.mem.Allocator;

/// Lexer reads the source code and turns it into tokens
const Lexer = @This();

/// Source code that is being tokenized
source: []const u8,
/// Current position in the source
current: usize = 0,

/// Creates a new lexer using the given source code
pub fn init(source: []const u8) Lexer {
    var lexer = Lexer{ .source = source };
    return lexer;
}

/// Parses the source and returns the next token found
pub fn next(self: *Lexer) ?Token {
    self.skipWhitespace();

    const start = self.current;
    const token_type: Token.TokenType = switch (self.readChar().?) {
        ',' => .comma,
        '.' => .period,
        ';' => .semicolon,
        '(' => .l_paren,
        ')' => .r_paren,
        '{' => .l_brace,
        '}' => .r_brace,
        '[' => .l_bracket,
        ']' => .r_bracket,
        '"' => blk: {
            self.readString();
            defer _ = self.readChar();
            break :blk .string;
        },
        '$' => blk: {
            break :blk .strat;
        },
        else => |char| blk: {
            if (isIdentChar(char)) {
                if (isUpper(char))
                    self.readVal()
                else
                    self.readVar();
                break :blk .val;
            } else if (isDigit(char)) {
                self.readInt();
                break :blk .integer;
            } else if (isInfix(char)) {
                self.readInfix();
                break :blk .integer;
            } else return null;
        },
    };

    return Token{
        .token_type = token_type,
        .start = start,
        .end = self.current,
    };
}

/// Tokenizes all tokens found in the input source and returns a list of tokens.
/// Memory is owned by the caller.
pub fn tokenize(self: *Lexer, allocator: Allocator) ![]const Token {
    var token_list = std.ArrayList(Token).init(allocator);
    while (true) {
        const tok: *Token = try token_list.addOne();
        tok.* = self.next();
        if (tok.token_type == .eof) {
            return token_list.toOwnedSlice();
        }
    }
}

/// Returns the next character but does not increase the Lexer's position, or
/// returns null
fn peekChar(self: Lexer) ?u8 {
    return if (self.current < self.source.len)
        self.source[self.current]
    else
        null;
}

/// Reads exactly one character, or returns null
fn readChar(self: *Lexer) ?u8 {
    defer self.current += 1;
    // Use `.?` here to short-circuit the deferred `self.current += 1`
    return self.peekChar().?;
}

/// Skips whitespace until a non-whitespace character is found. Not guarantee
/// to skip anything
fn skipWhitespace(self: *Lexer) void {
    while (self.peekChar()) |char|
        _ = if (isWhitespace(char))
            self.readChar()
        else
            break;
}

fn readToken(self: *Lexer, tokenFn: fn (*Lexer) void) ?Token {
    const start = self.current;
    tokenFn().?;
    return self.source[start..self.current];
}

/// Reads the next characters as a strat
fn strat(self: *Lexer) void {
    while (if (self.readChar()) |char|
        isIdentChar(char) or isDigit(char))
    {}
    // if ()
    //     continue
    // else
    //     break;
}

/// Reads the next characters as an identifier
fn val(self: *Lexer) void {
    while (self.readChar()) |char|
        _ = if (isIdentChar(char))
            self.readChar()
        else
            break;
}

/// Reads the next characters as an identifier
fn @"var"(self: *Lexer) void {
    while (self.readChar()) |char|
        _ = if (isIdentChar(char))
            self.readChar()
        else
            break;
}

/// Reads the next characters as an identifier
fn infix(self: *Lexer) void {
    while (self.readChar()) |char|
        _ = if (isInfix(char))
            self.readChar()
        else
            break;
}

/// Reads the next characters as number
fn readInt(self: *Lexer) void {
    while (self.peekChar()) |nextChar|
        _ = if (isDigit(nextChar))
            self.readChar()
        else
            break;
}

/// Reads the next characters as number
fn readDouble(self: *Lexer) void {
    while (self.peekChar()) |nextChar|
        _ = if (isDigit(nextChar) || nextChar == '.')
            self.readChar()
        else
            break;
}

/// Reads a string from the current character
fn readString(self: *Lexer) void {
    while (self.peekChar()) |nextChar|
        _ = if (nextChar != '"')
            self.readChar()
        else
            break;
}

/// Reads until the end of the line or EOF
fn readLine(self: *Lexer) void {
    while (self.peekChar()) |nextChar|
        _ = if (nextChar != '\n')
            self.readChar()
        else
            break;
}

/// Returns true if the given character is considered whitespace
fn isWhitespace(char: u8) bool {
    return switch (char) {
        ' ', '\t', '\n', '\r' => true,
        else => false,
    };
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
        'a'...'z' => true,
        else => false,
    };
}

/// True if the char can be a part of a valid identifier
fn isIdentChar(char: u8) bool {
    const invalidCharSet = comptime blk: {
        var buffer: [8]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buffer);
        const allocator = fba.allocator();

        const invalidChars = " \n\t\r,;:.^*+=<>@$%^&*|/\\`[](){}";

        var map = std.AutoHashMap(u8, void).init(allocator);
        defer map.deinit();

        // Add the substrings to the map
        for (invalidChars) |invalidChar| {
            // Add the substring to the map
            try map.put(invalidChar, {});
        }
        break :blk map;
    };
    return !invalidCharSet.contains(char);
}

test "All supported tokens" {
    const input =
        \\ five 5
        \\ ten 10
        \\ add
        \\ 
        \\ 5 10 5
        \\ infix -->
        \\ if (5 < 10) {
        \\   return true
        \\ } else {
        \\   return false
        \\ }
        \\ 
        \\ 10 == 10
        \\ 10 != 9
        \\ "foo"
        \\ "foo bar"
        \\ "foo".len
        \\ [1, 2]
        \\ {"key":1}
        \\ //this is a comment
        \\ ||
        \\ ()
    ;

    const tests = &[_]Token{
        .{ .token_type = .identifier, .start = 6, .end = 10 },
        .{ .token_type = .integer, .start = 13, .end = 14 },
        .{ .token_type = .identifier, .start = 21, .end = 24 },
        .{ .token_type = .integer, .start = 27, .end = 29 },
        .{ .token_type = .identifier, .start = 36, .end = 39 },
        .{ .token_type = .l_paren, .start = 44, .end = 45 },
        .{ .token_type = .identifier, .start = 45, .end = 46 },
        .{ .token_type = .comma, .start = 46, .end = 47 },
        .{ .token_type = .identifier, .start = 48, .end = 49 },
        .{ .token_type = .r_paren, .start = 49, .end = 50 },
        .{ .token_type = .l_brace, .start = 51, .end = 52 },
        .{ .token_type = .identifier, .start = 55, .end = 56 },
        .{ .token_type = .identifier, .start = 59, .end = 60 },
        .{ .token_type = .r_brace, .start = 65, .end = 66 },
        .{ .token_type = .identifier, .start = 74, .end = 80 },
        .{ .token_type = .identifier, .start = 83, .end = 86 },
        .{ .token_type = .l_paren, .start = 86, .end = 87 },
        .{ .token_type = .identifier, .start = 87, .end = 91 },
        .{ .token_type = .comma, .start = 91, .end = 92 },
        .{ .token_type = .identifier, .start = 93, .end = 96 },
        .{ .token_type = .r_paren, .start = 96, .end = 97 },
        .{ .token_type = .integer, .start = 102, .end = 103 },
        .{ .token_type = .integer, .start = 104, .end = 105 },
        .{ .token_type = .integer, .start = 108, .end = 110 },
        .{ .token_type = .integer, .start = 113, .end = 114 },
        .{ .token_type = .infix, .start = 116, .end = 118 },
        .{ .token_type = .l_paren, .start = 119, .end = 120 },
        .{ .token_type = .integer, .start = 120, .end = 121 },
        .{ .token_type = .integer, .start = 124, .end = 126 },
        .{ .token_type = .r_paren, .start = 126, .end = 127 },
        .{ .token_type = .l_brace, .start = 128, .end = 129 },
        .{ .token_type = .r_brace, .start = 144, .end = 145 },
        .{ .token_type = .l_brace, .start = 151, .end = 152 },
        .{ .token_type = .r_brace, .start = 168, .end = 169 },
        .{ .token_type = .integer, .start = 171, .end = 173 },
        .{ .token_type = .integer, .start = 177, .end = 179 },
        .{ .token_type = .integer, .start = 180, .end = 182 },
        .{ .token_type = .integer, .start = 186, .end = 187 },
        .{ .token_type = .string, .start = 189, .end = 192 },
        .{ .token_type = .string, .start = 195, .end = 202 },
        .{ .token_type = .string, .start = 205, .end = 208 },
        .{ .token_type = .identifier, .start = 210, .end = 213 },
        .{ .token_type = .l_brace, .start = 214, .end = 215 },
        .{ .token_type = .integer, .start = 215, .end = 216 },
        .{ .token_type = .comma, .start = 216, .end = 217 },
        .{ .token_type = .integer, .start = 218, .end = 219 },
        .{ .token_type = .r_bracket, .start = 219, .end = 220 },
        .{ .token_type = .l_brace, .start = 221, .end = 222 },
        .{ .token_type = .string, .start = 223, .end = 226 },
        .{ .token_type = .colon, .start = 227, .end = 228 },
        .{ .token_type = .integer, .start = 228, .end = 229 },
        .{ .token_type = .r_brace, .start = 229, .end = 230 },
        .{ .token_type = .comment, .start = 233, .end = 250 },
        .{ .token_type = .none, .start = 251, .end = 254 },
        .{ .token_type = .unit, .start = 251, .end = 254 },
    };

    var lexer = Lexer.init(input);

    for (tests) |unit| {
        const current_token = lexer.next();

        try testing.expectEqual(unit.start, current_token.start);
        try testing.expectEqual(unit.end, current_token.end);
        try testing.expectEqual(unit.token_type, current_token.token_type);
    }
}

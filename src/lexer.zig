/// The lexer for Sifu tries to make as few decisions as possible. Mostly, it
/// greedily lexes seperators like commas into their own tokens, separates
/// vars and vals based on the first character's case, and lexes numbers.
/// There are no errors, all tokens will eventually be recognized, as well as
/// utf-8.
const Lexer = @This();

const std = @import("std");
const testing = std.testing;
const Token = @import("token.zig");
const TokenType = Token.TokenType;
const Allocator = std.mem.Allocator;
const panic = std.debug.panic;
const CharSet = std.AutoHashMap(u8, void);

/// Source code that is being tokenized
source: []const u8,
/// Current position in the source
position: usize = 0,
/// Current line in the source
line: usize = 0,
/// Current column in the source
col: usize = 1,

// These could be done at comptime in a future compiler
var char_sets_buffer: [1024]u8 = undefined;
var non_ident_char_set: CharSet = undefined;
var infix_char_set: CharSet = undefined;

/// Creates a new lexer using the given source code
pub fn init(source: []const u8) Lexer {
    const infix_chars = ".:-^*+=<>%^*&|/@";
    const non_ident_chars = " \n\t\r,;:.^*=<>@$%^&*|/\\`[](){}";
    var fba = std.heap.FixedBufferAllocator.init(&char_sets_buffer);
    const allocator = fba.allocator();
    non_ident_char_set = charSetFromStr(non_ident_chars, allocator);
    infix_char_set = charSetFromStr(infix_chars, allocator);

    return Lexer{
        .source = source,
    };
}

/// Parses the source and returns the next token found
pub fn next(self: *Lexer) ?Token {
    self.skipWhitespace();
    const start = self.position;
    const char = self.peek() orelse return null;
    self.consume();
    // If the type here is inferred, zig will claim it depends on runtime val
    const token_type: TokenType = switch (char) {
        // Parse separators greedily
        '\n', ',', '.', ';', '(', ')', '{', '}', '[', ']', '"', '`' => .val,
        '$' => self.strat(),
        '#' => self.comment(),
        else => if (isUpper(char))
            self.val()
        else if (isLower(char) or char == '_')
            self.@"var"()
        else if (isDigit(char))
            self.int()
        else if (infix_char_set.contains(char))
            self.infix()
        else // This is a debug error only, as we shouldn't encounter an error during lexing
            panic(
                "Parser Error: Unknown character '{c}' at line {}, col {}",
                .{ char, self.line, self.col },
            ),
    };

    return Token{
        .token_type = token_type,
        .start = start,
        .end = self.position,
        .str = self.source[start..self.position],
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
    if (self.peek()) |char| {
        self.position += 1;
        switch (char) {
            '\n' => {
                self.col = 1;
                self.line += 1;
            },
            else => self.col += 1,
        }
    } else @panic("Attempted to advance to next token but EOF reached");
}

/// Skips whitespace until a non-whitespace character is found. Not guaranteed
/// to skip anything. Newlines are separators, and thus treated as tokens.
fn skipWhitespace(self: *Lexer) void {
    while (self.peek()) |char| {
        switch (char) {
            ' ', '\t', '\r' => self.consume(),
            else => break,
        }
    }
}

/// Reads the next characters as a strat
fn strat(self: *Lexer) TokenType {
    while (self.peek()) |char|
        if (!non_ident_char_set.contains(char) or isDigit(char))
            self.consume()
        else
            break;

    return .strat;
}

/// Reads the next characters as an val
fn val(self: *Lexer) TokenType {
    while (self.peek()) |char|
        if (!non_ident_char_set.contains(char))
            self.consume()
        else
            break;

    return .val;
}

/// Reads the next characters as an var
fn @"var"(self: *Lexer) TokenType {
    while (self.peek()) |char|
        if (!non_ident_char_set.contains(char))
            self.consume()
        else
            break;

    return .@"var";
}

/// Reads the next characters as an identifier
fn infix(self: *Lexer) TokenType {
    while (self.peek()) |char|
        if (infix_char_set.contains(char))
            self.consume()
        else
            break;

    return .infix;
}

/// Reads the next characters as number
fn int(self: *Lexer) TokenType {
    while (self.peek()) |nextChar|
        if (isDigit(nextChar))
            self.consume()
        else
            break;

    return .integer;
}

/// Reads the next characters as number
fn double(self: *Lexer) TokenType {
    // A double is just and int with an optional period and int immediately
    // after
    self.int();
    if (self.peek() == '.') {
        self.consume();
        self.int();
    }
    return .double;
}

/// Reads a value wrappen in double-quotes from the current character
fn string(self: *Lexer) TokenType {
    while (self.peek()) |nextChar|
        if (nextChar != '"')
            self.consume()
        else
            break;

    return .string;
}

/// Reads until the end of the line or EOF
fn comment(self: *Lexer) TokenType {
    while (self.peek()) |nextChar|
        if (nextChar != '\n')
            self.consume()
        else
            break;

    return .comment;
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

// Owned by caller, which should call `deinit`.
fn charSetFromStr(str: []const u8, allocator: Allocator) CharSet {
    var invalid_char_set = std.AutoHashMap(u8, void).init(allocator);
    // Add the substrings to the map
    for (str) |char|
        // Add the substring to the map
        invalid_char_set.put(char, {}) catch unreachable;

    return invalid_char_set;
}

// TODO: add more tests after committing to using either spans or indices
test "all tokens" {
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
    const tests = &[_]Token{
        .{ .token_type = .val, .start = 0, .end = 4, .str = "Val1" },
        .{ .token_type = .val, .start = 4, .end = 5, .str = "," },
        .{ .token_type = .integer, .start = 5, .end = 6, .str = "5" },
        .{ .token_type = .val, .start = 6, .end = 7, .str = ";" },
    };

    var lexer = Lexer.init(input);

    for (tests) |unit| {
        const next_token = lexer.next().?;

        try testing.expectEqual(unit.start, next_token.start);
        try testing.expectEqual(unit.end, next_token.end);
        try testing.expectEqual(unit.token_type, next_token.token_type);
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
        var lexer = Lexer.init(val_str);
        const next_token = lexer.next().?;
        // try std.io.getStdErr().writer().print("{}\n", .{next_token});
        // try std.io.getStdErr().writer().print("{s}\n", .{val_str[next_token.val]});
        try testing.expectEqual(@as(TokenType, .val), next_token.token_type);
        try testing.expectEqual(@as(?Token, null), lexer.next());
    }

    var lexer = Lexer.init("-Sd+ ++V"); // Should be -, Sd+, ++, V
    try testing.expectEqual(@as(TokenType, .infix), lexer.next().?.token_type);
    try testing.expectEqual(@as(TokenType, .val), lexer.next().?.token_type);
    try testing.expectEqual(@as(TokenType, .infix), lexer.next().?.token_type);
    try testing.expectEqual(@as(TokenType, .val), lexer.next().?.token_type);
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
        var lexer = Lexer.init(varStr);
        try testing.expectEqual(@as(TokenType, .@"var"), lexer.next().?.token_type);
        try testing.expectEqual(@as(?Token, null), lexer.next());
    }

    const notVarStrs = &[_][]const u8{
        "\n\t\r Asdf,",
        "-Word-43-",
        "Word-asd-cxvlj_9182-",
        "Random_123_",
    };
    for (notVarStrs) |notVarStr| {
        var lexer = Lexer.init(notVarStr);
        while (lexer.next()) |token| {
            try testing.expect(.@"var" != token.token_type);
        }
    }
}

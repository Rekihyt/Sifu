/// The lexer for Sifu tries to make as few decisions as possible. Mostly, it
/// greedily lexes seperators like commas into their own Terms, separates
/// vars and vals based on the first character's case, and lexes numbers.
/// There are no errors, all Terms will eventually be recognized, as well as
/// utf-8. The simple syntax of the language enables lexing and some parsing
/// at the same time, so the lexer parses strings, ints, etc. into memory.
const Lexer = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const panic = std.debug.panic;
const Set = @import("util.zig").Set;
const Term = @import("ast.zig").Term;
const fsize = @import("util.zig").fsize;

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

// These could be done at comptime in a future compiler
var char_sets_buffer: [1024]u8 = undefined;
var non_ident_char_set: Set(u8) = undefined;
var infix_char_set: Set(u8) = undefined;

/// Creates a new lexer using the given source code
pub fn init(allocator: Allocator, source: []const u8) Lexer {
    var fba = std.heap.FixedBufferAllocator.init(&char_sets_buffer);
    const fba_allocator = fba.allocator();
    non_ident_char_set = SetFromStr(" \n\t\r,;:.^*=<>@$%^&*|/\\`[](){}", fba_allocator);
    infix_char_set = SetFromStr(".:-^*+=<>%^*&|/@", fba_allocator);

    return Lexer{
        .arena = ArenaAllocator.init(allocator),
        .source = source,
    };
}

pub fn deinit(self: *Lexer) void {
    self.arena.deinit();
}
/// Parses the source and returns the next Term found. Memory is allocated
/// using the `Lexer`'s arena allocator.
pub fn next(self: *Lexer) ?Term {
    self.skipWhitespace();
    const pos = self.pos;
    const char = self.peek() orelse return null;
    const allocator = self.arena.allocator();
    _ = allocator;
    self.consume();
    // If the type here is inferred, zig will claim it depends on runtime val
    const kind: Term.Kind = switch (char) {
        // Parse separators greedily. These are vals, but for efficiency stored as u8's.
        '\n', ',', '.', ';', '(', ')', '{', '}', '[', ']', '"', '`' => .{ .sep = char },
        '#' => .{ .comment = self.comment(pos) },
        '+', '-' => if (self.peek()) |next_char|
            if (isDigit(next_char)) .{
                .int = self.int(pos) catch unreachable,
            } else .{ .infix = self.infix(pos) }
        else .{
            // This block is here for readability, it could just be
            // unified with the previous `else` block's call to `infix`
            .infix = if (char == '+') "+" else "-",
        },
        else => if (isUpper(char) or char == '$') .{
            .val = self.val(pos),
        } else if (isLower(char) or char == '_') .{
            .@"var" = self.@"var"(pos),
        } else if (isDigit(char)) .{
            .int = self.int(pos) catch unreachable,
        } else if (infix_char_set.contains(char)) .{
            .infix = self.infix(pos),
        } else
        // This is a debug error only, as we shouldn't encounter an error during lexing
        panic(
            "Parser Error: Unknown character '{c}' at line {}, col {}",
            .{ char, self.line, self.col },
        ),
    };
    switch (kind) {
        .sep => {},
        // String slices need separate allocations
        .val, .@"var", .infix, .comment => |str| {
            _ = str;
            // (try allocator.dupe(u8, str)) = "";
        },
        .int => {},
        .double => {},
    }
    return Term{
        .kind = kind,
        .pos = pos,
        .len = self.pos - pos,
    };
}

/// Tokenizes all `Term`s found in the input source and returns a list of `Term`s.
/// Memory is owned by the caller.
pub fn tokenize(self: *Lexer, allocator: Allocator) ![]const Term {
    var term_list = std.ArrayList(Term).init(allocator);
    while (self.next()) |term|
        try term_list.append(term);

    return term_list.toOwnedSlice();
}

/// Returns the next character but does not increase the Lexer's position, or
/// returns null if there are no more characters left to Termize.
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
        switch (char) {
            '\n' => {
                self.col = 1;
                self.line += 1;
            },
            else => self.col += 1,
        }
    } else @panic("Attempted to advance to next Term but EOF reached");
}

/// Skips whitespace until a non-whitespace character is found. Not guaranteed
/// to skip anything. Newlines are separators, and thus treated as Terms.
fn skipWhitespace(self: *Lexer) void {
    while (self.peek()) |char| {
        switch (char) {
            ' ', '\t', '\r' => self.consume(),
            else => break,
        }
    }
}

/// Reads the next characters as an val
fn val(self: *Lexer, pos: usize) []const u8 {
    while (self.peek()) |char|
        if (!non_ident_char_set.contains(char))
            self.consume()
        else
            break;

    return self.source[pos..self.pos];
}

/// Reads the next characters as an var
fn @"var"(self: *Lexer, pos: usize) []const u8 {
    while (self.peek()) |char|
        if (!non_ident_char_set.contains(char))
            self.consume()
        else
            break;

    return self.source[pos..self.pos];
}

/// Reads the next characters as an identifier
fn infix(self: *Lexer, pos: usize) []const u8 {
    while (self.peek()) |char|
        if (infix_char_set.contains(char))
            self.consume()
        else
            break;

    return self.source[pos..self.pos];
}

/// Reads the next characters as number
fn int(self: *Lexer, pos: usize) !usize {
    while (self.peek()) |nextChar|
        if (isDigit(nextChar))
            self.consume()
        else
            break;

    return try std.fmt.parseUnsigned(usize, self.source[pos..self.pos], 10);
}

/// Reads the next characters as number
fn double(self: *Lexer, pos: usize) Term {
    // A double is just and int with an optional period and int immediately
    // after
    self.int();
    if (self.peek() == '.') {
        self.consume();
        self.int();
    }
    return try std.fmt.parseFloat(fsize, self.source[pos..self.pos], 10);
}

/// Reads a value wrappen in double-quotes from the current character
fn string(self: *Lexer, pos: usize) Term {
    while (self.peek()) |nextChar|
        if (nextChar != '"')
            self.consume()
        else
            break;

    return self.source[pos..self.pos];
}

/// Reads until the end of the line or EOF
fn comment(self: *Lexer, pos: usize) []const u8 {
    while (self.peek()) |nextChar|
        if (nextChar != '\n')
            self.consume()
        else
            // Newlines that terminate comments are also tokens, so no
            // `consume` here
            break;

    // `pos + 1` to ignore the '#'
    return self.source[pos + 1 .. self.pos];
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
fn SetFromStr(str: []const u8, allocator: Allocator) Set(u8) {
    var invalid_char_set = std.AutoHashMap(u8, void).init(allocator);
    // Add the substrings to the map
    for (str) |char|
        // Add the substring to the map
        invalid_char_set.put(char, {}) catch unreachable;

    return invalid_char_set;
}

const testing = std.testing;

// TODO: add more tests after committing to using either spans or indices
test "All Terms" {
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
    const tests = &[_]Term{
        .{ .kind = .{ .val = "Val1" }, .pos = 0, .len = 4 },
        .{ .kind = .{ .val = "," }, .pos = 4, .len = 1 },
        .{ .kind = .{ .int = 5 }, .pos = 5, .len = 1 },
        .{ .kind = .{ .val = ";" }, .pos = 6, .len = 1 },
    };

    var lexer = Lexer.init(testing.allocator, input);

    for (tests) |unit| {
        const next_term = lexer.next().?;

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
        var lexer = Lexer.init(testing.allocator, val_str);
        const next_term = lexer.next().?;
        // try std.io.getStdErr().writer().print("{}\n", .{next_term});
        // try std.io.getStdErr().writer().print("{s}\n", .{val_str[next_term.val]});
        try testing.expect(.val == next_term.kind); // Use == here to coerce union to enum
        try testing.expectEqual(@as(?Term, null), lexer.next());
    }

    var lexer = Lexer.init(testing.allocator, "-Sd+ ++V"); // Should be -, Sd+, ++, V
    try testing.expectEqualSlices(u8, "-", lexer.next().?.kind.infix);
    try testing.expectEqualSlices(u8, "Sd+", lexer.next().?.kind.val);
    try testing.expectEqualSlices(u8, "++", lexer.next().?.kind.infix);
    try testing.expectEqualSlices(u8, "V", lexer.next().?.kind.val);
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
        var lexer = Lexer.init(testing.allocator, varStr);
        defer lexer.deinit();
        try testing.expect(.@"var" == lexer.next().?.kind);
        try testing.expectEqual(@as(?Term, null), lexer.next());
    }

    const notVarStrs = &[_][]const u8{
        "\n\t\r Asdf,",
        "-Word-43-",
        "Word-asd-cxvlj_9182-",
        "Random_123_",
    };
    for (notVarStrs) |notVarStr| {
        var lexer = Lexer.init(testing.allocator, notVarStr);
        while (lexer.next()) |term| {
            _ = term;
            // try testing.expect(.@"var" != term.kind);
        }
    }
}

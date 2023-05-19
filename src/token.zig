const std = @import("std");
const testing = std.testing;

const Token = @This();

token_type: TokenType,
start: usize,
end: usize,

/// Identifiers that are considered a token
pub const TokenType = enum {
    // identifiers
    val,
    @"var",
    strat,
    infix,

    // literals
    double,
    integer,
    comment,
};

/// Returns the string value of the token
pub fn fmtString(token_type: Token.TokenType) []const u8 {
    return switch (token_type) {
        // identifiers + literals
        .val => "〈val〉",
        .@"var" => "〈var〉",
        .strat => "〈strat〉",
        .infix => "〈infix〉",
        .integer => "〈integer〉",
        .string => "〈string〉",
        .comment => "〈comment〉",
    };
}

/// Returns the correct type of the identifier.
/// First checks if it's a keyword and returns the corresponding keyword,
/// if no keyword is found, returns `.identifier`.
pub fn findType(val: []const u8) Token.TokenType {
    return Token.Keywords.get(val) orelse .val;
}

test "Identifiers" {
    const identifiers = &[_][]const u8{
        "a",
        "word",
        "random",
    };
    for (identifiers) |identifier| {
        try testing.expect(findType(identifier) == .identifier);
    }
}

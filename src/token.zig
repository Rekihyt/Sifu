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

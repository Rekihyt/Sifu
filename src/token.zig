const std = @import("std");
const testing = std.testing;

const Token = @This();

token_type: TokenType,
start: usize,
end: usize,
str: []const u8,

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

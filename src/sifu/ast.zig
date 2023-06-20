///
/// Tokens are either lowercase `Variables` or some kind of `TokenType`. Instead
/// of having separate literal definitions, the various kinds are wrapped
/// together to match the structure of patterns.
///
/// Variables can only be strings, so aren't defined.
///
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const util = @import("../util.zig");
const mem = std.mem;
const fsize = util.fsize();
const Order = math.Order;
const math = std.math;
const assert = std.debug.assert;
const Oom = Allocator.Error;
const Pattern = @import("../pattern.zig")
    .Pattern(Token(Location), []const u8, Ast(Location));
const Lexer = @import("lexer.zig");

/// The AST is the first form of structure given to the source code. It handles
/// infix and separator operators but does not differentiate between builtins.
/// The Context type is intended for metainfo such as `Location`.
pub fn Ast(comptime Context: type) type {
    return union(enum) {
        apps: []const Self,
        token: Token(Context),

        pub const Self = @This();

        pub fn of(token: Token(Context)) Self {
            return .{ .token = token };
        }

        pub fn ofApps(apps: []const Self) Self {
            return .{ .apps = apps };
        }
    };
}

/// Any word with with context, including vars.
pub fn Token(comptime Context: type) type {
    return struct {
        /// The string value of this token.
        lit: []const u8,

        /// `Context` is intended for optional debug/tooling information like
        /// `Location`.
        context: Context,

        pub const Self = @This();

        /// Ignores Context.
        pub fn order(self: Self, other: Self) Order {
            return mem.order(u8, self.lit, other.lit);
        }

        pub fn eql(self: Self, other: Self) bool {
            return .eq == self.order(other);
        }

        pub fn tokenType(self: Self) TokenType {
            return if (self.lit.len == 0) Pattern.ofLit("", "") else if (Lexer.isUpper(self.lit[0]))
                .Value;
        }

        /// Convert this to a Pattern literal or variable, setting the Pattern's
        /// value by parsing the Token.
        pub fn toPattern(self: Self, allocator: Allocator) Oom!Pattern {
            _ = self;
            _ = allocator;
        }
    };
}

/// The location info for Sifu tokens. The end position can be calulated from
/// the slice, so it isn't stored.
// TODO: Store a URI pointer here.
pub const Location = struct {
    pos: usize,
    uri: ?*const []u8,
};

/// These are determined during parsing, not lexing. The values here correspond
/// exactly to a type name in Sifu.
pub const TokenType = enum {
    Value,
    String,
    // Ints/UInts are be applied to a number which signifies their size
    I, // signed
    U, // unsigned
    Float,
    Comment,

    /// Compares by value, not by len, pos, or pointers.
    pub fn order(self: TokenType, other: TokenType) Order {
        return math.order(@enumToInt(self), @enumToInt(other));
    }

    pub fn eql(self: TokenType, other: TokenType) bool {
        return .eq == self.order(other);
    }
};

const testing = std.testing;
const Tok = Token(Location);

test "simple ast to pattern" {
    const term = Tok{
        .lit = "My-Token",
        .context = .{ .uri = null, .pos = 0 },
    };
    _ = term;
    const ast = Ast(Location){
        .token = .{
            .lit = "Some-Other-Token",
            .context = .{ .uri = null, .pos = 20 },
        },
    };
    _ = ast;
    // _ = Pattern.ofTokenType(term, ast);
}

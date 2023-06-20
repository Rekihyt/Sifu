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
        /// These are determined during parsing, but used during lexing. The values here
        /// correspond exactly to a type name in Sifu.
        pub const Type = enum {
            Val,
            Str,
            Var,
            Infix,
            // Ints/UInts are be applied to a number which signifies their size
            I, // signed
            U, // unsigned
            F, // float
            Comment,

            /// Compares by value, not by len, pos, or pointers.
            pub fn order(self: Type, other: Type) Order {
                return math.order(@enumToInt(self), @enumToInt(other));
            }

            pub fn eql(self: Type, other: Type) bool {
                return .eq == self.order(other);
            }
        };

        /// The string value of this token.
        lit: []const u8,

        /// The token type, to be used in patterns
        type: Type,

        /// `Context` is intended for optional debug/tooling information like
        /// `Location`.
        context: Context,

        pub const Self = @This();

        /// Ignores Context.
        pub fn order(self: Self, other: Self) Order {
            // Don't need to use `Token.Type` because it depends entirely on the
            // literal anyways.
            return mem.order(u8, self.lit, other.lit);
        }

        pub fn eql(self: Self, other: Self) bool {
            return .eq == self.order(other);
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

const testing = std.testing;
const Tok = Token(Location);

test "simple ast to pattern" {
    const term = Tok{
        .type = .Val,
        .lit = "My-Token",
        .context = .{ .uri = null, .pos = 0 },
    };
    _ = term;
    const ast = Ast(Location){
        .token = .{
            .type = .Val,
            .lit = "Some-Other-Token",
            .context = .{ .uri = null, .pos = 20 },
        },
    };
    _ = ast;
    // _ = Pattern.ofTokenType(term, ast);
}

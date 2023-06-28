const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;
const math = std.math;
const assert = std.debug.assert;
const util = @import("../util.zig");
const Order = math.Order;

/// The AST is the first form of structure given to the source code. It handles
/// infix, nesting, and separator operators but does not differentiate between
/// builtins. The `Token` is a custom type to allow storing of metainfo such as
/// `Location`.
pub fn Ast(comptime Token: type) type {
    return union(enum) {
        apps: []const Self,
        @"var": []const u8,
        token: Token,

        pub const Self = @This();

        pub fn of(token: Token) Self {
            return .{ .token = token };
        }

        pub fn ofApps(apps: []const Self) Self {
            return .{ .apps = apps };
        }

        /// Compares by value, not by len, pos, or pointers.
        pub fn order(self: Self, other: Self) Order {
            const ord = math.order(@enumToInt(self), @enumToInt(other));
            return if (ord == .eq)
                switch (self) {
                    .apps => |apps| util.orderWith(apps, other.apps, Self.order),
                    .@"var" => |v| mem.order(u8, v, other.@"var"),
                    .token => |token| token.order(other.token),
                }
            else
                ord;
        }
    };
}

const testing = std.testing;
const syntax = @import("syntax.zig");
const Location = syntax.Location;
const Tok = syntax.Token(Location);
const Term = syntax.Term;
const Type = syntax.Type;

test "simple ast to pattern" {
    const term = Tok{
        .type = .Val,
        .lit = "My-Token",
        .context = .{ .uri = null, .pos = 0 },
    };
    _ = term;
    const ast = Ast(Tok){
        .token = .{
            .type = .Val,
            .lit = "Some-Other-Token",
            .context = .{ .uri = null, .pos = 20 },
        },
    };
    _ = ast;
    // _ = Pattern.ofTokenType(term, ast);
}

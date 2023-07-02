const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;
const math = std.math;
const assert = std.debug.assert;
const util = @import("../util.zig");
const Order = math.Order;
const pattern = @import("../pattern.zig");

/// The AST is the first form of structure given to the source code. It handles
/// infix, nesting, and separator operators but does not differentiate between
/// builtins. The `Token` is a custom type to allow storing of metainfo such as
/// `Location`, and must implement `toString()` for pattern conversion.
pub fn Ast(comptime Token: type) type {
    return union(enum) {
        token: Token,
        @"var": []const u8,
        apps: []const Self,
        pattern: Pattern,

        pub const Self = @This();

        /// The Pattern type specific to the Sifu interpreter.
        pub const Pattern = pattern
            .Pattern([]const u8, []const u8, *Self);

        pub fn of(token: Token) Self {
            return .{ .token = token };
        }

        pub fn ofApps(apps: []const Self) Self {
            return .{ .apps = apps };
        }

        /// Compares by value, not by len, pos, or pointers.
        pub fn order(self: Self, other: Self) Order {
            const ord = math.order(@intFromEnum(self), @intFromEnum(other));
            return if (ord == .eq)
                switch (self) {
                    .apps => |apps| util.orderWith(apps, other.apps, Self.order),
                    .@"var" => |v| mem.order(u8, v, other.@"var"),
                    .token => |token| token.order(other.token),
                    .pattern => |pat| pat.order(other.pattern),
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

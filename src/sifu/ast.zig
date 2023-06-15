///
/// Tokens are either lowercase `Variables` or some kind of `Lit`. Instead
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

/// The AST is the first form of structure given to the source code. It handles
/// infix and separator operators but does not differentiate between builtins.
/// The Context type is intended for metainfo such as `Span`.
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

        pub fn print(self: Self, writer: anytype) !void {
            switch (self) {
                .apps => |asts| if (asts.len > 0 and
                    asts[0] == .token and
                    asts[0].token.term == .lit)
                    switch (asts[0].token.term.lit) {
                        .infix => |infix| {
                            // An infix always forms an App with at least 2
                            // nodes, the second of which must be an App (which
                            // may be empty)
                            assert(asts.len >= 2);
                            assert(asts[1] == .apps);
                            try writer.writeAll("(");
                            try asts[1].print(writer);
                            try writer.writeByte(' ');
                            try writer.writeAll(infix);
                            if (asts.len >= 2)
                                for (asts[2..]) |arg| {
                                    try writer.writeByte(' ');
                                    try arg.print(writer);
                                };
                            try writer.writeAll(")");
                        },
                        else => if (asts.len > 0) {
                            try asts[0].print(writer);
                            for (asts[1..]) |ast| {
                                try writer.writeByte(' ');
                                try ast.print(writer);
                            } else try writer.writeAll("()");
                        },
                    },
                .token => |token| switch (token.term) {
                    .lit => |lit| switch (lit) {
                        .comment => |cmt| {
                            try writer.writeByte('#');
                            try writer.writeAll(cmt);
                        },
                        inline else => |t| try writer.print("{any}", .{t}),
                    },
                    .@"var" => |v| try writer.print("{s}", .{v}),
                },
            }
        }
    };
}

/// Any term with context, including vars.
pub fn Token(comptime Context: type) type {
    return struct {
        pub const Term = union(enum) {
            @"var": []const u8,
            lit: Lit,
        };

        term: Term,
        ctx: Context,

        pub const Self = @This();

        pub fn ofVar(v: []const u8, ctx: Context) Self {
            return .{ .term = .{ .@"var" = v }, .ctx = ctx };
        }

        pub fn of(lit: Lit, ctx: Context) Self {
            return .{ .term = .{ .lit = lit }, .ctx = ctx };
        }

        /// Ignores Context.
        pub fn compare(self: Self, other: Self) Order {
            const order = math.order(
                @enumToInt(self.term),
                @enumToInt(other.term),
            );
            return if (order == .eq)
                switch (self.term) {
                    .@"var" => |v| mem.order(u8, v, other.term.@"var"),
                    .lit => |lit| lit.compare(other.term.lit),
                }
            else
                order;
        }

        pub fn eql(self: Self, other: Self) bool {
            return .eq == self.compare(other);
        }
    };
}
/// The location info for Sifu tokens.
pub const Span = struct {
    pos: usize,
    len: usize,
};

/// Literals in Sifu are all terms other than vars.
pub const Lit = union(enum) {
    sep: u8,
    // word: u64,
    val: []const u8,
    infix: []const u8,
    int: usize,
    // unboundInt: []const u1,
    float: fsize,
    comment: []const u8,

    /// Compares by value, not by len, pos, or pointers.
    pub fn compare(self: Lit, other: Lit) Order {
        return if (@enumToInt(self) == @enumToInt(other))
            switch (self) {
                .infix => |str| mem.order(u8, str, other.infix),
                .val => |str| mem.order(u8, str, other.val),
                .comment => |str| mem.order(u8, str, other.comment),
                .int => |num| math.order(num, other.int),
                .float => |num| math.order(num, other.float),
                .sep => |sep| math.order(sep, other.sep),
            }
        else
            math.order(@enumToInt(self), @enumToInt(other));
    }

    pub fn eql(self: Lit, other: Lit) bool {
        return .eq == self.compare(other);
    }
};

const testing = std.testing;
const Tok = Token(Span);

test "equal strings with different pointers, len, or pos should be equal" {
    const str1 = "abc";
    const str2 = try testing.allocator.dupe(u8, str1);
    defer testing.allocator.free(str2);

    const term1 = Tok{
        .term = .{ .lit = Lit{ .val = str1 } },
        .ctx = Span{ .len = 0, .pos = 0 },
    };
    const term2 = Tok{
        .term = .{ .lit = Lit{ .val = str2 } },
        .ctx = Span{ .len = 1, .pos = 1 },
    };

    try testing.expect(term1.eql(term2));
}

test "equal strings with different kinds should not be equal" {
    const str1 = "abc";
    const str2 = try testing.allocator.dupe(u8, str1);
    defer testing.allocator.free(str2);

    const term1 = Tok{
        .term = .{ .lit = Lit{ .val = str1 } },
        .ctx = Span{ .len = 0, .pos = 0 },
    };
    const term2 = Tok{
        .term = .{ .lit = Lit{ .infix = str2 } },
        .ctx = Span{ .len = 0, .pos = 0 },
    };

    try testing.expect(!term1.eql(term2));
}

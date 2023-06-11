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
/// Context is meant for metainfo such as `Span`, and is parameterized because
/// many computations on the Ast don't need it.
pub fn Ast(comptime Context: type) type {
    return union(enum) {
        apps: []const Ast,
        term: Term(Context),
    };
}

/// These form the leaves (or atoms) of the AST.
pub fn Term(comptime Context: type) type {
    return struct {
        token: union(enum) {
            @"var": []const u8,
            lit: Lit,
        },
        ctx: Context,
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

    pub fn equalTo(self: Lit, other: Lit) bool {
        return .eq == self.compare(other);
    }
};

pub fn print(self: anytype, writer: anytype) !void {
    switch (self) {
        .apps => |asts| if (asts.len > 0 and asts[0] == .term and asts[0].term.kind == .infix) {
            // An infix always forms an App with at least 2 nodes, the
            // second of which must be an App
            assert(asts.len >= 2);
            assert(asts[1] == .apps);
            try writer.writeAll("(");
            try asts[1].print(writer);
            try writer.writeByte(' ');
            try writer.writeAll(asts[0].term.kind.infix);
            if (asts.len >= 2)
                for (asts[2..]) |arg| {
                    try writer.writeByte(' ');
                    try arg.print(writer);
                };
            try writer.writeAll(")");
        } else if (asts.len != 0) {
            try asts[0].print(writer);
            for (asts[1..]) |ast| {
                try writer.writeByte(' ');
                try ast.print(writer);
            }
        },
        .term => |term| switch (term.kind) {
            .sep => |sep| try writer.writeByte(sep),
            .val, .@"var" => |ident| try writer.writeAll(ident),
            .infix => |ident| try writer.writeAll(ident),
            .comment => |cmt| {
                try writer.writeByte('#');
                try writer.writeAll(cmt);
            },
            .int => |i| try writer.print("{}", .{i}),
            .float => |f| try writer.print("{}", .{f}),
        },
    }
}

const testing = std.testing;

test "equal strings with different pointers, len, or pos should be equal" {
    const str1 = "abc";
    const str2 = try testing.allocator.dupe(u8, str1);
    defer testing.allocator.free(str2);

    const term1 = Lit{ .val = str1, .len = 0, .pos = 0 };
    const term2 = Lit{ .val = str2, .len = 1, .pos = 1 };

    try testing.expect(term1.equalTo(term2));
}

test "equal strings with different kinds should not be equal" {
    const str1 = "abc";
    const str2 = try testing.allocator.dupe(u8, str1);
    defer testing.allocator.free(str2);

    const term1 = Lit{ .val = str1, .len = 0, .pos = 0 };
    const term2 = Lit{ .infix = str2, .len = 0, .pos = 0 };

    try testing.expect(!term1.equalTo(term2));
}

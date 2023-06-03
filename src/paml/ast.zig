const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const util = @import("../util.zig");
const assert = std.debug.assert;
const mem = std.mem;
const math = std.math;
const Order = math.Order;

/// The Sifu AST primarily serves to abstract both infix operations and
/// juxtaposition into apps.
pub fn Ast(comptime T: type) type {
    return union(enum) {
        /// Because a term cannot be contained by more than one app (besides
        /// being in a nested app), they can be stored by value.
        apps: []const Self,

        /// A terminal node; a leaf
        term: T,

        pub const Self = @This();

        pub fn of(term: T) Self {
            return Self{ .term = term };
        }

        /// Compares by value, not by len, pos, or pointers.
        pub fn compare(self: Self, other: Self) Order {
            return switch (self) {
                .apps => |apps| switch (other) {
                    .apps => |other_apps| util.orderWith(apps, other_apps, Self.compare),

                    // apps are less than non-apps (sort of like in a dictionary)
                    else => .lt,
                },
                .term => |term| switch (other) {
                    .term => term.compare(other.term),
                    .apps => .gt,
                },
            };
        }

        /// Compares by value, not by len, pos, or pointers.
        pub fn equalTo(self: Self, other: Self) bool {
            return .eq == self.compare(other);
        }

        pub fn print(self: Self, writer: anytype) !void {
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
    };
}

const testing = std.testing;
const Term = @import("../sifu/Term.zig");

test "equal strings with different pointers, len, or pos should be equal" {
    const str1 = "abc";
    const str2 = try testing.allocator.dupe(u8, str1);
    defer testing.allocator.free(str2);

    const term1 = Term{ .kind = .{ .val = str1 }, .len = 0, .pos = 0 };
    const term2 = Term{ .kind = .{ .val = str2 }, .len = 1, .pos = 1 };

    try testing.expect(term1.equalTo(term2));
}

test "equal strings with different kinds should not be equal" {
    const str1 = "abc";
    const str2 = try testing.allocator.dupe(u8, str1);
    defer testing.allocator.free(str2);

    const term1 = Term{ .kind = .{ .val = str1 }, .len = 0, .pos = 0 };
    const term2 = Term{ .kind = .{ .@"var" = str2 }, .len = 0, .pos = 0 };

    try testing.expect(!term1.equalTo(term2));
}

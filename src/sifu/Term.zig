const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const util = @import("../util.zig");
const mem = std.mem;
const math = std.math;
const Order = math.Order;
const fsize = util.fsize();

const Term = @This();

kind: Kind,
pos: usize,
len: usize,

// May need to use `std.meta.fieldInfo(Term, .kind).field_type` if the
// compiler complains about self-dependency
pub const Kind = union(enum) {
    sep: u8,
    val: []const u8,
    @"var": []const u8,
    infix: []const u8,
    int: usize,
    // unboundInt: []const u1,
    float: fsize,
    comment: []const u8,

    /// Compares by value, not by len, pos, or pointers.
    pub fn compare(self: Kind, other: Kind) Order {
        return if (@enumToInt(self) == @enumToInt(other))
            switch (self) {
                .infix => |str| mem.order(u8, str, other.infix),
                .val => |str| mem.order(u8, str, other.val),
                .@"var" => |str| mem.order(u8, str, other.@"var"),
                .comment => |str| std.mem.order(u8, str, other.comment),
                .int => |num| math.order(num, other.int),
                .float => |num| math.order(num, other.float),
                .sep => |sep| math.order(sep, other.sep),
            }
        else
            math.order(@enumToInt(self), @enumToInt(other));
    }

    pub fn equalTo(self: Kind, other: Kind) bool {
        return .eq == self.compare(other);
    }
};

/// Compares by value, not by len, pos, or pointers.
pub fn compare(self: Term, other: Term) Order {
    return self.kind.compare(other.kind);
}

/// Compares by value, not by len, pos, or pointers.
pub fn equalTo(self: Term, other: Term) bool {
    return .eq == self.compare(other);
}

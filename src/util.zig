const std = @import("std");
const math = std.math;
const Order = math.Order;

pub fn Set(comptime T: type) type {
    return std.AutoHashMap(T, void);
}

// If this is just a const, the compiler complains about self-dependency in ast.zig
pub fn fsize() type {
    return switch (@typeInfo(usize).Int.bits) {
        8, 16 => f16,
        64 => f64,
        128 => f128,
        else => f32,
    };
}

const maxInt = std.math.maxInt;
test "expect f64" {
    try std.testing.expectEqual(switch (maxInt(usize)) {
        maxInt(u8), maxInt(u16) => f16,
        maxInt(u64) => f64,
        maxInt(u128) => f128,
        else => f32,
    }, fsize());
}

pub fn first(comptime T: type, slice: []const T) ?T {
    if (slice.len == 0) null else slice[0];
}

pub fn last(comptime T: type, slice: []const T) ?T {
    if (slice.len == 0) null else slice[slice.len - 1];
}

/// Compare two slices whose elements can be compared by the `order` function.
/// May panic on slices of different length.
pub fn orderWith(
    lhs: anytype,
    rhs: anytype,
    op: fn (anytype, anytype) Order,
) Order {
    const n = @min(lhs.len, rhs.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        switch (op(lhs[i], rhs[i])) {
            .eq => continue,
            .lt => return .lt,
            .gt => return .gt,
        }
    }
    return math.order(lhs.len, rhs.len);
}

const testing = std.testing;

test "slices of different len" {
    const s1 = &[_]usize{ 1, 2 };
    const s2 = &[_]usize{ 1, 2, 3 };
    try testing.expectEqual(@as(Order, .lt), orderWith(s1, s2, math.order));
}

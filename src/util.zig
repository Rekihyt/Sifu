const std = @import("std");

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

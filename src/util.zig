const std = @import("std");
const math = std.math;
const Order = math.Order;
const meta = std.meta;
const mem = std.mem;
const Strategy = std.hash.Strategy;
const Wyhash = std.hash.Wyhash;

pub fn hashFromHasherUpdate(
    comptime K: type,
) fn (K) u32 {
    return struct {
        fn hash(self: K) u32 {
            var hasher = Wyhash.init(0);
            self.hasherUpdate(&hasher);
            return @truncate(hasher.final());
        }
    }.hash;
}

pub fn hasherUpdateFromHash(
    comptime K: type,
    hash: fn (K) u32,
) fn (K, anytype) void {
    return struct {
        fn hasherUpdate(key: K, hasher: anytype) u32 {
            hasher.update(&mem.toBytes(hash(key)));
        }
    }.hasherUpdate;
}

// pub fn ArrayToUpdateContext(comptime ArrayCtx: anytype, comptime K: type) type {
//     return struct {
//         pub fn hasherUpdate(key: K, hasher: anytype) void {
//             if (@typeInfo(K) == .Struct or @typeInfo(K) == .Union)
//                 if (@hasDecl(K, "hasherUpdate")) {
//                     key.hasherUpdate(hasher);
//                     return;
//                 };
//             hasher.update(&mem.toBytes(ArrayCtx.hash(undefined, key)));
//         }
//         pub fn eql(k1: K, k2: K) bool {
//             return ArrayCtx.eql(undefined, k1, k2, undefined);
//         }
//     };
// }

// pub fn UpdateToArrayContext(comptime Ctx: type, comptime K: type) type {
//     return struct {
//         pub fn hash(self: @This(), key: K) u32 {
//             _ = self;
//             var hasher = Wyhash.init(0);
//             hasher.update(&mem.toBytes(Ctx.hash(key)));
//             return @truncate(hasher.final());
//         }
//         pub fn eql(self: @This(), k1: K, k2: K, b_index: usize) bool {
//             _ = b_index;
//             _ = self;
//             return Ctx.eql(k1, k2);
//         }
//     };
// }

// pub fn IntoUpdateContext(comptime Key: type) type {
//     return struct {
//         pub fn hasherUpdate(key: Key, hasher: anytype) void {
//             return key.hasherUpdate(hasher);
//         }

//         pub fn eql(
//             key: Key,
//             other: Key,
//         ) bool {
//             return key.eql(other);
//         }
//     };
// }

/// Convert a type with a hash and eql function with typical signatures to a
/// context compatible with std.array_hash_map.
pub fn IntoArrayContext(comptime Key: type) type {
    // const K = switch (@typeInfo(Key)) {
    //     .Struct, .Union, .Enum, .Opaque => Key,
    //     .Pointer => |ptr| ptr.child,
    //     else => @compileError(
    //         "Key type must be a struct/union or pointer to one",
    //     ),
    // };
    // _ = K;

    return struct {
        pub fn hash(self: @This(), key: Key) u32 {
            _ = self;
            return key.hash();
        }
        pub fn eql(
            self: @This(),
            key: Key,
            other: Key,
            b_index: usize,
        ) bool {
            _ = b_index;
            _ = self;
            return key.eql(other);
        }
    };
}

/// Curry a function. Necessary in cases where a type is unknown until after its
/// parent's instantiation.
pub fn Curry(
    comptime Fn: fn (type, type) type,
    comptime Arg1: type,
) fn (type) type {
    return struct {
        pub fn Curried(comptime Arg2: type) type {
            return Fn(Arg1, Arg2);
        }
    }.Curried;
}

pub fn AutoSet(comptime T: type) type {
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

pub fn first(comptime T: type, slice: []const T) ?T {
    return if (slice.len == 0) null else slice[0];
}

pub fn last(comptime T: type, slice: []const T) ?T {
    return if (slice.len == 0) null else slice[slice.len - 1];
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
    return while (i < n) : (i += 1) {
        switch (op(lhs[i], rhs[i])) {
            .eq => continue,
            .lt => break .lt,
            .gt => break .gt,
        }
    } else math.order(lhs.len, rhs.len);
}

const testing = std.testing;

test "expect f64" {
    try std.testing.expectEqual(switch (maxInt(usize)) {
        maxInt(u8), maxInt(u16) => f16,
        maxInt(u64) => f64,
        maxInt(u128) => f128,
        else => f32,
    }, fsize());
}

test "slices of different len" {
    const s1 = &[_]usize{ 1, 2 };
    const s2 = &[_]usize{ 1, 2, 3 };
    try testing.expectEqual(@as(Order, .lt), orderWith(s1, s2, math.order));
}

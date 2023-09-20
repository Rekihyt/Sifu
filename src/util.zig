const std = @import("std");
const math = std.math;
const Order = math.Order;
const meta = std.meta;
const mem = std.mem;
const Strategy = std.hash.Strategy;
const Wyhash = std.hash.Wyhash;

pub fn hashFromHasherUpdate(
    comptime K: type,
    hasherUpdate: fn (anytype, K) void,
) fn (K) u32 {
    return struct {
        fn hash(self: K) u32 {
            var hasher = Wyhash.init(0);
            hasherUpdate(&hasher, self);
            return @truncate(hasher.final());
        }
    }.hash;
}

pub fn hasherUpdateFromHash(
    comptime K: type,
    hash: fn (K) u32,
) fn (anytype, K) void {
    return struct {
        fn hasherUpdate(hasher: anytype, self: K) u32 {
            hasher.update(&mem.toBytes(hash(self)));
        }
    }.hasherUpdate;
}

/// Convert a type with a hash and eql function with typical signatures to a
/// context compatible with std.array_hash_map.
pub fn IntoArrayContext(
    comptime Key: type,
) type {
    const K = switch (@typeInfo(Key)) {
        .Struct, .Union, .Enum, .Opaque => Key,
        .Pointer => |ptr| ptr.child,
        else => @compileError(
            "Key type must be a struct/union or pointer to one",
        ),
    };
    _ = K;

    // if (@hasDecl(K, "hash")) {
    // util.hasherUpdateFromHash(Key.hash);
    // }
    // TODO: convert hasherUpdate to hash, and same for eql
    // else if (@hasDecl(Key, "hasherUpdate"))
    //     Key.hasherUpdate
    // else @compileError(
    //     \\ Context must contain either a hash or hasherUpdate
    //     \\ function
    // );

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

/// Calls `hash` on a struct or pointer to a struct if the method exists,
/// or uses `hasherUpdate` if it exists, otherwise hashes the value using
/// autoHashStrat. Follows a single pointer if necessary when calling `hash`.
pub fn genericHash(val: anytype) u32 {
    const Val = @TypeOf(val);
    const T = switch (@typeInfo(Val)) {
        .Pointer => |ptr| ptr.child,
        else => Val,
    };
    if (@typeInfo(T) == .Struct and @hasDecl(T, "hash"))
        return val.hash();

    var hasher = Wyhash.init(0);
    genericHasherUpdate(hasher, val);
    return @truncate(hasher.final());
}

/// Calls `hasherUpdate` on a struct or pointer to a struct if the method
/// exists, or uses `hash` if it exists, otherwises hashes the value using
/// autoHashStrat. Follows a single pointer if necessary when calling `hash`.
pub fn genericHasherUpdate(hasher: anytype, val: anytype) void {
    const Val = @TypeOf(val);
    const T = switch (@typeInfo(Val)) {
        .Pointer => |ptr| ptr.child,
        else => Val,
    };
    if (@typeInfo(T) == .Struct and @hasDecl(T, "hasherUpdate"))
        val.hasherUpdate(hasher)
    else if (@typeInfo(T) == .Struct and @hasDecl(T, "hash"))
        hasher.update(&mem.toBytes(val.hash()))
    else
        std.hash.autoHash(hasher, val);
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

// From: https://github.com/bcrist/vera
pub fn getAutoHashFn(
    comptime K: type,
    comptime strat: std.hash.Strategy,
    comptime Context: type,
) fn (Context, K) u32 {
    return struct {
        fn hash(ctx: Context, key: K) u32 {
            _ = ctx;
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHashStrat(&hasher, key, strat);
            return hasher.final();
        }
    }.hash;
}

// From: https://github.com/bcrist/vera
pub fn getAutoEqlFn(
    comptime K: type,
    comptime strat: std.hash.Strategy,
    comptime Context: type,
) fn (Context, K, K) bool {
    return struct {
        fn eql(ctx: Context, a: K, b: K) bool {
            _ = ctx;
            return deepEql(a, b, strat);
        }
    }.eql;
}

// From: https://github.com/bcrist/vera
pub fn DeepRecursiveAutoArrayHashMapUnmanaged(
    comptime K: type,
    comptime V: type,
) type {
    return std.ArrayHashMapUnmanaged(
        K,
        V,
        AutoStrategyContext(K, .DeepRecursive),
        true,
    );
}

// From: https://github.com/bcrist/vera
pub fn AutoStrategyContext(
    comptime K: type,
    comptime strat: std.hash.Strategy,
) type {
    return struct {
        pub const hash = getAutoHashFn(K, strat, @This());
        pub const eql = getAutoEqlFn(K, strat, @This());
    };
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
test "expect f64" {
    try std.testing.expectEqual(switch (maxInt(usize)) {
        maxInt(u8), maxInt(u16) => f16,
        maxInt(u64) => f64,
        maxInt(u128) => f128,
        else => f32,
    }, fsize());
}

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

test "slices of different len" {
    const s1 = &[_]usize{ 1, 2 };
    const s2 = &[_]usize{ 1, 2, 3 };
    try testing.expectEqual(Order.lt, orderWith(s1, s2, math.order));
}

/// Like std.meta.eql but follows pointers when possible, and requires eql
/// for struct types to be defined.
pub fn deepEql(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    switch (@typeInfo(T)) {
        .Struct => |info| {
            inline for (info.fields) |field_info| {
                // @compileError(std.fmt.comptimePrint(
                //     "{?}\n",
                //     .{field_info},
                // ));
                const eqlFn = if (@typeInfo(field_info.type) == .Struct and
                    @hasDecl(field_info.type, "eql"))
                    @field(field_info.type, "eql")
                else
                    deepEql;

                return eqlFn(
                    @field(a, field_info.name),
                    @field(b, field_info.name),
                );
            }
        },
        .ErrorUnion => return if (a) |a_p|
            if (b) |b_p|
                deepEql(a_p, b_p)
            else |_|
                false
        else |a_e| if (b) |_|
            false
        else |b_e|
            a_e == b_e,
        .Union => |info| {
            if (info.tag_type) |UnionTag| {
                const tag_a = meta.activeTag(a);
                const tag_b = meta.activeTag(b);
                if (tag_a != tag_b)
                    return false;

                inline for (info.fields) |field_info| {
                    if (@field(UnionTag, field_info.name) == tag_a) {
                        return deepEql(
                            @field(a, field_info.name),
                            @field(b, field_info.name),
                        );
                    }
                }
                return false;
            }
            @compileError(
                "cannot compare untagged union type " ++ @typeName(T),
            );
        },
        .Array => {
            if (a.len != b.len)
                return false;
            for (a, 0..) |e, i|
                if (!deepEql(e, b[i]))
                    return false;

            return true;
        },
        .Vector => |info| {
            var i: usize = 0;
            while (i < info.len) : (i += 1)
                if (!deepEql(a[i], b[i]))
                    return false;

            return true;
        },
        .Pointer => |info| {
            return switch (info.size) {
                .One, .C => deepEql(a.*, b.*),
                .Many => a == b,
                .Slice => a.len == b.len and for (a, b) |x, y| {
                    if (!deepEql(x, y))
                        return false;
                } else true,
            };
        },
        .Optional => {
            if (a == null and b == null)
                return true;
            if (a == null or b == null)
                return false;

            return deepEql(a.?, b.?);
        },
        else => return a == b,
    }
}

/// Write a struct or pointer using its "write" function if it has one.
pub fn genericWrite(val: anytype, writer: anytype) !void {
    const T = @TypeOf(val);
    switch (@typeInfo(T)) {
        .Struct => if (@hasDecl(T, "write")) {
            _ = try @field(T, "write")(val, writer);
        },
        .Pointer => |ptr| if (@hasDecl(ptr.child, "write")) {
            // @compileError(std.fmt.comptimePrint("{?}\n", .{ptr}));
            _ = try @field(ptr.child, "write")(val.*, writer);
        },
        else => try writer.print("{any}, ", .{val}),
    }
}

test "deepEql" {
    const S = struct {
        a: u32,
        b: f64,
        c: [5]u8,
    };

    const U = union(enum) {
        s: S,
        f: ?f32,
    };

    const s_1 = S{
        .a = 134,
        .b = 123.3,
        .c = "12345".*,
    };

    var s_3 = S{
        .a = 134,
        .b = 123.3,
        .c = "12345".*,
    };

    const u_1 = U{ .f = 24 };
    const u_2 = U{ .s = s_1 };
    const u_3 = U{ .f = 24 };

    try testing.expect(deepEql(s_1, s_3));
    try testing.expect(deepEql(&s_1, &s_1));
    try testing.expect(deepEql(&s_1, &s_3));
    try testing.expect(deepEql(u_1, u_3));
    try testing.expect(!deepEql(u_1, u_2));

    const a1 = "abcdef";
    const a2 = "abcdef";
    const a3 = "ghijkl";
    const a4 = "abc   ";
    try testing.expect(deepEql(a1, a2));
    try testing.expect(deepEql(a1.*, a2.*));
    try testing.expect(!deepEql(a1, a4));
    try testing.expect(!deepEql(a1, a3));
    try testing.expect(deepEql(a1[0..], a2[0..]));

    const EU = struct {
        fn tst(err: bool) !u8 {
            if (err) return error.Error;
            return @as(u8, 5);
        }
    };

    try testing.expect(deepEql(EU.tst(true), EU.tst(true)));
    try testing.expect(deepEql(EU.tst(false), EU.tst(false)));
    try testing.expect(!deepEql(EU.tst(false), EU.tst(true)));

    // TODO: fix, currently crashing compiler
    // var v1: u32 = @splat(@as(u32, 1));
    // var v2: u32 = @splat(@as(u32, 1));
    // var v3: u32 = @splat(@as(u32, 2));

    // try testing.expect(deepEql(v1, v2));
    // try testing.expect(!deepEql(v1, v3));
}

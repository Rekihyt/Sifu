const std = @import("std");
const math = std.math;
const Order = math.Order;
const meta = std.meta;
const mem = std.mem;

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

/// Like std.meta.eql but follows pointers when possible, and requires eql
/// for struct types to be defined. In the future, Zig might allow @hasDecl
/// to recurse on fields if eql isn't defined, but that currently segfaults
/// the compiler.
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

    var v1 = @splat(4, @as(u32, 1));
    var v2 = @splat(4, @as(u32, 1));
    var v3 = @splat(4, @as(u32, 2));

    try testing.expect(deepEql(v1, v2));
    try testing.expect(!deepEql(v1, v3));
}

const std = @import("std");
const math = std.math;
const Order = math.Order;
const meta = std.meta;
const mem = std.mem;
const Strategy = std.hash.Strategy;
const Wyhash = std.hash.Wyhash;
const Allocator = std.mem.Allocator;

/// Shorthand for printing to stderr or null writer and asserting no errors.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    const stderr = if (@import("build_options").verbose_tests)
        std.io.getStdErr().writer()
    else
        std.io.null_writer;
    stderr.print(fmt, args) catch unreachable;
}

pub fn popSlice(
    unmanaged_list: anytype,
    index: usize,
    allocator: Allocator,
) !@typeInfo(@TypeOf(unmanaged_list)).Pointer.child {
    // if (list.items.len > index) for (list.items)
    var result = @typeInfo(@TypeOf(unmanaged_list)).Pointer.child{};
    for (unmanaged_list.items[index..]) |app| {
        try result.append(allocator, app);
    }
    unmanaged_list.shrinkRetainingCapacity(index);
    return result;
}

pub fn mapOption(option: anytype, function: anytype) @TypeOf(function(option)) {
    return if (option) |value|
        function(value)
    else
        null;
}

/// Get a reference to a nullable field in `struct_ptr`, creating one if it
/// doesn't already exist, initialized to default struct value.
pub fn getOrInit(
    comptime Field: anytype,
    struct_ptr: anytype,
    allocator: Allocator,
) !@typeInfo(@TypeOf(@field(struct_ptr, @tagName(Field)))).Optional.child {
    const field_option = @field(struct_ptr, @tagName(Field));
    const FieldPtrType = @typeInfo(@TypeOf(field_option)).Optional.child;
    const FieldType = @typeInfo(FieldPtrType).Pointer.child;
    const field = field_option orelse blk: {
        var new_field = try allocator.create(FieldType);
        new_field.* = FieldType{};
        break :blk new_field;
    };
    // @compileLog(FieldPtrType);
    // @compileLog(FieldType);
    @field(struct_ptr, @tagName(Field)) = field;
    return field;
}

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

pub fn genericWrite(val: anytype, writer: anytype) @TypeOf(writer).Error!void {
    return switch (@typeInfo(@TypeOf(val))) {
        .Struct, .Union => val.write(writer),
        .Pointer => |S| if (S.child == u8)
            writer.writeAll(val)
        else
            writer.print("{any}", .{val}),
        else => writer.print("{any}", .{val}),
    };
}

/// Convert a type with a hash and eql function with typical signatures to a
/// context compatible with std.array_hash_map.
pub fn IntoArrayContext(comptime Key: type) type {
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
/// Panics on slices of different length.
pub fn sliceOrder(
    lhs: anytype,
    rhs: anytype,
    op: fn (anytype, anytype) Order,
) Order {
    return for (lhs, rhs) |lhs_val, rhs_val|
        switch (op(lhs_val, rhs_val)) {
            .eq => continue,
            .lt => break .lt,
            .gt => break .gt,
        }
    else
        .eq;
}

pub fn sliceEql(
    lhs: anytype,
    rhs: @TypeOf(lhs),
    eq: fn (
        @typeInfo(@TypeOf(lhs)).Pointer.child,
        @typeInfo(@TypeOf(rhs)).Pointer.child,
    ) bool,
) bool {
    return lhs.len == rhs.len and for (lhs, rhs) |lhs_val, rhs_val| {
        if (!eq(lhs_val, rhs_val))
            break false;
    } else true;
}

/// Call a function with both values, if they are present, returning null if
/// not.
/// Like Haskell's liftM2 but with Zig's optional type as the monad.
pub fn liftOption(
    comptime R: type,
    maybe_lhs: anytype,
    maybe_rhs: anytype,
    op: fn (anytype, anytype) R,
) ?R {
    if (maybe_lhs) |lhs| if (maybe_rhs) |rhs|
        return op(lhs, rhs);

    return null;
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
    const s1: []const usize = &.{ 1, 2, 3 };
    const s2: []const usize = &.{ 1, 2, 4 };
    try testing.expectEqual(Order.lt, sliceOrder(s1, s2, math.order));
    const s3: []const usize = &.{ 1, 2, 3 };
    const eq = struct {
        pub fn eq(a: usize, b: usize) bool {
            return a == b;
        }
    }.eq;
    try testing.expect(sliceEql(s1, s3, eq));
    try testing.expect(!sliceEql(s1, s2, eq));
}

/// Calls `hash` on a struct or pointer to a struct if the method exists,
/// or uses `hasherUpdate` if it exists, otherwise hashes the value using
/// autoHashStrat. Follows a single pointer if necessary when calling `hash`.
pub fn genericHash(val: anytype) u32 {
    const Val = @TypeOf(val);
    const T = switch (@typeInfo(Val)) {
        .Pointer => |ptr| ptr.child,
        else => Val,
    };
    if (@typeInfo(T) == .Struct or @typeInfo(T) == .Union)
        if (@hasDecl(T, "hash"))
            return val.hash();

    var hasher = Wyhash.init(0);
    genericHasherUpdate(hasher, val);
    return @truncate(hasher.final());
}

/// Calls `hasherUpdate` on a struct or pointer to a struct if the method
/// exists, or uses `hash` if it exists, otherwises hashes the value using
/// autoHashStrat. Follows a single pointer if necessary when calling `hash`.
pub fn genericHasherUpdate(
    comptime HashCtx: ?type,
    val: anytype,
    hasher: anytype,
) void {
    const Val = @TypeOf(val);
    const T = switch (@typeInfo(Val)) {
        .Pointer => |ptr| ptr.child,
        else => Val,
    };
    if (HashCtx) |Ctx| {
        if (@typeInfo(Ctx) == .Struct or @typeInfo(Ctx) == .Union)
            if (@hasDecl(Ctx, "hasherUpdate"))
                Ctx.hasherUpdate(val, hasher)
            else if (@hasDecl(Ctx, "hash"))
                hasher.update(&mem.toBytes(Ctx.hash(undefined, val)));
    } else if (@typeInfo(T) == .Struct or @typeInfo(T) == .Union) {
        if (@hasDecl(T, "hasherUpdate"))
            val.hasherUpdate(hasher)
        else if (@hasDecl(T, "hash"))
            hasher.update(&mem.toBytes(val.hash()));
    } else @compileError("No hash or hasherUpdate provided via ctx or method");
    // } else std.hash.autoHash(hasher, val);
}

/// Like std.meta.eql but follows pointers when possible, and calls eql
/// on container types to be defined.
pub fn genericEql(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);

    // `@hasDecl` currently crashing compiler
    switch (@typeInfo(T)) {
        .Struct, .Union => if (@hasDecl(T, "eql"))
            return a.eql(b),
        else => {},
    }
    switch (@typeInfo(T)) {
        .Struct => |info| return inline for (info.fields) |field_info| {
            if (!genericEql(
                @field(a, field_info.name),
                @field(b, field_info.name),
            )) break false;
        } else true,
        .ErrorUnion => if (a) |a_p|
            return if (b) |b_p| genericEql(a_p, b_p) else |_| false
        else |a_e|
            return if (b) |_| false else |b_e| a_e == b_e,
        .Union => |info| {
            if (info.tag_type) |UnionTag| {
                const tag_a = meta.activeTag(a);
                const tag_b = meta.activeTag(b);
                return if (tag_a != tag_b)
                    false
                else
                    return inline for (info.fields) |tag| {
                        if (@field(UnionTag, tag.name) == tag_a)
                            break genericEql(
                                @field(a, tag.name),
                                @field(b, tag.name),
                            );
                    } else false;
            }
            @compileError(
                "cannot compare untagged union type " ++ @typeName(T),
            );
        },
        .Array => {
            if (a.len != b.len)
                return false;

            for (a, 0..) |e, i|
                if (!genericEql(e, b[i]))
                    return false;

            return true;
        },
        .Vector => |info| {
            var i: usize = 0;
            while (i < info.len) : (i += 1) {
                if (!genericEql(a[i], b[i]))
                    return false;
            }
            return true;
        },
        .Pointer => |info| return switch (info.size) {
            .One, .C => genericEql(a.*, b.*),
            .Slice => a.len == b.len and for (a, b) |x, y| {
                if (genericEql(x, y)) break false;
            } else true,
            .Many => a == b,
        },
        .Optional => {
            if (a == null and b == null)
                return true;
            if (a == null or b == null)
                return false;
            return genericEql(a.?, b.?);
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

test "genericEql" {
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

    try testing.expect(genericEql(s_1, s_3));
    try testing.expect(genericEql(&s_1, &s_1));
    try testing.expect(genericEql(&s_1, &s_3));
    try testing.expect(genericEql(u_1, u_3));
    try testing.expect(!genericEql(u_1, u_2));

    const a1 = "abcdef";
    const a2 = "abcdef";
    const a3 = "ghijkl";
    const a4 = "abc   ";
    try testing.expect(genericEql(a1, a2));
    try testing.expect(genericEql(a1.*, a2.*));
    try testing.expect(!genericEql(a1, a4));
    try testing.expect(!genericEql(a1, a3));
    try testing.expect(genericEql(a1[0..], a2[0..]));

    const EU = struct {
        fn tst(err: bool) !u8 {
            if (err) return error.Error;
            return @as(u8, 5);
        }
    };

    try testing.expect(genericEql(EU.tst(true), EU.tst(true)));
    try testing.expect(genericEql(EU.tst(false), EU.tst(false)));
    try testing.expect(!genericEql(EU.tst(false), EU.tst(true)));

    // TODO: fix, currently crashing compiler
    // var v1: u32 = @splat(@as(u32, 1));
    // var v2: u32 = @splat(@as(u32, 1));
    // var v3: u32 = @splat(@as(u32, 2));

    // try testing.expect(genericEql(v1, v2));
    // try testing.expect(!genericEql(v1, v3));
}

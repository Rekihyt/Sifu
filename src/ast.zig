const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;
const math = std.math;
const assert = std.debug.assert;
const util = @import("util.zig");
const Order = math.Order;
const Wyhash = std.hash.Wyhash;

// Allows []const u8.
pub fn AutoAst(
    comptime Key: type,
    comptime Var: type,
    comptime ValOrSelf: ?type,
) type {
    return Ast(
        Key,
        Var,
        util.Curry(std.AutoArrayHashMapUnmanaged, Key),
        util.Curry(std.AutoArrayHashMapUnmanaged, Var),
        ValOrSelf,
    );
}

pub fn StringAst(comptime Var: type, comptime ValOrSelf: ?type) type {
    return Ast(
        []const u8,
        Var,
        std.StringArrayHashMapUnmanaged,
        util.Curry(std.AutoArrayHashMapUnmanaged, Var),
        ValOrSelf,
    );
}

/// The AST is the structure given to the source code and IR. It handles
/// infix, nesting, and separator operators but does not differentiate between
/// builtins. The `Key` is a custom type to allow storing of metainfo such as a
/// position, and must implement `toString()` for pattern conversion. It could
/// also be a simple type for optimization purposes.
///
/// Pass null for `Val` to use the instantiated Ast (the Self type in this
/// struct definition) type as the Val type in the Pattern, as it isn't possible
/// to specify this before the type is instantiated.
pub fn Ast(
    comptime Key: type,
    comptime Var: type,
    comptime KeyMapFn: fn (type) type,
    comptime VarMapFn: fn (type) type,
    comptime ValOrSelf: ?type,
) type {
    return union(enum) {
        key: Key,
        @"var": Var,
        apps: Apps,
        pattern: Pat,

        pub const Self = @This();

        /// The type that the `Pat` evaluates to after matching on an instance
        /// of this `Ast`.
        pub const Val = ValOrSelf orelse *const Self;

        /// The type of apps
        pub const Apps = []const Self;

        /// The Pattern type specific to this Ast.
        pub const Pat = Pattern(Key, Var, KeyMapFn, VarMapFn, ValOrSelf);

        pub const KeyMap = Pat.KeyMap;
        pub const VarMap = Pat.VarMap;

        pub fn ofLit(key: Key) Self {
            return .{ .key = key };
        }

        pub fn ofApps(apps: []const Self) Self {
            return .{ .apps = apps };
        }

        /// Compares by value, not by len, pos, or pointers.
        pub fn order(self: Self, other: Self) Order {
            const ord = math.order(@intFromEnum(self), @intFromEnum(other));
            return if (ord == .eq)
                switch (self) {
                    .apps => |apps| util.orderWith(apps, other.apps, Self.order),
                    .@"var" => |v| mem.order(u8, v, other.@"var"),
                    .key => |key| key.order(other.key),
                    .pattern => |pat| pat.order(other.pattern),
                }
            else
                ord;
        }

        fn rewrite(
            apps: []const Self,
            allocator: Allocator,
            var_map: VarMap,
        ) Allocator.Error![]const Self {
            _ = var_map;
            _ = allocator;
            _ = apps;
        }

        pub fn write(self: Self, writer: anytype) !void {
            switch (self) {
                .apps => |apps| for (apps) |app|
                    if (std.meta.activeTag(app) == .apps) {
                        try writer.writeByte('(');
                        try app.write(writer);
                        try writer.writeByte(')');
                    } else {
                        try app.write(writer);
                        try writer.writeByte(' ');
                    },
                .@"var" => |v| try writer.writeAll(v),
                .key => |key| try writer.writeAll(key.lit),
                // .pattern => |pat| try pat.write(writer),
                else => @panic("unimplemented"),
            }
        }
    };
}

const meta = std.meta;
const ArenaAllocator = std.heap.ArenaAllocator;
const t = @import("test.zig");

///
/// A trie-like type based on the given term type. Each pattern contains zero or
/// more children.
///
/// The term and var type must be hashable, and must NOT contain any cycles.
/// TODO: reword this: Nodes track context, the recursive structures (map,
/// match) do not.
///
/// Params
/// `Key` - the type of literal keys
/// `Var` - the type of variable keys
/// `Val` - type of values that a successful key match will evaluate to
///
/// Note: must be used with an Ast of the same types, you probably want to
/// instantiate an Ast instead and alias it's `Pat` definition.
fn Pattern(
    comptime Key: type,
    comptime Var: type,
    comptime KeyMapFn: fn (type) type,
    comptime VarMapFn: fn (type) type,
    comptime ValOrSelf: ?type,
) type {
    return struct {
        pub const Self = @This();

        // pub const Val = ValOrSelf orelse *Ast(Key, Var, null);
        pub const AstType = Ast(Key, Var, KeyMapFn, VarMapFn, ValOrSelf);
        pub const Val = AstType.Val;
        pub const Apps = AstType.Apps;

        pub const KeyMap = KeyMapFn(Self);
        pub const VarMap = VarMapFn(Self);

        pub const PatMap = std.AutoArrayHashMapUnmanaged(
            *Self,
            Self,
        );

        pub const VarPat = struct {
            @"var": Var,
            next: ?*Self = null,
        };

        /// A Var matches and stores a locally-unique key. During rewriting,
        /// whenever the key is encountered again, it is rewritten to this
        /// pattern's value. A Var pattern matches anything, including nested
        /// patterns. It only makes sense to match anything after trying to
        /// match something specific, so Vars always successfully match (if
        /// there is a Var) after a Key or Subpat match fails.
        var_pat: ?VarPat = null,

        /// Nested patterns can also be keys because they are (probably) created
        /// deterministically, as long as they have only had elements inserted
        /// and not removed. This is empty when there are no / nested patterns in
        /// this pattern.
        // TODO: define a hash function for keys, including patterns.
        pat_map: PatMap = PatMap{},

        /// This is for nested apps that this pattern should match. Each layer
        /// of pointer redirection encodes a level of app nesting (parens).
        sub_pat: ?*Self = null,

        /// Maps literal terms to the next pattern, if there is one. These form
        /// the branches of the trie.
        map: KeyMap = KeyMap{},

        /// A null value represents an undefined pattern, for example in `Foo
        /// Bar -> 123`, the value at `Foo` would be null.
        val: ?Val = null,

        pub fn empty() Self {
            return Self{};
        }

        pub fn ofLit(
            allocator: Allocator,
            lit: Key,
            val: ?Val,
        ) !Self {
            var map = KeyMap{};
            try map.put(allocator, lit, Self{ .val = val });
            return .{
                .map = map,
            };
        }

        pub fn ofVar(@"var": Var, val: ?Val) Self {
            return .{
                .@"var" = @"var",
                .val = val,
            };
        }

        pub fn eql(self: Self, other: Self) bool {
            var iter = self.map.iterator();
            var other_iter = other.map.iterator();
            while (iter.next()) |next| {
                if (other_iter.next()) |other_next| {
                    // std.debug.print(
                    //     "\n{s}, {s}\n",
                    //     .{ next.key_ptr.*, other_next.key_ptr.* },
                    // );
                    if (util.deepEql(next, other_next))
                        continue;
                }
                return false;
            }
            return other_iter.next() == null and
                util.deepEql(self, other);
        }

        pub fn deepEql(self: Self, other: Self) bool {
            _ = other;
            _ = self;
        }

        pub const PrefixResult = struct {
            len: usize,
            pat_ptr: *Self,
        };

        /// Return a pointer to the last pattern in `pat` after the longest path
        /// matching `apps`. This pointer is valid unless reassigned in `pat`.
        /// If there is no last pattern (no apps matched) the same `pat` pointer
        /// will be return. If the entire `apps` is a prefix, a pointer to the
        /// last pat will be returned.
        pub fn matchPrefix(
            pat: *Self,
            allocator: Allocator,
            apps: []const AstType,
        ) Allocator.Error!PrefixResult {
            var current = pat;
            // Follow the longest branch that exists
            const prefix_len = for (apps, 0..) |app, i| switch (app) {
                .key => |key| {
                    if (current.map.getPtr(key)) |next|
                        current = next
                    else
                        break i;
                },
                .@"var" => |v| if (current.var_pat) |var_pat| {
                    _ = v;
                    if (var_pat.next) |var_next|
                        current = var_next;
                },
                .apps => |sub_apps| if (current.sub_pat) |sub_pat| {
                    const sub_prefix =
                        try sub_pat.matchPrefix(allocator, sub_apps);
                    // Check that the entire sub_apps matched sub_pat
                    if (sub_prefix.len == sub_apps.len)
                        continue
                    else
                        break i;
                },
                .pattern => |sub_pat| {
                    // TODO: lookup sub_pat in current's pat_map
                    _ = sub_pat;
                    @panic("unimplemented");
                },
            } else apps.len;

            return .{ .len = prefix_len, .pat_ptr = current };
        }

        /// Creates a new ast app containing the subset of `pat` that matches
        /// the longest matching prefix in 'apps'. Returns a usize describing
        /// this position in apps.
        /// The result is a tree of all branches that matched the pattern.
        // pub fn match(
        //     pat: Self,
        //     allocator: Allocator,
        //     apps: []const AstType,
        // ) Allocator.Error!?Val {
        //     // var var_map = VarMap{};
        //     const result = try pat.matchPrefix(allocator, apps);
        //     return if (result) |result_ptr|
        //         result_ptr.val
        //     else
        //         null;
        // }

        /// As a pattern is matched, a hashmap for vars is populated with
        /// each var's bound variable. These can the be used by the caller for
        /// rewriting.
        pub fn insert(
            pat: *Self,
            allocator: Allocator,
            apps: Apps,
            val: ?Val,
        ) Allocator.Error!bool {
            const prefix = try pat.matchPrefix(allocator, apps);
            var current = prefix.pat_ptr;

            // Create the rest of the branches
            for (apps[prefix.len..]) |ast| switch (ast) {
                .key => |key| switch (key.type) {
                    .Val, .Str, .Infix, .I, .F, .U => {
                        const put_result = try current.map.getOrPut(
                            allocator,
                            key,
                        );
                        current = put_result.value_ptr;
                        current.* = Self.empty();
                    },
                    .Var => {
                        const next = try allocator.create(Self);
                        next.* = Self.empty();
                        current.var_pat = .{
                            .@"var" = key.lit,
                            .next = next,
                        };
                        current = next;
                    },
                    else => @panic("unimplemented"),
                },
                else => @panic("unimplemented"),
            };
            const updated = current.val != null;
            // Put the value in this last node
            current.*.val = val;
            return updated;
        }

        /// Pretty print a pattern
        pub fn print(self: Self, writer: anytype) !void {
            try self.printIndent(writer, 0);
        }

        // TODO: add all pattern fields
        fn printIndent(self: Self, writer: anytype, indent: usize) !void {
            try writer.writeByte('|');
            if (self.val) |val| {
                try util.genericWrite(val, writer);
            }
            try writer.writeByte('|');
            try writer.print(" {s}\n", .{"{"});

            var iter = self.map.iterator();
            while (iter.next()) |entry| {
                for (0..indent + 4) |_|
                    try writer.print(" ", .{});

                try util.genericWrite(entry.key_ptr.*, writer);
                _ = try writer.write(" -> ");
                try entry.value_ptr.*.printIndent(writer, indent + 4);
            }
            for (0..indent) |_|
                try writer.print(" ", .{});

            try writer.print("{s}\n", .{"}"});
        }
    };
}

const testing = std.testing;

// for debugging with zig test --test-filter, comment this import
const verbose_tests = @import("build_options").verbose_tests;
// const stderr = if (true)
const stderr = if (verbose_tests)
    std.io.getStdErr().writer()
else
    std.io.null_writer;

test "Pattern: eql" {
    const TestAst = StringAst(void, usize);
    const Pat = TestAst.Pat;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p1 = Pat{};
    var p2 = Pat{
        .val = 123,
    };
    // Reverse order because patterns are values, not references
    try p2.map.put(
        allocator,
        "p1",
        Pat{ .val = 123 },
    );
    try p1.map.put(allocator, "Aa", p2);
    // try testing.expect(p1.eql(p2));

    // try p1.print(stderr);
    // try p2.print(stderr);
}

test "should behave like a set when given void" {
    const TestAst = AutoAst(usize, void, void);
    const Pat = TestAst.Pat;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    var pat = try Pat.ofLit(al, 123, {});
    _ = pat;
    // TODO: insert some apps here once insert is implemented
    // var nodes1: [1]Pat = undefined;
    // var nodes3: [3]Pat = undefined;
    // for (&nodes1, 0..) |*node, i| {
    //     node.* = Pat.ofLit(i, {}, {});
    // }
    // try testing.expectEqual(@as(?void, null), pat.match(nodes1));
    // try testing.expectEqual(@as(?void, null), pat.match(nodes3));

    // Empty pattern
    // try testing.expectEqual(@as(?void, {}), pat.match(.{
    //     .val = {},
    //     .kind = .{ .map = Pat.KeyMap{} },
    // }));
}

test "insert single lit" {}

test "insert multiple lits" {
    // Multiple keys
    // try pat.insert(&.{ 1, 2, 3 }, {}, al);
    // try testing.expect(pat.kind.map.contains(1));
}

test "compile: nested" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const TestAst = AutoAst(usize, void, void);
    const Pat = TestAst.Pat;
    var pat = try Pat.ofLit(al, 123, {});
    _ = try pat.matchPrefix(al, &.{});
    // Test nested
    // const Pat2 = Pat{};
    // Pat2.pat_map.put( &pat, 456 };
    // _ = Pat2;
}
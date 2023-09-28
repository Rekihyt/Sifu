const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;
const math = std.math;
const assert = std.debug.assert;
const util = @import("util.zig");
const Order = math.Order;
const Wyhash = std.hash.Wyhash;
const array_hash_map = std.array_hash_map;
const AutoContext = std.array_hash_map.AutoContext;
const StringContext = std.array_hash_map.StringContext;

// TODO: check if using []const u8, and use this instead maybe?
// pub const StringCtx = struct {
//     pub fn hasherUpdate(key: []const u8, hasher: anytype) void {
//         hasher.update(key);
//     }

//     pub fn eql(s1: []const u8, s2: []const u8) bool {
//         mem.eql(s1, s2);
//     }
// };

// - refactor node/pat creation api to use pat instead of node
// - convert hasherUpdate to hash and match the array_hash_map Context api
// - add hash or hasherUpdate and eql / eql + b_index option

pub fn AutoPattern(
    comptime Key: type,
    comptime Var: type,
) type {
    return AutoPatternOfVal(Key, Var, AutoContext(Key), AutoContext(Var), null);
}

pub fn AutoPatternOfVal(
    comptime Key: type,
    comptime Var: type,
    comptime Val: type,
) type {
    return PatternOfValWithContext(
        Key,
        Var,
        Val,
        AutoContext(Key),
        AutoContext(Var),
        AutoContext(Val),
    );
}

pub fn StringPattern(
    comptime Var: type,
    comptime VarCtx: type,
) type {
    return PatternOfValWithContext(
        []const u8,
        Var,
        null,
        StringContext,
        VarCtx,
        null,
    );
}

pub fn AutoStringPattern(
    comptime Var: type,
) type {
    return PatternOfValWithContext(
        []const u8,
        Var,
        null,
        StringContext,
        AutoContext(Var),
        null,
    );
}

pub fn AutoStringPatternOfVal(
    comptime Var: type,
    comptime Val: type,
) type {
    return PatternOfValWithContext(
        []const u8,
        Var,
        Val,
        StringContext,
        AutoContext(Var),
        AutoContext(Val),
    );
}

/// A pattern that uses a pointer to its own type as its value. Used for
/// parsing. Provided types must implement hash and eql.
pub fn Pattern(
    comptime Key: type,
    comptime Var: type,
) type {
    return PatternOfValWithContext(
        Key,
        Var,
        null,
        util.IntoArrayContext(Key),
        util.IntoArrayContext(Var),
        null,
    );
}

pub fn PatternOfVal(
    comptime Key: type,
    comptime Var: type,
    comptime Val: type,
    comptime ValContext: type,
) type {
    return PatternOfValWithContext(
        Key,
        Var,
        Val,
        util.IntoArrayContext(Key),
        util.IntoArrayContext(Var),
        ValContext,
    );
}

const meta = std.meta;
const ArenaAllocator = std.heap.ArenaAllocator;
const t = @import("test.zig");

// TODO: create a PatternWithContext function for basic and custom types that
// takes contexts and calls PatternOfVal with a new struct that stores both the
// original Keys / Vals with the new functions.
// TODO: don't ignore contexts functions

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
/// Contexts must be either nulls or structs with a type and two functions:
///    - `hasherUpdate` a hash function for `T`, of type `fn (T, anytype)
///        void` that updates a hasher (instead of a direct hash function for
///        efficiency)
///    - `eql` a function to compare two `T`s, of type `fn (T, T) bool`
/// Pass null for `ValOrSelf` and `ValOrSelfCtx` to use the instantiated
/// Node (the Self type in this struct definition) type as the Val type in
/// the Pattern, as it isn't possible to specify this before the type is
/// instantiated.
pub fn PatternOfValWithContext(
    comptime Key: type,
    comptime Var: type,
    comptime ValOrSelf: ?type,
    comptime KeyCtx: type,
    comptime VarCtx: type,
    comptime ValOrSelfCtx: ?type,
) type {
    return struct {
        pub const Self = @This();

        /// The type of apps
        pub const Apps = []const Node;

        /// The type that the `Pat` evaluates to after matching on an instance
        /// of this `Node`.
        pub const Val = ValOrSelf orelse *const Node;

        pub const ValCtx = ValOrSelfCtx orelse NodeCtx;

        const NodeCtx = struct {
            pub fn hash(self: @This(), node: *const Node) u32 {
                _ = self;
                return node.*.hash();
            }
            pub fn eql(
                self: @This(),
                node: *const Self,
                other: *const Self,
                b_index: usize,
            ) bool {
                _ = b_index;
                _ = self;
                return node.*.eql(other.*);
            }
        };

        const PatCtx = struct {
            pub fn hash(self: @This(), pat: *const Self) u32 {
                _ = self;
                return pat.*.hash();
            }
            pub fn eql(
                self: @This(),
                pat: *const Self,
                other: *const Self,
                b_index: usize,
            ) bool {
                _ = b_index;
                _ = self;
                return pat.*.eql(other.*);
            }
        };
        pub const KeyMap = std.ArrayHashMapUnmanaged(
            Key,
            Self,
            KeyCtx,
            true,
        );
        pub const VarMap = std.ArrayHashMapUnmanaged(
            Var,
            Self,
            VarCtx,
            true,
        );
        pub const PatMap = std.ArrayHashMapUnmanaged(
            *const Self,
            Self,
            PatCtx,
            true,
        );

        pub const VarPat = struct {
            @"var": Var,
            // A var pat might not necessarily have a next pattern (the var is
            // at the end)
            next: ?*Self = null,
            // The value for the var pattern
            val: ?Val = null,

            pub const hash = util.hashFromHasherUpdate(VarPat);

            pub fn hasherUpdate(self: VarPat, hasher: anytype) void {
                hasher.update(&mem.toBytes(VarCtx.hash(undefined, self.@"var")));
                if (self.next) |next|
                    next.hasherUpdate(hasher);

                if (self.val) |val|
                    hasher.update(&mem.toBytes(ValCtx.hash(undefined, val)));
            }

            pub fn eql(
                self: VarPat,
                other: VarPat,
            ) bool {
                if (self.next) |self_next| {
                    return if (other.next) |other_next|
                        self_next.eql(other_next)
                    else
                        false;
                } else return other.next == null;

                return VarCtx.eql(
                    undefined,
                    self.@"var",
                    other.@"var",
                    undefined,
                ) and
                    ValCtx.eql(undefined, self.val, other.val, undefined);
            }
        };

        /// An Node is a single value or tree. Together, multiple Nodes are
        /// encoded in a pattern. In Sifu, it is also the structure given
        /// to a source code entry (a `Node(Token)`). It infix, nesting, and
        /// separator operators but does not differentiate between builtins.
        /// The `Key` is a custom type to allow storing of metainfo such as a
        /// position, and must implement `toString()` for pattern conversion. It
        /// could also be a simple type for optimization purposes.
        pub const Node = union(enum) {
            key: Key,
            @"var": Var,
            apps: Apps,
            pat: Self,

            pub const VarRewriteMap = std.ArrayHashMapUnmanaged(
                Var,
                Self,
                VarCtx,
                true,
            );

            pub const hash = util.hashFromHasherUpdate(Node);

            pub fn hasherUpdate(self: Node, hasher: anytype) void {
                hasher.update(&mem.toBytes(@intFromEnum(self)));
                switch (self) {
                    .apps => |apps| for (apps) |app|
                        app.hasherUpdate(hasher),
                    .@"var" => |v| hasher.update(&mem.toBytes(VarCtx.hash(undefined, v))),
                    .key => |k| hasher.update(&mem.toBytes(KeyCtx.hash(undefined, k))),
                    .pat => |p| p.hasherUpdate(hasher),
                }
            }

            pub fn eql(node: Node, other: Node) bool {
                return if (@intFromEnum(node) != @intFromEnum(other))
                    false
                else switch (node) {
                    .apps => |apps| apps.len == other.apps.len and for (
                        apps,
                        other.apps,
                    ) |app, other_app| {
                        if (!app.eql(other_app))
                            break false;
                    } else true,

                    .@"var" => |v| VarCtx.eql(undefined, v, other.@"var", undefined),
                    .key => |k| KeyCtx.eql(undefined, k, other.key, undefined),
                    .pat => |p| p.eql(other.pat),
                };
            }

            pub fn ofLit(key: Key) Node {
                return .{ .key = key };
            }

            pub fn ofApps(apps: Apps) Node {
                return .{ .apps = apps };
            }

            /// Compares by value, not by len, pos, or pointers.
            pub fn order(self: Node, other: Node) Order {
                const ord = math.order(@intFromEnum(self), @intFromEnum(other));
                return if (ord == .eq)
                    switch (self) {
                        .apps => |apps| util.orderWith(
                            apps,
                            other.apps,
                            Node.order,
                        ),
                        .@"var" => |v| mem.order(u8, v, other.@"var"),
                        .key => |key| key.order(other.key),
                        .pat => |pat| pat.order(other.pat),
                    }
                else
                    ord;
            }

            fn rewrite(
                apps: Apps,
                allocator: Allocator,
                var_map: VarRewriteMap,
            ) Allocator.Error!Apps {
                _ = var_map;
                _ = allocator;
                _ = apps;
            }

            pub fn write(self: Node, writer: anytype) !void {
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
                    .pat => |pat| try pat.print(writer),
                }
            }
        };

        pub const PrefixResult = struct {
            len: usize,
            pat_ptr: *Self,
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

        // = util.hashFromHasherUpdate(Self, hasherUpdate);
        pub fn hash(self: Self) u32 {
            var hasher = Wyhash.init(0);
            self.hasherUpdate(&hasher);
            return @truncate(hasher.final());
        }

        pub fn hasherUpdate(pat: Self, hasher: anytype) void {
            if (pat.var_pat) |var_pat|
                var_pat.hasherUpdate(hasher);

            for (pat.map.keys()) |key|
                hasher.update(&mem.toBytes(KeyCtx.hash(undefined, key)));
            for (pat.pat_map.keys()) |p|
                p.hasherUpdate(hasher);

            // TODO: add comptime if for hashing vals in a pattern
            for (pat.map.values()) |p|
                p.hasherUpdate(hasher);
            for (pat.pat_map.values()) |p|
                p.hasherUpdate(hasher);

            if (pat.val) |val|
                hasher.update(&mem.toBytes(ValCtx.hash(undefined, val)));

            if (pat.sub_pat) |sub_pat|
                sub_pat.hasherUpdate(hasher);
        }

        pub fn eql(self: Self, other: Self) bool {
            _ = other;
            _ = self;
            // return KeyCtx.eql(undefined, self.key, other.key, undefined) and
            //     VarCtx.eql(undefined, self.@"var", other.@"var", undefined) and
            //     ValCtx.eql(undefined, self.val, other.val, undefined);
            return false;
        }

        pub fn ofVar(@"var": Var, val: ?Val) Self {
            return .{
                .@"var" = @"var",
                .val = val,
            };
        }

        /// Return a pointer to the last pattern in `pat` after the longest path
        /// matching `apps`. This pointer is valid unless reassigned in `pat`.
        /// If there is no last pattern (no apps matched) the same `pat` pointer
        /// will be return. If the entire `apps` is a prefix, a pointer to the
        /// last pat will be returned.
        /// - Any Node matches a var pattern including a var
        /// - A var Node doesn't match a non-var pattern (var matching is one
        ///    way)
        /// - A literal Node that matches a literal-var pattern matches the
        ///    literal part, not the var
        pub fn matchPrefix(
            pat: *Self,
            allocator: Allocator,
            apps: Apps,
        ) Allocator.Error!PrefixResult {
            var current = pat;
            // Follow the longest branch that exists
            const prefix_len = for (apps, 0..) |app, i| {
                const next = switch (app) {
                    .key => |key| current.map.getPtr(key),

                    // vars with different names are "equal"
                    // TODO: update var map
                    .@"var" => |_| if (current.var_pat) |var_pat|
                        var_pat.next
                    else
                        null,

                    .apps => |sub_apps| blk: {
                        const sub_pat = current.sub_pat orelse
                            break :blk null;

                        const sub_prefix =
                            try sub_pat.matchPrefix(allocator, sub_apps);
                        // Check that the entire sub_apps matched sub_pat
                        if (sub_prefix.len != sub_apps.len)
                            break :blk null;

                        break :blk sub_pat;
                    },

                    .pat => |node_pat| current.pat_map.getPtr(&node_pat),
                };
                if (next) |next_pat|
                    current = next_pat
                else
                    break i;
            } else apps.len;

            return .{ .len = prefix_len, .pat_ptr = current };
        }

        /// Creates a new node app containing the subset of `pat` that matches
        /// the longest matching prefix in 'apps'. Returns a usize describing
        /// this position in apps.
        /// The result is a tree of all branches that matched the pattern.
        pub fn match(
            pat: Self,
            allocator: Allocator,
            apps: []const Node,
        ) Allocator.Error!?Val {
            // var var_map = VarMap{};
            const result = try pat.matchPrefix(allocator, apps);
            return if (result) |result_ptr|
                result_ptr.val
            else
                null;
        }

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
            for (apps[prefix.len..]) |node| switch (node) {
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
            const updated = current.*.val != null;
            // Put the value in this last node
            current.*.val = val;
            return updated;
        }

        /// Pretty print a pattern
        pub fn print(self: Self, writer: anytype) !void {
            try self.printIndent(writer, 0);
        }

        // TODO: add all pattern fields
        fn printIndent(
            self: Self,
            writer: anytype,
            indent: usize,
        ) @TypeOf(writer).Error!void {
            try writer.writeByte('|');
            if (self.val) |val| {
                try val.write(writer);
            }
            try writer.writeByte('|');
            try writer.print(" {s}\n", .{"{"});

            var iter = self.map.iterator();
            while (iter.next()) |entry| {
                for (0..indent + 4) |_|
                    try writer.print(" ", .{});

                _ = try entry.key_ptr.write(writer);
                _ = try writer.write(" -> ");
                try entry.value_ptr.printIndent(writer, indent + 4);
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
    const Pat = AutoStringPatternOfVal(void, usize);
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
    const Pat = AutoPatternOfVal(usize, void, void);
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
    const Pat = AutoPatternOfVal(usize, void, void);
    var pat = try Pat.ofLit(al, 123, {});
    _ = try pat.matchPrefix(al, &.{});
    // Test nested
    // const Pat2 = Pat{};
    // Pat2.pat_map.put( &pat, 456 };
    // _ = Pat2;
}

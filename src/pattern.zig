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
const print = std.debug.print;

pub fn AutoPattern(
    comptime Key: type,
    comptime Var: type,
) type {
    if (Key == []const u8)
        @compileError(
            \\Cannot make a pattern automatically from []const u8,
            \\please use AutoStringPattern instead.
        );
    return PatternWithContext(Key, Var, AutoContext(Key), AutoContext(Var));
}

pub fn StringPattern(
    comptime Var: type,
    comptime VarCtx: type,
) type {
    return PatternWithContext([]const u8, Var, StringContext, VarCtx);
}

pub fn AutoStringPattern(
    comptime Var: type,
) type {
    return PatternWithContext([]const u8, Var, StringContext, AutoContext(Var));
}

/// A pattern that uses a pointer to its own type as its node. Used for
/// parsing. Provided types must implement hash and eql.
pub fn Pattern(
    comptime Key: type,
    comptime Var: type,
) type {
    return PatternWithContext(
        Key,
        Var,
        util.IntoArrayContext(Key),
        util.IntoArrayContext(Var),
    );
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
///
/// Contexts must be either nulls or structs with a type and two functions:
///    - `hasherUpdate` a hash function for `T`, of type `fn (T, anytype)
///        void` that updates a hasher (instead of a direct hash function for
///        efficiency)
///    - `eql` a function to compare two `T`s, of type `fn (T, T) bool`
pub fn PatternWithContext(
    comptime Key: type,
    comptime Var: type,
    comptime KeyCtx: type,
    comptime VarCtx: type,
) type {
    return struct {
        pub const Self = @This();

        pub const KeyMap = std.ArrayHashMapUnmanaged(
            Key,
            Self,
            KeyCtx,
            true,
        );
        pub const VarMap = std.ArrayHashMapUnmanaged(
            Var,
            Node,
            VarCtx,
            true,
        );
        pub const PatMap = std.ArrayHashMapUnmanaged(
            Self,
            Self,
            util.IntoArrayContext(Self),
            true,
        );

        /// Nodes form the keys and values of a pattern type (its recursive
        /// structure forces both to be the same type). In Sifu, it is also the
        /// structure given to a source code entry (a `Node(Token)`). It encodes
        /// sequences, nesting, and patterns.
        /// The `Key` is a custom type to allow storing of metainfo such as a
        /// position, and must implement `toString()` for pattern conversion. It
        /// could also be a simple type for optimization purposes.
        pub const Node = union(enum) {
            key: Key,
            @"var": Var,
            apps: []const Node,
            pat: *Self,

            pub const VarRewriteMap = std.ArrayHashMapUnmanaged(
                Var,
                Self,
                VarCtx,
                true,
            );

            /// Performs a deep copy, resulting in a Node the same size as the
            /// original.
            /// The copy should be freed with `deleteChildren`.
            pub fn copy(self: Node, allocator: Allocator) Allocator.Error!Node {
                return switch (self) {
                    .key, .@"var" => self,
                    .pat => |p| try Node.ofPat(allocator, try p.copy(allocator)),
                    .apps => |apps| blk: {
                        var apps_copy = try allocator.alloc(Node, apps.len);
                        for (apps, apps_copy) |app, *app_copy|
                            app_copy.* = try app.copy(allocator);

                        break :blk Node.ofApps(apps_copy);
                    },
                };
            }

            pub fn delete(self: *Node, allocator: Allocator) void {
                self.deleteChildren(allocator);
                allocator.destroy(self);
            }

            pub fn deleteChildren(self: *Node, allocator: Allocator) void {
                switch (self.*) {
                    .key, .@"var" => {},
                    .pat => |p| p.delete(allocator),
                    .apps => |apps| {
                        for (apps) |*app|
                            @constCast(app).deleteChildren(allocator);

                        allocator.free(apps);
                    },
                }
            }

            pub const hash = util.hashFromHasherUpdate(Node);

            pub fn hasherUpdate(self: Node, hasher: anytype) void {
                hasher.update(&mem.toBytes(@intFromEnum(self)));
                switch (self) {
                    .apps => |apps| for (apps) |app|
                        app.hasherUpdate(hasher),
                    .@"var" => |v| hasher.update(
                        &mem.toBytes(VarCtx.hash(undefined, v)),
                    ),
                    .key => |k| hasher.update(
                        &mem.toBytes(KeyCtx.hash(undefined, k)),
                    ),
                    .pat => |p| p.hasherUpdate(hasher),
                }
            }

            pub fn eql(node: Node, other: Node) bool {
                return if (@intFromEnum(node) != @intFromEnum(other))
                    false
                else switch (node) {
                    .apps => |apps| apps.len == other.apps.len and
                        for (apps, other.apps) |app, other_app|
                    {
                        if (!app.eql(other_app))
                            break false;
                    } else true,

                    .@"var" => |v| VarCtx.eql(
                        undefined,
                        v,
                        other.@"var",
                        undefined,
                    ),
                    .key => |k| KeyCtx.eql(undefined, k, other.key, undefined),
                    .pat => |p| p.eql(other.pat.*),
                };
            }

            pub fn ofLit(key: Key) Node {
                return .{ .key = key };
            }
            pub fn ofVar(@"var": Var) Node {
                return .{ .@"var" = @"var" };
            }

            pub fn ofApps(apps: []const Node) Node {
                return .{ .apps = apps };
            }

            pub fn createKey(
                allocator: Allocator,
                key: Key,
            ) Allocator.Error!*Node {
                var node = try allocator.create(Node);
                node.* = Node{ .key = key };
                return node;
            }

            /// Lifetime of `apps` must be longer than this Node.
            pub fn createApps(
                allocator: Allocator,
                apps: []const Node,
            ) Allocator.Error!*Node {
                var node = try allocator.create(Node);
                node.* = Node{ .apps = apps };
                return node;
            }

            pub fn createPat(
                allocator: Allocator,
                pat: Self,
            ) Allocator.Error!*Node {
                const node = try allocator.create(Node);
                const pat_ptr = try allocator.create(Self);
                pat_ptr.* = pat;
                node.* = Node{ .pat = pat_ptr };
                return node;
            }

            pub fn ofPat(
                allocator: Allocator,
                pat: Self,
            ) Allocator.Error!Node {
                const pat_ptr = try allocator.create(Self);
                pat_ptr.* = pat;
                return Node{ .pat = pat_ptr };
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
                apps: []const Node,
                allocator: Allocator,
                var_map: VarRewriteMap,
            ) Allocator.Error![]Node {
                _ = var_map;
                _ = allocator;
                _ = apps;
            }

            fn writeSExp(
                self: Node,
                writer: anytype,
                optional_indent: ?usize,
            ) !void {
                if (optional_indent) |indent| for (0..indent) |_|
                    try writer.writeByte(' ');
                switch (self) {
                    .apps => |apps| {
                        try writer.writeByte('(');
                        for (apps) |app| {
                            try app.writeSExp(writer, optional_indent);
                            try writer.writeByte(' ');
                        }
                        try writer.writeByte(')');
                    },
                    .@"var" => |@"var"| _ = try util.genericWrite(@"var", writer),
                    .key => |key| _ = try util.genericWrite(key, writer),
                    .pat => |pat| try pat.writeIndent(writer, optional_indent),
                }
            }

            pub fn write(
                self: Node,
                writer: anytype,
            ) !void {
                return self.writeIndent(writer, 0);
            }

            pub fn writeIndent(
                self: Node,
                writer: anytype,
                optional_indent: ?usize,
            ) !void {
                switch (self) {
                    .apps => |apps| for (apps) |app| {
                        try app.writeSExp(writer, optional_indent);
                        try writer.writeByte(' ');
                    },
                    else => try self.writeSExp(writer, optional_indent),
                }
            }
        };

        /// The results of matching a pattern exactly (vars are matched literally
        /// instead of by building up a tree of their possible values)
        pub const ExactPrefixResult = struct {
            len: usize,
            end_ptr: *const Self,
        };

        /// The longest prefix matching a pattern, where vars match all possible
        /// expressions.
        pub const PrefixResult = struct {
            len: usize,
            end_ptr: *const Self,
        };

        /// A Var matches and stores a locally-unique key. During rewriting,
        /// whenever the key is encountered again, it is rewritten to this
        /// pattern's val. A Var pattern matches anything, including nested
        /// patterns. It only makes sense to match anything after trying to
        /// match something specific, so Vars always successfully match (if
        /// there is a Var) after a Key or Subpat match fails.
        option_var: ?Var = null,
        var_next: ?*Self = null,

        /// Nested patterns can also be keys because they are (probably) created
        /// deterministically, as long as they have only had elements inserted
        /// and not removed. This is empty when there are no / nested patterns in
        /// this pattern.
        pat_map: PatMap = PatMap{},

        /// This is for nested apps that this pattern should match. Each layer
        /// of pointer redirection encodes a level of app nesting (parens).
        sub_pat: ?*Self = null,

        /// Maps literal terms to the next pattern, if there is one. These form
        /// the branches of the trie.
        map: KeyMap = KeyMap{},

        /// A null val represents an undefined pattern, for example in `Foo
        /// Bar -> 123`, the val at `Foo` would be null.
        val: ?*Node = null,

        pub fn ofVal(
            allocator: Allocator,
            optional_val: ?Key,
        ) Allocator.Error!Self {
            return Self{
                .val = if (optional_val) |val|
                    try Node.createKey(allocator, val)
                else
                    null,
            };
        }
        pub fn copy(self: Self, allocator: Allocator) Allocator.Error!Self {
            var result = Self{};
            var map_iter = self.map.iterator();
            while (map_iter.next()) |entry|
                try result.map.putNoClobber(
                    allocator,
                    entry.key_ptr.*,
                    try entry.value_ptr.copy(allocator),
                );

            var pat_map_iter = self.pat_map.iterator();
            while (pat_map_iter.next()) |entry| {
                // const new_key_ptr = try allocator.create(Self);
                // new_key_ptr.* = try entry.key_ptr.*.copy(allocator);

                try result.pat_map.putNoClobber(
                    allocator,
                    try entry.key_ptr.*.copy(allocator),
                    try entry.value_ptr.*.copy(allocator),
                );
            }
            if (self.val) |val| {
                result.val = try allocator.create(Node);
                result.val.?.* = try val.copy(allocator);
            }
            if (self.sub_pat) |sub_pat| {
                result.sub_pat = try allocator.create(Self);
                result.sub_pat.?.* = try sub_pat.copy(allocator);
            }
            result.option_var = self.option_var;
            if (self.var_next) |var_next| {
                result.var_next = try allocator.create(Self);
                result.var_next.?.* = try var_next.copy(allocator);
            }
            return result;
        }

        /// Frees all memory recursively, leaving the Pattern in an undefined state.
        /// The `self` pointer must have been allocated with `allocator`.
        pub fn delete(self: *Self, allocator: Allocator) void {
            self.deleteChildren(allocator);
            allocator.destroy(self);
        }

        pub fn deleteChildren(self: *Self, allocator: Allocator) void {
            for (self.map.values()) |*pat|
                pat.deleteChildren(allocator);

            self.map.deinit(allocator);

            for (self.pat_map.keys()) |*pat|
                pat.deleteChildren(allocator);
            // Pattern/Node values must be deleted because they are allocated
            // recursively
            for (self.pat_map.values()) |*pat|
                pat.deleteChildren(allocator);

            self.pat_map.deinit(allocator);

            if (self.var_next) |var_next|
                var_next.delete(allocator);

            if (self.val) |val|
                // Value nodes are allocated recursively
                val.delete(allocator);

            if (self.sub_pat) |sub_pat|
                sub_pat.delete(allocator);
        }

        pub fn hash(self: Self) u32 {
            var hasher = Wyhash.init(0);
            self.hasherUpdate(&hasher);
            return @truncate(hasher.final());
        }

        pub fn hasherUpdate(self: Self, hasher: anytype) void {
            for (self.map.keys()) |key|
                hasher.update(&mem.toBytes(KeyCtx.hash(undefined, key)));
            for (self.pat_map.keys()) |p|
                p.hasherUpdate(hasher);

            for (self.map.values()) |p|
                p.hasherUpdate(hasher);
            for (self.pat_map.values()) |p|
                p.hasherUpdate(hasher);

            if (self.option_var) |v|
                hasher.update(&mem.toBytes(VarCtx.hash(undefined, v)));
            if (self.var_next) |var_next|
                var_next.*.hasherUpdate(hasher);

            if (self.val) |val|
                hasher.update(&mem.toBytes(val.hash()));

            if (self.sub_pat) |sub_pat|
                sub_pat.hasherUpdate(hasher);
        }

        fn keyEql(k1: Key, k2: Key) bool {
            return KeyCtx.eql(undefined, k1, k2, undefined);
        }

        pub fn eql(self: Self, other: Self) bool {
            const var_eql = if (self.option_var) |self_var|
                if (other.option_var) |other_var|
                    VarCtx.eql(undefined, self_var, other_var, undefined)
                else
                    false
            else
                other.option_var == null and
                    if (self.var_next) |self_next|
                    if (other.var_next) |other_next|
                        self_next.*.eql(other_next.*)
                    else
                        false
                else
                    other.var_next == null;
            if (!var_eql) return false;

            const val_eql = if (self.val) |self_val|
                if (other.val) |other_val|
                    self_val.*.eql(other_val.*)
                else
                    false
            else
                other.val == null;
            if (!val_eql) return false;

            const sub_pat_eql = if (self.sub_pat) |self_sub_pat|
                if (other.sub_pat) |other_sub_pat|
                    self_sub_pat.*.eql(other_sub_pat.*)
                else
                    false
            else
                other.sub_pat == null;
            if (!sub_pat_eql) return false;

            _ = util.sliceEql(self.map.keys(), other.map.keys(), keyEql) or
                return false;

            _ = util.sliceEql(self.map.values(), other.map.values(), Self.eql) or
                return false;

            _ = util.sliceEql(
                self.pat_map.keys(),
                other.pat_map.keys(),
                struct {
                    pub fn eq(p1: Self, p2: Self) bool {
                        return p1.eql(p2);
                    }
                }.eq,
            ) or
                return false;

            _ = util.sliceEql(
                self.pat_map.values(),
                other.pat_map.values(),
                Self.eql,
            ) or
                return false;

            return true;
        }

        pub fn create(allocator: Allocator) !*Self {
            const result = try allocator.create(Self);
            result.* = Self{};
            return result;
        }

        /// Like matchExactPrefix but matches only a single node exactly.
        pub fn matchExactNode(pat: *const Self, node: Node) ?*Self {
            // switch (node) {
            //     .key => |key| if (pat.map.getPtr(key)) |lit_match|
            //         lit_match.write(stderr) catch unreachable,
            //     else => {},
            // }
            return switch (node) {
                .key => |key| pat.map.getPtr(key),

                // vars with different names are "equal"
                .@"var" => pat.var_next,

                .apps => |sub_apps| blk: {
                    const sub_pat = pat.sub_pat orelse
                        break :blk null;

                    // Check that the entire sub_apps matched sub_pat
                    const sub_prefix = sub_pat.matchExactPrefix(sub_apps);

                    // print("Matched sub_prefix {}\n", .{sub_prefix.len == sub_apps.len});
                    // If there isn't a node for another pattern, this
                    // match fails
                    const next_node = sub_prefix.end_ptr.val orelse
                        break :blk null;

                    // Match sub_pat, move to its value, which is also
                    // always a pattern even though it is wrapped in a Node
                    break :blk if (sub_prefix.len == sub_apps.len)
                        next_node.pat
                    else
                        null;
                },
                .pat => |node_pat| pat.pat_map.getPtr(node_pat.*),
            };
        }

        /// Return a pointer to the last pattern in `pat` after the longest path
        /// matching `apps`. This is an exact match, so variables only match
        /// variables and a subpattern will be returned. This pointer is valid
        /// unless reassigned in `pat`.
        /// If there is no last pattern (no apps matched) the same `pat` pointer
        /// will be returned. If the entire `apps` is a prefix, a pointer to the
        /// last pat will be returned.
        /// Although `pat` isn't modified, the val (if any) returned from it
        /// is modifiable by the caller
        pub fn matchExactPrefix(
            pat: *const Self,
            apps: []const Node,
        ) ExactPrefixResult {
            var current = pat;
            // Follow the longest branch that exists
            const prefix_len = for (apps, 0..) |app, i| {
                current = current.matchExactNode(app) orelse
                    break i;
            } else apps.len;

            // print("Matched prefix:\n", .{});
            // const prefix = Node{ .apps = apps[0..prefix_len] };
            // prefix.write(stderr) catch unreachable;
            // print("\n", .{});

            return .{ .len = prefix_len, .end_ptr = @constCast(current) };
        }

        /// Follows `pat` for each app matching structure as well as value.
        /// Does not require allocation because variable branches are not
        /// explored, but rather followed.
        pub fn matchExact(
            pat: *const Self,
            apps: []const Node,
        ) ?*Node {
            // var var_map = VarMap{};
            const prefix = pat.matchExactPrefix(apps);
            // print("Result: ", .{});
            // prefix.end_ptr.val.?.write(stderr) catch unreachable;
            return if (prefix.len == apps.len)
                prefix.end_ptr.val
            else
                null;
        }

        /// Matching a prefix where vars match anything in the pattern, and vars
        /// in the pattern match anything in the expression. Includes partial
        /// prefixes (ones that don't match all apps).
        /// - Any Node matches a var pattern including a var
        /// - A var Node doesn't match a non-var pattern (var matching is one
        ///    way)
        /// - A literal Node that matches a literal-var pattern matches the
        ///    literal part, not the var
        pub fn matchPrefixes(
            pat: *const Self,
            allocator: Allocator,
            apps: []const Node,
        ) Allocator.Error![]PrefixResult {
            var prefixes = std.ArrayListUnmanaged(PrefixResult){};
            var current = pat;
            var var_map = VarMap{};
            defer var_map.deinit(allocator);
            // Follow the longest branch that exists
            const prefix_len = for (apps, 0..) |app, i| switch (app) {
                // TODO: possible bug, not updating current node
                // TODO: append prefix as well
                .@"var" => |@"var"| {
                    const result = try var_map.getOrPut(allocator, @"var");
                    // If a var was already bound, just check its value is
                    // equal to this one
                    if (result.found_existing and result.value_ptr.*.eql(app))
                        continue
                        // Otherwise iterate over all entries in this pattern and
                        // try to match a prefix for each
                    else {
                        for (current.map.values()) |val|
                            try prefixes.appendSlice(
                                allocator,
                                try val.matchPrefixes(allocator, apps[1..]),
                            );
                        for (current.pat_map.values()) |val|
                            try prefixes.appendSlice(
                                allocator,
                                try val.matchPrefixes(allocator, apps[1..]),
                            );
                        if (current.sub_pat) |sub_pat|
                            try prefixes.appendSlice(
                                allocator,
                                try sub_pat.matchPrefixes(allocator, apps[1..]),
                            );
                        if (current.var_next) |var_next|
                            try prefixes.appendSlice(
                                allocator,
                                try var_next.matchPrefixes(allocator, apps[1..]),
                            );
                    }
                },
                else => {
                    // Exact matches should preclude any var matches
                    current = current.matchExactNode(app) orelse blk: {
                        // If nothing matched, default to current's var, if any
                        if (current.option_var) |v| {
                            const result = try var_map.getOrPut(allocator, v);
                            // If a previous var was bound, check that the
                            // current key matches it
                            if (result.found_existing) {
                                if (!result.value_ptr.*.eql(app))
                                    continue;
                            } else result.value_ptr.* = app;

                            if (current.var_next) |var_next|
                                break :blk var_next;

                            break i + 1;
                        }
                        break i;
                    };
                    print("Current updated\n", .{});
                },
            } else apps.len;

            // print("Matched prefix:\n", .{});
            const prefix = PrefixResult{ .end_ptr = current, .len = prefix_len };
            try prefixes.append(allocator, prefix);
            print("Prefix len: {}\n", .{prefix_len});

            return try prefixes.toOwnedSlice(allocator);
        }

        /// Follows `pat` for each app matching by value, or all apps for var
        /// patterns. Creates a new node app containing the subset of `pat`
        /// that matches the longest matching prefix in 'apps'. Returns a usize
        /// describing this position in apps. The result is an array of all
        /// matches.
        pub fn match(
            pat: *Self,
            allocator: Allocator,
            apps: []const Node,
        ) ![]?*Node {
            var prefixes = try pat.matchPrefixes(allocator, apps);
            var matches = std.ArrayListUnmanaged(?*Node){};
            // prefix.end_ptr.val.?.write(stderr) catch unreachable;
            print("Prefixes : {}\n", .{prefixes.len});
            for (prefixes) |prefix| {
                try stderr.print("\tPrefix len: {}, Apps len: {}\n", .{ prefix.len, apps.len });
                print("\tEnd pointer value: ", .{});
                if (prefix.end_ptr.val) |val| val.write(stderr) catch
                    unreachable else print("null", .{});
                print("\n", .{});
                if (prefix.len == apps.len)
                    // Unwrap the val as pat, because it is always inserted as such
                    try matches.append(allocator, if (prefix.end_ptr.val) |val|
                        val
                    else
                        null);
            }

            return try matches.toOwnedSlice(allocator);
        }

        /// Add a node to the pattern by following `keys`, wrapping them into an
        /// App of Nodes.
        /// Allocations:
        /// - The path followed by apps is allocated and copied recursively
        /// - The node, if given, is allocated and copied recursively
        /// Freeing should be done with `delete` or `deleteChildren`, depending
        /// on how `self` was allocated
        pub fn insertKeys(
            self: *Self,
            allocator: Allocator,
            keys: []const Key,
            optional_node: ?Node,
        ) Allocator.Error!*Self {
            const apps = try allocator.alloc(Node, keys.len);
            defer allocator.free(apps);
            for (apps, 0..) |*node, i|
                node.* = Node.ofLit(keys[i]);

            return self.insert(
                allocator,
                apps,
                optional_node,
            );
        }

        /// Add a node to the pattern by following `apps`.
        /// Allocations:
        /// - The path followed by apps is allocated and copied recursively
        /// - The node, if given, is allocated and copied recursively
        /// Freeing should be done with `delete` or `deleteChildren`, depending
        /// on how `self` was allocated
        pub fn insert(
            self: *Self,
            allocator: Allocator,
            apps: []const Node,
            optional_val: ?Node,
        ) Allocator.Error!*Self {
            var result = try self.getOrPut(allocator, apps);
            // Clear existing value node
            if (result.end_ptr.val) |prev_val| {
                prev_val.delete(allocator);
                result.end_ptr.val = null;
            }
            // Add new value node
            if (optional_val) |val| {
                const new_val = try allocator.create(Node);
                // TODO: check found existing
                new_val.* = try val.copy(allocator);
                // stderr.print("Node ptr: {*}\n", .{result.end_ptr.val}) catch
                // unreachable;
                result.end_ptr.val = new_val;
            }
            return result.end_ptr;
        }

        // / Because of the recursive type, we need to use a *Node
        // / here instead of a *Pat, so any pattern gets wrapped into
        // / a `Node.pat`.

        /// Get a reference to this pattern's `node`, creating one if it
        /// doesn't already exist.
        ///
        /// Returns a pointer to uninitialized memory.
        pub fn getValPtr(self: *Self, allocator: Allocator) !*Node {
            const val: *Node = self.val orelse
                try allocator.create(Node);

            self.val = val;
            return val;
        }

        /// Similar to ArrayHashMap's type, but the index is specific to the
        /// last hashmap.
        pub const GetOrPutResult = struct {
            end_ptr: *Self,
            found_existing: bool,
            index: usize,
        };

        /// As a pattern is matched, a hashmap for vars is populated with
        /// each var's bound variable. These can the be used by the caller for
        /// rewriting.
        pub fn getOrPut(
            pat: *Self,
            allocator: Allocator,
            apps: []const Node,
        ) Allocator.Error!GetOrPutResult {
            const prefix = pat.matchExactPrefix(apps);
            var current = @constCast(prefix.end_ptr);
            var found_existing = true;
            // print("Prefix len: {}\n", .{prefix.len});

            // Create the rest of the branches
            for (apps[prefix.len..]) |app| switch (app) {
                .key => |key| {
                    const put_result = try current.map.getOrPut(allocator, key);
                    current = put_result.value_ptr;
                    if (!put_result.found_existing) {
                        found_existing = false;
                        current.* = Self{};
                    }
                },
                .@"var" => |v| {
                    current.option_var = v;
                    if (current.var_next == null)
                        found_existing = false;
                    current = try util.getOrInit(.var_next, current, allocator);
                },
                .apps => |sub_apps| {
                    if (current.sub_pat == null)
                        found_existing = false;
                    const sub_pat =
                        try util.getOrInit(.sub_pat, current, allocator);
                    const put_result = try sub_pat.getOrPut(allocator, sub_apps);
                    if (!put_result.found_existing)
                        found_existing = false;

                    const next_pat = try put_result.end_ptr.getValPtr(allocator);
                    // next_pat.write(stderr) catch unreachable;

                    current = next_pat.pat;
                },
                .pat => |p| {
                    const put_result = try current.pat_map.getOrPut(
                        allocator,
                        try p.copy(allocator),
                    );
                    // Move to the next pattern
                    current = put_result.value_ptr;

                    // Initialize it if not already
                    if (!put_result.found_existing) {
                        found_existing = false;
                        current.* = Self{};
                    }
                },
            };
            return GetOrPutResult{
                .end_ptr = current,
                .found_existing = found_existing,
                .index = 0, // TODO
            };
        }

        /// Pretty print a pattern
        pub fn pretty(self: Self, writer: anytype) !void {
            try self.writeIndent(writer, 0);
        }

        pub fn write(self: Self, writer: anytype) !void {
            try writer.writeByte('|');
            if (self.val) |val| {
                try val.writeIndent(writer, null);
            }
            try writer.writeAll("| {");

            try writeMap(self.map, writer, null);

            if (self.option_var) |v|
                try util.genericWrite(v, writer);
            if (self.var_next) |var_next|
                try var_next.write(writer);

            if (self.sub_pat) |sub_pat| {

                // print("Subpat: {}\n", .{sub_pat.map.count()});
                try sub_pat.write(writer);
            }
            try writer.writeAll("}");
        }

        pub const indent_increment = 2;
        fn writeIndent(
            self: Self,
            writer: anytype,
            optional_indent: ?usize,
        ) @TypeOf(writer).Error!void {
            if (self.val) |val| {
                try writer.writeAll("| ");
                try val.writeIndent(writer, null);
                try writer.writeAll("| ");
            }

            try writer.writeByte('{');
            try writer.writeAll(
                if (optional_indent) |_|
                    if (self.map.count() > 0)
                        "\n"
                    else
                        ""
                else
                    " ",
            );

            const optional_indent_inc = if (optional_indent) |indent|
                indent + indent_increment
            else
                null;

            try writeMap(self.map, writer, optional_indent_inc);
            if (self.option_var) |v| {
                for (0..optional_indent orelse 0) |_|
                    try writer.writeByte(' ');
                try util.genericWrite(v, writer);
            }
            if (self.var_next) |var_next|
                try var_next.writeIndent(writer, optional_indent_inc);

            if (self.sub_pat) |sub_pat| {
                for (0..optional_indent_inc orelse 0) |_|
                    try writer.writeByte(' ');

                // print("Subpat: {}\n", .{sub_pat.map.count()});
                try sub_pat.writeIndent(writer, optional_indent_inc);
            }
            for (0..optional_indent orelse 1) |_|
                try writer.writeByte(' ');

            try writer.writeByte('}');
            try writer.writeByte(if (optional_indent) |_| '\n' else ' ');
        }

        fn writeMap(
            map: anytype,
            writer: anytype,
            optional_indent: ?usize,
        ) @TypeOf(writer).Error!void {
            var iter = map.iterator();
            while (iter.next()) |entry| {
                for (0..optional_indent orelse 0) |_|
                    try writer.writeByte(' ');

                const key = entry.key_ptr.*;
                _ = try util.genericWrite(key, writer);
                try writer.writeAll(" -> ");
                try entry.value_ptr.writeIndent(
                    writer,
                    if (optional_indent) |indent|
                        indent + indent_increment
                    else
                        null,
                );
            }
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
    const Pat = AutoStringPattern(usize);
    const Node = Pat.Node;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p1 = Pat{};
    var p2 = Pat{};

    var val = Node{ .key = "123" };
    var val2 = Node{ .key = "123" };
    // Reverse order because patterns are values, not references
    try p2.map.put(allocator, "Bb", Pat{ .val = &val });
    try p1.map.put(allocator, "Aa", p2);

    var p_insert = Pat{};
    _ = try p_insert.insert(allocator, &.{
        Node{ .key = "Aa" },
        Node{ .key = "Bb" },
    }, val2);
    try p1.write(stderr);
    try stderr.writeByte('\n');
    try p_insert.write(stderr);
    try stderr.writeByte('\n');
    try testing.expect(p1.eql(p_insert));
}

test "should behave like a set when given void" {
    const Pat = AutoPattern(usize, void);
    const Node = Pat.Node;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    const nodes1 = &.{ Node{ .key = 123 }, Node{ .key = 456 } };
    var pat = Pat{};
    _ = try pat.insert(al, nodes1, null);

    // TODO: add to a test for insert
    // var expected = try Pat{};
    // {
    //     var current = &expected;
    //     for (0..2) |i| {
    //         current = current.map.Node.ofLit(i);
    //     }
    // }

    print("\nSet Pattern:\n", .{});
    try pat.write(stderr);
    print("\n", .{});
    const prefix = pat.matchExactPrefix(nodes1);
    // Even though there is a match, the val is null because we didn't insert
    // a value
    try testing.expectEqual(
        @as(?*Node, null),
        prefix.end_ptr.val,
    );
    try testing.expectEqual(@as(usize, 2), prefix.len);

    // try testing.expectEqual(@as(?void, null), pat.matchExact(nodes1[0..1]));

    // Empty pattern
    // try testing.expectEqual(@as(?void, {}), pat.match(.{
    //     .val = {},
    //     .kind = .{ .map = Pat.KeyMap{} },
    // }));
}

test "insert single lit" {}

test "insert multiple lits" {
    // Multiple keys
    const Pat = AutoPattern(usize, void);
    const Node = Pat.Node;
    var pat = Pat{};
    defer pat.deleteChildren(testing.allocator);

    _ = try pat.insert(
        testing.allocator,
        &.{ Node{ .key = 1 }, Node{ .key = 2 }, Node{ .key = 3 } },
        null,
    );
    try testing.expect(pat.map.contains(1));
}

test "compile: nested" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const Pat = AutoPattern(usize, void);
    var pat = try Pat.ofVal(al, 123);
    const prefix = pat.matchExactPrefix(&.{});
    _ = prefix;
    // Test nested
    // const Pat2 = Pat{};
    // Pat2.pat_map.put( &pat, 456 };
    // _ = Pat2;
}

test "Memory: simple" {
    const Pat = AutoPattern(usize, void);
    var pat = try Pat.ofVal(testing.allocator, 123);
    defer pat.deleteChildren(testing.allocator);
}

test "Memory: nesting" {
    const Pat = AutoStringPattern(void);
    const Node = Pat.Node;
    var nested_pat = try Pat.create(testing.allocator);
    defer nested_pat.delete(testing.allocator);
    nested_pat.sub_pat = try Pat.create(testing.allocator);

    _ = try nested_pat.sub_pat.?.insertKeys(
        testing.allocator,
        &.{ "cherry", "blossom", "tree" },
        Node.ofLit("beautiful"),
    );
}

test "Memory: idempotency" {
    const Pat = AutoPattern(usize, void);
    var pat = Pat{};
    defer pat.deleteChildren(testing.allocator);
}

test "Memory: nested pattern" {
    const Pat = AutoStringPattern(void);
    const Node = Pat.Node;
    _ = Node;
    var pat = try Pat.create(testing.allocator);
    defer pat.delete(testing.allocator);
    var val_pat = try Pat.ofVal(testing.allocator, "Val");

    // No need to free this, because key pointers are deleted
    var nested_pat = try Pat.ofVal(testing.allocator, "Asdf");

    try pat.pat_map.put(testing.allocator, nested_pat, val_pat);

    _ = try val_pat.insertKeys(
        testing.allocator,
        &.{ "cherry", "blossom", "tree" },
        null,
    );
}

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
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const print = util.print;
const first = util.first;
const last = util.last;
const panic = std.debug.panic;

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
        pub const NodeMap = std.ArrayHashMapUnmanaged(
            Node, // The tree
            Self, // The next pattern in the trie for this key's tree
            util.IntoArrayContext(Node),
            true,
        );
        /// This is a pointer to the pattern at the end of some path of nodes,
        /// and an index to the start of the path.
        const GetOrPutResult = NodeMap.GetOrPutResult;
        // struct {
        //     pattern_ptr: *Self,
        //     index: usize, // the index in the top level node map
        //     found_existing: bool,
        // };
        /// Used to store the children, which are the next patterns pointed to
        /// by literal keys.
        pub const PatternList = std.ArrayListUnmanaged(Self);
        /// This is used as a kind of temporary storage for matching
        pub const VarMap = std.ArrayHashMapUnmanaged(
            Var,
            Node,
            VarCtx,
            true,
        );

        /// Maps terms to the next pattern, if there is one. These form
        /// the branches of the trie for a level of nesting. All vars hash to
        /// the same thing in this map. This map references the rest of the
        /// fields in this struct (except values) which are responsible for
        /// storing things by value. Nested apps and patterns are encoded by
        /// a layer of pointer indirection.
        map: NodeMap = NodeMap{},
        /// A null value represents an undefined pattern, for example in `Foo
        /// Bar -> 123`, the value at `Foo` would be null.
        value: ?*Node = null,

        /// Nodes form the keys and values of a pattern type (its recursive
        /// structure forces both to be the same type). In Sifu, it is also the
        /// structure given to a source code entry (a `Node(Token)`). It encodes
        /// sequences, nesting, and patterns.
        /// The `Key` is a custom type to allow storing of metainfo such as a
        /// position, and must implement `toString()` for pattern conversion.
        /// It could also be a simple type for optimization purposes. Sifu maps
        /// the syntax described below to this data structure, but that syntax
        /// is otherwise irrelevant. Any infix operator that isn't a builtin
        /// (match, arrow or list) is parsed into an app.
        /// These are ordered in their precedence, which is used during parsing.
        pub const Node = union(enum) {
            /// A unique constant, literal values. Uniqueness when in a pattern
            /// arises from NodeMap referencing the same value multiple times
            /// (based on Key.eql).
            key: Key,
            /// A Var matches and stores a locally-unique key. During rewriting,
            /// whenever the key is encountered again, it is rewritten to this
            /// pattern's value. A Var pattern matches anything, including nested
            /// patterns. It only makes sense to match anything after trying to
            /// match something specific, so Vars always successfully match (if
            /// there is a Var) after a Key or Subpat match fails.
            variable: Var,
            /// Spaces separated juxtaposition, or lists/parens for nested apps.
            /// Infix operators add their rhs as a nested apps after themselves.
            apps: []const Node,
            /// A postfix encoded match pattern, i.e. `x : Int -> x * 2` where
            /// some node (`x`) must match some subpattern (`Int`) in order for
            /// the rest of the match to continue. Like infixes, the apps to
            /// the left form their own subapps, stored here, but the `:` token
            /// is elided.
            match: []const Node,
            /// A postfix encoded arrow expression denoting a rewrite, i.e. `A B
            /// C -> 123`.
            arrow: []const Node,
            /// "long" versions of ops have same semantics, but are tracked to
            /// facilitate parsing/printing. They may be removed in the future,
            /// as parsing isn't a concern of this abstract data structure.
            // long_match: []const Node,
            // long_arrow: []const Node,
            /// A single element in comma separated list, with the comma elided.
            /// Lists are operators that are recognized as separators for
            /// patterns.
            list: []const Node,
            // A pointer here saves space depending on the size of `Key`
            /// An expression in braces.
            pattern: Self,

            /// Performs a deep copy, resulting in a Node the same size as the
            /// original.
            /// The copy should be freed with `deinit`.
            pub fn copy(self: Node, allocator: Allocator) Allocator.Error!Node {
                return switch (self) {
                    .key, .variable => self,
                    .pattern => |p| Node.ofPattern(try p.copy(allocator)),
                    inline .apps, .arrow, .match, .list => |apps, tag| blk: {
                        var apps_copy = try allocator.alloc(Node, apps.len);
                        for (apps, apps_copy) |app, *app_copy|
                            app_copy.* = try app.copy(allocator);

                        break :blk @unionInit(Node, @tagName(tag), apps_copy);
                    },
                };
            }

            pub fn clone(self: Node, allocator: Allocator) !*Node {
                var self_copy = try allocator.create(Node);
                self_copy.* = try self.copy(allocator);
                return self_copy;
            }

            pub fn destroy(self: *Node, allocator: Allocator) void {
                self.deinit(allocator);
                allocator.destroy(self);
            }

            pub fn deinit(self: Node, allocator: Allocator) void {
                switch (self) {
                    .key, .variable => {},
                    .pattern => |*p| @constCast(p).deinit(allocator),
                    inline .apps, .match, .arrow, .list => |apps, tag| {
                        _ = tag;
                        for (apps) |*app|
                            @constCast(app).deinit(allocator);
                        allocator.free(apps);
                        // Overwrite the freed pointer
                        // self = @unionInit(Node, @tagName(tag), &.{});
                    },
                }
            }

            pub const hash = util.hashFromHasherUpdate(Node);

            pub fn hasherUpdate(self: Node, hasher: anytype) void {
                hasher.update(&mem.toBytes(@intFromEnum(self)));
                switch (self) {
                    inline .apps, .match, .arrow, .list => |apps, tag| {
                        for (apps) |app|
                            app.hasherUpdate(hasher);
                        switch (tag) {
                            .arrow => hasher.update("->"),
                            .match => hasher.update(":"),
                            .list => hasher.update(","),
                            else => {},
                        }
                    },
                    // All var asts hash to the same value,
                    // which is just their enum
                    .variable => {},
                    .key => |k| hasher.update(
                        &mem.toBytes(KeyCtx.hash(undefined, k)),
                    ),
                    .pattern => |p| p.hasherUpdate(hasher),
                }
            }

            pub fn eql(node: Node, other: Node) bool {
                return if (@intFromEnum(node) != @intFromEnum(other))
                    false
                else switch (node) {
                    .key => |k| KeyCtx.eql(undefined, k, other.key, undefined),
                    .variable => other == .variable,
                    inline .apps, .arrow, .match, .list => |apps, tag| blk: {
                        const other_slice = @field(other, @tagName(tag));
                        break :blk apps.len == other_slice.len and
                            for (apps, other_slice) |app, other_app|
                        {
                            if (!app.eql(other_app))
                                break false;
                        } else true;
                    },
                    .pattern => |p| p.eql(other.pattern),
                };
            }
            pub fn ofLit(key: Key) Node {
                return .{ .key = key };
            }
            pub fn ofVar(variable: Var) Node {
                return .{ .variable = variable };
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

            pub fn createPattern(
                allocator: Allocator,
                pattern: Self,
            ) Allocator.Error!*Node {
                const node = try allocator.create(Node);
                node.* = Node{ .pattern = pattern };
                return node;
            }

            pub fn ofPattern(
                pattern: Self,
            ) Node {
                return Node{ .pattern = pattern };
            }

            /// Returns a copy of the node with pointer variants set to empty.
            /// This is used for two reasons: it helps ensure that a pattern
            /// never stores a Node's allocations, and allows granular matching
            /// while perserving order between different node kinds.
            fn asEmpty(node: Node) Node {
                return switch (node) {
                    .key, .variable => node,
                    .pattern => Node{ .pattern = Self{} },
                    inline .apps, .match, .arrow, .list => |_, tag|
                    // All slice types hash to themselves
                    @unionInit(Node, @tagName(tag), &.{}),
                };
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
                        .variable => |v| mem.order(u8, v, other.variable),
                        .key => |key| key.order(other.key),
                        .pattern => |pattern| pattern.order(other.pattern),
                    }
                else
                    ord;
            }

            pub fn writeSExp(
                self: Node,
                writer: anytype,
                optional_indent: ?usize,
            ) !void {
                for (0..optional_indent orelse 0) |_|
                    try writer.writeByte(' ');
                switch (self) {
                    .key => |key| _ = try util.genericWrite(key, writer),
                    .variable => |variable| _ = try util.genericWrite(
                        variable,
                        writer,
                    ),
                    .pattern => |pattern| try pattern.writeIndent(
                        writer,
                        optional_indent,
                    ),
                    else => {
                        try writer.writeByte('(');
                        try self.writeIndent(writer, optional_indent);
                        try writer.writeByte(')');
                    },
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
            ) @TypeOf(writer).Error!void {
                switch (self) {
                    // Ignore top level parens
                    inline .apps, .arrow, .match, .list => |apps, tag| {
                        if (apps.len == 0)
                            return;
                        try apps[0].writeSExp(writer, optional_indent);
                        if (apps.len == 1) {
                            return;
                        } else for (apps[1 .. apps.len - 1]) |app| {
                            try writer.writeByte(' ');
                            try app.writeSExp(writer, optional_indent);
                        }

                        switch (tag) {
                            .arrow => try writer.writeAll(" ->"),
                            .match => try writer.writeAll(" :"),
                            .list => try writer.writeAll(","),
                            else => {},
                        }
                        try writer.writeByte(' ');
                        try apps[apps.len - 1]
                            .writeSExp(writer, optional_indent);
                    },
                    else => try self.writeSExp(writer, optional_indent),
                }
            }
        };

        /// The results of matching a pattern exactly (vars are matched literally
        /// instead of by building up a tree of their possible values)
        pub const ExactPrefixResult = struct {
            len: usize,
            index: ?usize, // Null if no prefix
            end: Self,
        };
        /// The longest prefix matching a pattern, where vars match all possible
        /// expressions.
        pub const PrefixResult = struct {
            len: usize,
            end: *Self,
        };

        pub fn ofKey(
            allocator: Allocator,
            optional_key: ?Key,
        ) Allocator.Error!Self {
            return Self{
                .value = if (optional_key) |key|
                    try Node.createKey(allocator, key)
                else
                    null,
            };
        }

        /// Deep copy a pattern by value. Use deinit to free.
        pub fn copy(self: Self, allocator: Allocator) Allocator.Error!Self {
            var result = Self{};
            var map_iter = self.map.iterator();
            while (map_iter.next()) |entry|
                try result.map.putNoClobber(
                    allocator,
                    try entry.key_ptr.copy(allocator),
                    try entry.value_ptr.copy(allocator),
                );
            if (self.value) |value|
                result.value = try value.clone(allocator);

            return result;
        }

        /// Deep copy a pattern pointer, returning a pointer to new memory. Use
        /// destroy to free.
        pub fn clone(self: *Self, allocator: Allocator) !*Self {
            const clone_ptr = try allocator.create(Self);
            clone_ptr.* = try self.copy(allocator);
            return clone_ptr;
        }

        /// Frees all memory recursively, leaving the Pattern in an undefined
        /// state. The `self` pointer must have been allocated with `allocator`.
        /// The opposite of `clone`.
        pub fn destroy(self: *Self, allocator: Allocator) void {
            self.deinit(allocator);
            allocator.destroy(self);
        }

        /// The opposite of `copy`.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            defer self.map.deinit(allocator);
            var iter = self.map.iterator();
            while (iter.next()) |entry| {
                entry.key_ptr.deinit(allocator);
                entry.value_ptr.deinit(allocator);
            }
            if (self.value) |value|
                // Value nodes are also allocated recursively
                value.destroy(allocator);
        }

        pub fn hash(self: Self) u32 {
            var hasher = Wyhash.init(0);
            self.hasherUpdate(&hasher);
            return @truncate(hasher.final());
        }

        pub fn hasherUpdate(self: Self, hasher: anytype) void {
            var map_iter = self.map.iterator();
            while (map_iter.next()) |entry| {
                entry.key_ptr.*.hasherUpdate(hasher);
                entry.value_ptr.*.hasherUpdate(hasher);
            }
            if (self.value) |value|
                hasher.update(&mem.toBytes(value.hash()));
        }

        fn keyEql(k1: Key, k2: Key) bool {
            return KeyCtx.eql(undefined, k1, k2, undefined);
        }

        /// Patterns are equal if they have the same literals, sub-arrays and
        /// sub-patterns and if their debruijn variables are equal. The patterns
        /// are assumed to be in debruijn form already.
        pub fn eql(self: Self, other: Self) bool {
            var map_iter = self.map.iterator();
            var other_iter = other.map.iterator();
            while (map_iter.next()) |entry| {
                const other_entry = other_iter.next() orelse
                    return false;
                if (!(entry.key_ptr.*.eql(other_entry.key_ptr.*) and
                    entry.value_ptr == other_entry.value_ptr))
                    return false;
            }
            return if (self.value) |self_value| if (other.value) |other_value|
                self_value.*.eql(other_value.*)
            else
                false else other.value == null;
        }

        pub fn create(allocator: Allocator) !*Self {
            const result = try allocator.create(Self);
            result.* = Self{};
            return result;
        }

        pub const VarNext = struct {
            variable: Var,
            index: usize,
            next: Self,
        };

        pub fn getVar(pattern: *const Self) ?VarNext {
            const index = pattern.map.getIndex(Node{ .variable = "" }) orelse
                return null;

            return VarNext{
                .variable = pattern.map.keys()[index].variable,
                .index = index,
                .next = pattern.map.values()[index],
            };
        }

        /// Follows `pattern` for each app matching structure as well as value.
        /// Does not require allocation because variable branches are not
        /// explored, but rather followed. This is an exact match, so variables
        /// only match variables and a subpattern will be returned. This pointer
        /// is valid unless reassigned in `pat`.
        /// If apps is empty the same `pat` pointer will be returned. If
        /// the entire `apps` is a prefix, a pointer to the last pat will be
        /// returned instead of null.
        /// `pattern` isn't modified.
        pub fn get(
            pattern: Self,
            node: Node,
        ) ?Self {
            print("get: ", .{});
            const empty_node = node.asEmpty();
            if (pattern.map.get(empty_node)) |value|
                value.write(err_stream) catch unreachable
            else
                print("null", .{});
            print(" at index: {?}\n", .{pattern.map.getIndex(empty_node)});
            var index = pattern.map.getIndex(empty_node) orelse
                return null;
            var next = pattern.map.values()[index];
            return switch (node) {
                .key, .variable => next,
                .apps, .arrow, .match, .list => |sub_apps| blk: {
                    const prefix = next.getPrefix(sub_apps);
                    break :blk if (prefix.len == sub_apps.len)
                        prefix.end
                    else
                        null;
                },
                else => @panic("unimplemented"),
            };
        }

        /// Return a pointer to the last pattern in `pat` after the longest path
        /// matching `apps`.
        pub fn getPrefix(
            pattern: Self,
            apps: []const Node,
        ) ExactPrefixResult {
            var current = pattern;
            var index: ?usize = null;
            // Follow the longest branch that exists
            const prefix_len = for (apps, 0..) |app, i| {
                current = current.get(app) orelse
                    break i;
            } else apps.len;

            return .{ .len = prefix_len, .index = index, .end = current };
        }

        /// As a pattern is matched, a hashmap for vars is populated with
        /// each var's bound variable. These can the be used by the caller for
        /// rewriting.
        /// All nodes are copied, not moved, into the pattern.
        ///
        pub fn getOrPut(
            pattern: *Self,
            allocator: Allocator,
            node: Node,
        ) Allocator.Error!GetOrPutResult {
            // No need to copy here because empty slices have 0 length
            var result = try pattern.map.getOrPut(allocator, node.asEmpty());
            if (result.found_existing) {
                print("Found existing\n", .{});
            } else {
                result.value_ptr.* = Self{};
            }
            switch (node) {
                .key, .variable => {},
                // All slice types are encoded the same way after their top
                // level hash
                .apps, .arrow, .match, .list => |apps| {
                    for (apps) |app|
                        result = try result.value_ptr.getOrPut(allocator, app);
                },
                else => @panic("unimplemented"),
            }
            return result;
        }

        /// Add a node to the pattern by following `key`.
        /// Allocations:
        /// - The path followed by apps is allocated and copied recursively
        /// - The node, if given, is allocated and copied recursively
        /// Returns a pointer to the pattern directly containing `optional_val`.
        pub fn put(
            self: *Self,
            allocator: Allocator,
            key: Node,
            maybe_value: ?Node,
        ) Allocator.Error!void {
            const get_or_put = try self.getOrPut(allocator, key);
            if (maybe_value) |value| {
                if (get_or_put.value_ptr.*.value) |prev_value| {
                    print("Deleting old value: {*}\n", .{prev_value});
                    prev_value.destroy(allocator);
                }
                // print("Put Hash: {}\n", .{node.hash()});
                get_or_put.value_ptr.*.value = try value.clone(allocator);
            }
        }

        /// Add a node to the pattern by following `keys`, wrapping them into an
        /// App of Nodes.
        /// Allocations:
        /// - The path followed by apps is allocated and copied recursively
        /// - The node, if given, is allocated and copied recursively
        /// Freeing should be done with `destroy` or `deinit`, depending
        /// on how `self` was allocated
        pub fn putKeys(
            self: *Self,
            allocator: Allocator,
            keys: []const Key,
            optional_value: ?Node,
        ) Allocator.Error!*Self {
            var apps = allocator.alloc(Key, keys.len);
            defer apps.free(allocator);
            for (apps, keys) |*app, key|
                app.* = Node.ofLit(key);

            return self.put(
                allocator,
                Node.ofApps(apps),
                optional_value,
            );
        }

        /// The resulting pattern and its value from successful matching
        /// (otherwise null is returned), therefore `pattern` is always a
        /// child of the root.
        /// `index` - where in the last node map matched
        const MatchResult = struct {
            pattern: Self,
            next: ?Self = null,
            index: usize,
        };

        /// The first half of evaluation. The variables in the node match
        /// anything in the pattern, and vars in the pattern match anything in
        /// the expression. Includes partial prefixes (ones that don't match
        /// all apps).
        /// - Any node matches a var pattern including a var (the var node is
        ///   then stored in the var map like any other node)
        /// - A var node doesn't match a non-var pattern (var matching is one
        ///   way)
        /// - A literal node that matches a literal-var pattern matches the
        /// literal part, not the var
        /// Returns a new pattern that only contains branches that matched `apps`.
        /// Calculates the minimum index a subsequent match should use, which
        /// is at least one greater than the current (except for structural
        /// recursion).
        // TODO: move var_map from params to result
        pub fn match(
            pattern: Self,
            allocator: Allocator,
            var_map: *VarMap,
            node: Node,
        ) Allocator.Error!?MatchResult {
            const empty_node = node.asEmpty();

            print("Matched: `", .{});
            node.asEmpty().writeSExp(err_stream, null) catch unreachable;
            print("` ", .{});
            var result: MatchResult = undefined;
            if (pattern.map.getIndex(empty_node)) |next_index| {
                result.index = next_index;
                result.pattern = pattern.map.values()[next_index];
                print("exactly: ", .{});
                result.pattern.write(err_stream) catch unreachable;
                print(" at index: {?}\n", .{result.index});
            } else if (pattern.getVar()) |var_next| {
                // index += 1; // TODO use as limit
                result.index = var_next.index;
                print("as var `{s}` ", .{var_next.variable});
                var_next.next.write(err_stream) catch unreachable;
                print(" at index: {?}\n", .{result.index});
                const var_result =
                    try var_map.getOrPut(allocator, var_next.variable);
                // If a previous var was bound, check that the
                // current key matches it
                if (var_result.found_existing) {
                    if (!var_result.value_ptr.*.eql(node)) {
                        print("found equal existing var mapping\n", .{});
                    } else {
                        print("found existing non-equal var mapping", .{});
                    }
                } else {
                    print("New Var: {s}\n", .{var_result.key_ptr.*});
                    var_result.value_ptr.* = node;
                }
                result.pattern = var_next.next;
            } else {
                print(" null\n", .{});
                return null;
            }
            switch (node) {
                .key, .variable => {},
                .apps, .match, .arrow, .list => |sub_apps| {
                    // TODO: Follow the longest branch that exists
                    for (sub_apps) |sub_app|
                        result = try result.pattern.match(
                            allocator,
                            var_map,
                            sub_app,
                        ) orelse break;
                },
                else => @panic("unimplemented"),
            }
            return result;
        }

        /// The second half of an evaluation step. Rewrites all variable
        /// captures into the matched expression. Copies any variables in node
        /// if they are keys in var_map with their values. If there are no
        /// matches in var_map, this functions is equivalent to copy. Result
        /// should be freed with deinit.
        pub fn rewrite(
            pattern: Self,
            allocator: Allocator,
            var_map: VarMap,
            node: Node,
        ) Allocator.Error!Node {
            const rewritten = switch (node) {
                .key => node,
                .variable => |variable| blk: {
                    print("Var get: ", .{});
                    if (var_map.get(variable)) |var_node|
                        var_node.write(err_stream) catch unreachable
                    else
                        print("null", .{});
                    print("\n", .{});
                    break :blk try (var_map.get(variable) orelse
                        node).copy(allocator);
                },
                inline .apps, .arrow, .match, .list => |apps, tag| blk: {
                    var apps_copy = try allocator.alloc(Node, apps.len);
                    for (apps, apps_copy) |app, *app_copy|
                        app_copy.* = try pattern.rewrite(allocator, var_map, app);

                    break :blk @unionInit(Node, @tagName(tag), apps_copy);
                },
                // .pattern => |sub_pat| {
                //     _ = sub_pat;
                // },
                else => @panic("unimplemented"),
            };
            return rewritten;
        }

        /// Given a pattern and a query to match against it, this function
        /// continously matches until no matches are found, or a match repeats.
        /// Match result cases:
        /// - a pattern of lower ordinal: continue
        /// - the same pattern: continue unless patterns are equivalent
        ///   expressions (fixed point)
        /// - a pattern of higher ordinal: break
        pub fn evaluate(
            pattern: Self,
            // var_map: *VarMap,
            allocator: Allocator,
            node: Node,
        ) Allocator.Error!Node {
            var var_map = VarMap{};
            defer var_map.deinit(allocator);
            var previous = try node.copy(allocator);
            return while (try pattern.match(allocator, &var_map, previous)) |matched| {
                const eval = if (matched.pattern.value) |value| blk: {
                    print("Rewrite matched {s}: ", .{@tagName(value.*)});
                    value.write(err_stream) catch unreachable;
                    err_stream.writeByte('\n') catch unreachable;
                    break :blk try pattern.rewrite(allocator, var_map, value.*);
                } else {
                    print("matched, but no value\n", .{});
                    break previous;
                };
                print("vars in map: {}\n", .{var_map.entries.len});
                if (previous.eql(eval)) {
                    break eval;
                }
                previous.deinit(allocator);
                previous = eval;
            } else previous;
        }

        /// Pretty print a pattern on multiple lines
        pub fn pretty(self: Self, writer: anytype) !void {
            try self.writeIndent(writer, 0);
        }

        /// Print a pattern without newlines
        pub fn write(self: Self, writer: anytype) !void {
            try self.writeIndent(writer, null);
        }

        pub const indent_increment = 2;
        fn writeIndent(
            self: Self,
            writer: anytype,
            optional_indent: ?usize,
        ) @TypeOf(writer).Error!void {
            if (self.value) |value| {
                try writer.writeByte('|');
                try value.writeIndent(writer, null);
                try writer.writeAll("| ");
            }
            const optional_indent_inc = if (optional_indent) |indent|
                indent + indent_increment
            else
                null;
            try writer.writeByte('{');
            try writer.writeAll(if (optional_indent) |_| "\n" else "");
            try writeEntries(self.map, writer, optional_indent_inc);
            for (0..optional_indent orelse 0) |_|
                try writer.writeByte(' ');
            try writer.writeByte('}');
            try writer.writeAll(if (optional_indent) |_| "\n" else "");
        }

        fn writeEntries(
            map: anytype,
            writer: anytype,
            optional_indent: ?usize,
        ) @TypeOf(writer).Error!void {
            var iter = map.iterator();
            while (iter.next()) |entry| {
                for (0..optional_indent orelse 1) |_|
                    try writer.writeByte(' ');

                const node = entry.key_ptr.*;
                try node.writeSExp(writer, null);
                try writer.writeAll(" -> ");
                try entry.value_ptr.*.writeIndent(writer, optional_indent);
                try writer.writeAll(if (optional_indent) |_| "" else ", ");
            }
        }
    };
}

const testing = std.testing;

// for debugging with zig test --test-filter, comment this import
// const stderr = if (true)
const err_stream = if (@import("build_options").verbose_tests)
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

    var value = Node{ .key = "123" };
    var value2 = Node{ .key = "123" };
    // Reverse order because patterns are values, not references
    try p2.map.put(allocator, "Bb", Pat{ .value = &value });
    try p1.map.put(allocator, "Aa", p2);

    var p_put = Pat{};
    _ = try p_put.putApps(allocator, &.{
        Node{ .key = "Aa" },
        Node{ .key = "Bb" },
    }, value2);
    try p1.write(err_stream);
    try err_stream.writeByte('\n');
    try p_put.write(err_stream);
    try err_stream.writeByte('\n');
    try testing.expect(p1.eql(p_put));
}

test "should behave like a set when given void" {
    const Pat = AutoPattern(usize, void);
    const Node = Pat.Node;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    const nodes1 = &.{ Node{ .key = 123 }, Node{ .key = 456 } };
    var pattern = Pat{};
    _ = try pattern.putApps(al, nodes1, null);

    // TODO: add to a test for put
    // var expected = try Pat{};
    // {
    //     var current = &expected;
    //     for (0..2) |i| {
    //         current = current.map.Node.ofLit(i);
    //     }
    // }

    print("\nSet Pattern:\n", .{});
    try pattern.write(err_stream);
    print("\n", .{});
    const prefix = pattern.getPrefix(nodes1);
    // Even though there is a match, the value is null because we didn't put
    // a value
    try testing.expectEqual(
        @as(?*Node, null),
        prefix.end.value,
    );
    try testing.expectEqual(@as(usize, 2), prefix.len);

    // try testing.expectEqual(@as(?void, null), pattern.matchUnique(nodes1[0..1]));

    // Empty pattern
    // try testing.expectEqual(@as(?void, {}), pattern.match(.{
    //     .value = {},
    //     .kind = .{ .map = Pat.KeyMap{} },
    // }));
}

test "put single lit" {}

test "put multiple lits" {
    // Multiple keys
    const Pat = AutoPattern(usize, void);
    const Node = Pat.Node;
    var pattern = Pat{};
    defer pattern.deinit(testing.allocator);

    _ = try pattern.putApps(
        testing.allocator,
        &.{ Node{ .key = 1 }, Node{ .key = 2 }, Node{ .key = 3 } },
        null,
    );
    try testing.expect(pattern.map.contains(1));
}

test "compile: nested" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const Pat = AutoPattern(usize, void);
    var pattern = try Pat.ofValue(al, 123);
    const prefix = pattern.getPrefix(&.{});
    _ = prefix;
    // Test nested
    // const Pat2 = Pat{};
    // Pat2.pat_map.put( &pat, 456 };
    // _ = Pat2;
}

test "Memory: simple" {
    const Pat = AutoPattern(usize, void);
    var pattern = try Pat.ofValue(testing.allocator, 123);
    defer pattern.deinit(testing.allocator);
}

test "Memory: nesting" {
    const Pat = AutoStringPattern(void);
    const Node = Pat.Node;
    var nested_pattern = try Pat.create(testing.allocator);
    defer nested_pattern.destroy(testing.allocator);
    nested_pattern.getOrPut(testing.allocator, Pat{}, "subpat's value");

    _ = try nested_pattern.putKeys(
        testing.allocator,
        &.{ "cherry", "blossom", "tree" },
        Node.ofLit("beautiful"),
    );
}

test "Memory: idempotency" {
    const Pat = AutoPattern(usize, void);
    var pattern = Pat{};
    defer pattern.deinit(testing.allocator);
}

test "Memory: nested pattern" {
    const Pat = AutoStringPattern(void);
    const Node = Pat.Node;
    var pattern = try Pat.create(testing.allocator);
    defer pattern.destroy(testing.allocator);
    var value_pattern = try Pat.ofValue(testing.allocator, "Value");

    // No need to free this, because key pointers are destroyed
    var nested_pattern = try Pat.ofValue(testing.allocator, "Asdf");

    try pattern.map.put(testing.allocator, Node{ .pattern = &nested_pattern }, value_pattern);

    _ = try value_pattern.putKeys(
        testing.allocator,
        &.{ "cherry", "blossom", "tree" },
        null,
    );
}

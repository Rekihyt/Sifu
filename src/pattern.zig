const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;
const math = std.math;
const util = @import("util.zig");
const assert = std.debug.assert;
const panic = util.panic;
const Order = math.Order;
const Wyhash = std.hash.Wyhash;
const array_hash_map = std.array_hash_map;
const AutoContext = std.array_hash_map.AutoContext;
const StringContext = std.array_hash_map.StringContext;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const print = util.print;
const first = util.first;
const last = util.last;
const streams = util.streams;
const verbose_errors = @import("build_options").verbose_errors;

pub fn AutoPattern(
    comptime Literal: type,
) type {
    if (Literal == []const u8)
        @compileError(
            \\Cannot make a pattern automatically from []const u8,
            \\please use AutoStringPattern instead.
        );
    return PatternWithContext(Literal, AutoContext(Literal));
}

pub fn StringPattern() type {
    return PatternWithContext(
        []const u8,
        StringContext,
        StringMemManager,
    );
}

/// A pattern that uses a pointer to its own type as its node and copies keys
/// and vars by value. Used for parsing. Provided types must implement hash
/// and eql.
pub fn Pattern(
    comptime Literal: type,
) type {
    return PatternWithContext(
        Literal,
        util.IntoArrayContext(Literal),
        null,
    );
}

const StringMemManager = struct {
    fn copy(allocator: Allocator, str: []const u8) ![]const u8 {
        return allocator.dupe(u8, str);
    }
    fn deinit(allocator: Allocator, str: []const u8) void {
        // print("Freeing {s}\n", .{str});
        return allocator.free(str);
    }
};

pub fn CopyByValue(comptime T: type) type {
    // No-ops for unmanaged copying by value
    return struct {
        fn copy(allocator: Allocator, val: T) !T {
            _ = allocator;
            return val;
        }
        fn deinit(allocator: Allocator, val: T) void {
            _ = allocator;
            _ = val;
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
/// `Literal` - the type of literal keys and variables
///
/// Contexts must be either nulls or structs with a type and two functions:
///    - `hasherUpdate` a hash function for `T`, of type `fn (T, anytype)
///        void` that updates a hasher (instead of a direct hash function for
///        efficiency)
///    - `eql` a function to compare two `T`s, of type `fn (T, T) bool`
///
/// MemManager: an optional set of functions for allocating and freeing copies
/// of Keys and Vars. Must have a copy and deinit function for each.
pub fn PatternWithContext(
    comptime Literal: type,
    comptime Ctx: type,
    comptime MemManager: ?type,
) type {
    return struct {
        pub const Self = @This();
        pub const NodeMap = std.ArrayHashMapUnmanaged(
            Node, // The key, a single key
            Self, // The next pattern in the trie for this key's tree
            util.IntoArrayContext(Node),
            true,
        );
        /// This is a pointer to the pattern at the end of some path of nodes,
        /// and an index to the start of the path.
        const GetOrPutResult = NodeMap.GetOrPutResult;
        /// Used to store the children, which are the next patterns pointed to
        /// by literal keys.
        pub const PatternList = std.ArrayListUnmanaged(Self);
        /// This is used as a kind of temporary storage for variable during
        /// matching and rewriting
        pub const LiteralMap = std.ArrayHashMap(Literal, Node, Ctx, true);
        pub const LiteralMapUnmanaged = std
            .ArrayHashMapUnmanaged(Literal, Node, Ctx, true);
        pub const Manager = MemManager orelse CopyByValue(Literal);

        /// Maps terms to the next pattern, if there is one. These form
        /// the branches of the trie for a level of nesting. All vars hash to
        /// the same thing in this map. This map references the rest of the
        /// fields in this struct (except values) which are responsible for
        /// storing things by value. Nested apps and patterns are encoded by
        /// a layer of pointer indirection.
        map: NodeMap = .{},
        /// A null value represents an undefined pattern, for example in `Foo
        /// Bar -> 123`, the value at `Foo` would be null.
        value: ?*Node = null,

        /// An apps Node with a height.
        pub const Tree = struct {
            root: []const Node = &.{},
            height: usize = 0,

            // Clears all memory and resets this Tree's root to an empty apps.
            pub fn deinit(self: Tree, allocator: Allocator) void {
                Node.ofApps(self).deinit(allocator);
            }
        };

        /// Nodes form the keys and values of a pattern type (its recursive
        /// structure forces both to be the same type). In Sifu, it is also the
        /// structure given to a source code entry (a `Node(Token)`). It encodes
        /// sequences, nesting, and patterns.
        /// The `Literal` is a custom type to allow storing of metainfo such as a
        /// position, and must implement `toString()` for pattern conversion.
        /// It could also be a simple type for optimization purposes. Sifu maps
        /// the syntax described below to this data structure, but that syntax
        /// is otherwise irrelevant. Any infix operator that isn't a builtin
        /// (match, arrow or list) is parsed into an app.
        /// These are ordered in their precedence, which is used during parsing.
        pub const Node = union(enum) {
            /// A unique constant, literal values. Uniqueness when in a pattern
            /// arises from NodeMap referencing the same value multiple times
            /// (based on Literal.eql).
            key: Literal,
            /// A Var matches and stores a locally-unique key. During rewriting,
            /// whenever the key is encountered again, it is rewritten to this
            /// pattern's value. A Var pattern matches anything, including nested
            /// patterns. It only makes sense to match anything after trying to
            /// match something specific, so Vars always successfully match (if
            /// there is a Var) after a Key or Subpat match fails.
            variable: Literal,
            /// Spaces separated juxtaposition, or lists/parens for nested apps.
            /// Infix operators add their rhs as a nested apps after themselves.
            apps: Tree,
            /// Variables that match apps as a term. These are only strictly
            /// needed for matching patterns with ops, where the nested apps
            /// is implicit.
            var_apps: Literal,
            /// The list following a non-builtin operator.
            infix: Tree,
            /// A postfix encoded match pattern, i.e. `x : Int -> x * 2` where
            /// some node (`x`) must match some subpattern (`Int`) in order for
            /// the rest of the match to continue. Like infixes, the apps to
            /// the left form their own subapps, stored here, but the `:` token
            /// is elided.
            match: Tree,
            /// A postfix encoded arrow expression denoting a rewrite, i.e. `A B
            /// C -> 123`. This includes "long" versions of ops, which have same
            /// semantics, but only play a in part parsing/printing. Parsing
            /// shouldn't concern this abstract data structure, and there is
            /// enough information preserved such that during printing, the
            /// correct precedence operator can be recreated.
            arrow: Tree,
            /// TODO: remove. These are here temporarily until the parser is
            /// refactored to determine precedence by tracking tokens instead of
            /// nodes. The pretty printer must also then reconstruct the correct
            /// tokens based on the precedence needed to preserve a given Ast's
            /// structure.
            long_match: Tree,
            long_arrow: Tree,
            long_list: Tree,
            /// A single element in comma separated list, with the comma elided.
            /// Lists are operators that are recognized as separators for
            /// patterns.
            list: Tree,
            // A pointer here saves space depending on the size of `Literal`
            /// An expression in braces.
            pattern: Self,

            /// Performs a deep copy, resulting in a Node the same size as the
            /// original. Does not deep copy keys or vars.
            /// The copy should be freed with `deinit`.
            pub fn copy(
                self: Node,
                allocator: Allocator,
            ) Allocator.Error!Node {
                return switch (self) {
                    .key => |key| Node.ofKey(try Manager.copy(allocator, key)),
                    .variable => |variable| Node.ofVar(try Manager.copy(allocator, variable)),
                    .var_apps => |var_apps| Node.ofVarApps(try Manager.copy(allocator, var_apps)),
                    .pattern => |p| Node.ofPattern(try p.copy(allocator)),
                    inline else => |tree, tag| blk: {
                        const apps_copy = try allocator.alloc(Node, tree.root.len);
                        for (tree.root, apps_copy) |app, *app_copy|
                            app_copy.* = try app.copy(allocator);

                        break :blk @unionInit(Node, @tagName(tag), Tree{
                            .root = apps_copy,
                            .height = tree.height,
                        });
                    },
                };
            }

            // Same as copy but allocates the root
            pub fn clone(self: Node, allocator: Allocator) !*Node {
                const self_copy = try allocator.create(Node);
                self_copy.* = try self.copy(allocator);
                return self_copy;
            }

            pub fn destroy(self: *Node, allocator: Allocator) void {
                self.deinit(allocator);
                allocator.destroy(self);
            }

            pub fn deinit(self: Node, allocator: Allocator) void {
                switch (self) {
                    .key => |key| Manager.deinit(allocator, key),
                    .variable => |variable| Manager.deinit(allocator, variable),
                    .var_apps => |var_apps| Manager.deinit(allocator, var_apps),
                    .pattern => |*p| @constCast(p).deinit(allocator),
                    inline else => |tree| {
                        for (tree.root) |*app|
                            @constCast(app).deinit(allocator);
                        allocator.free(tree.root);
                    },
                }
            }

            pub const hash = util.hashFromHasherUpdate(Node);

            pub fn hasherUpdate(self: Node, hasher: anytype) void {
                hasher.update(&mem.toBytes(@intFromEnum(self)));
                switch (self) {
                    // Variables are always the same hash in Patterns (in
                    // varmaps they need unique hashes)
                    // TODO: differentiate between repeated and unique vars
                    .variable, .var_apps => {},
                    .key => |key| hasher.update(
                        &mem.toBytes(Ctx.hash(undefined, key)),
                    ),
                    .pattern => |pattern| pattern.hasherUpdate(hasher),
                    inline else => |tree, tag| {
                        // Height isn't hashed because it wouldn't add any new
                        // information
                        for (tree.root) |app|
                            app.hasherUpdate(hasher);
                        switch (tag) {
                            .arrow, .long_arrow => hasher.update("->"),
                            .match, .long_match => hasher.update(":"),
                            .list => hasher.update(","),
                            else => {},
                        }
                    },
                }
            }

            pub fn eql(node: Node, other: Node) bool {
                return if (@intFromEnum(node) != @intFromEnum(other))
                    false
                else switch (node) {
                    .key => |k| Ctx.eql(undefined, k, other.key, undefined),
                    // TODO: make exact comparisons work with single place
                    // patterns in hashmaps
                    // .variable => |v| Ctx.eql(undefined, v, other.variable, undefined),
                    .variable => other == .variable,
                    .var_apps => other == .var_apps,
                    .pattern => |p| p.eql(other.pattern),
                    inline else => |tree, tag| blk: {
                        const other_tree = @field(other, @tagName(tag));
                        break :blk tree.root.len == other_tree.root.len and
                            for (tree.root, other_tree.root) |app, other_app|
                        {
                            if (!app.eql(other_app))
                                break false;
                        } else true;
                    },
                };
            }
            pub fn ofKey(key: Literal) Node {
                return .{ .key = key };
            }
            pub fn ofVar(variable: Literal) Node {
                return .{ .variable = variable };
            }
            pub fn ofVarApps(var_apps: Literal) Node {
                return .{ .var_apps = var_apps };
            }

            pub fn ofApps(apps: Tree) Node {
                return .{ .apps = apps };
            }

            pub fn createKey(
                allocator: Allocator,
                key: Literal,
            ) Allocator.Error!*Node {
                const node = try allocator.create(Node);
                node.* = Node{ .key = key };
                return node;
            }

            /// Lifetime of `apps` must be longer than this Node.
            pub fn createApps(
                allocator: Allocator,
                apps: Tree,
            ) Allocator.Error!*Node {
                const node = try allocator.create(Node);
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
                    .key, .variable, .var_apps => node,
                    .pattern => Node{ .pattern = Self{} },
                    inline else => |_, tag|
                    // All slice types hash to themselves
                    @unionInit(Node, @tagName(tag), .{}),
                };
            }

            pub fn isOp(self: Node) bool {
                return switch (self) {
                    .key, .variable, .apps, .var_apps, .pattern => false,
                    else => true,
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
                    .variable, .var_apps => |variable| {
                        _ = try util.genericWrite(variable, writer);
                    },
                    .pattern => |pattern| try pattern.writeIndent(
                        writer,
                        optional_indent,
                    ),
                    .apps => {
                        try writer.writeByte('(');
                        try self.writeIndent(writer, optional_indent);
                        try writer.writeByte(')');
                    },
                    inline else => |slice, tag| {
                        switch (tag) {
                            .arrow => try writer.writeAll("-> "),
                            .match => try writer.writeAll(": "),
                            .long_arrow => try writer.writeAll("--> "),
                            .long_match => try writer.writeAll(":: "),
                            .list => try writer.writeAll(", "),
                            else => {},
                        }
                        // Don't write an s-exp as its redundant for ops
                        try Node.ofApps(slice).writeIndent(writer, optional_indent);
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
                    inline .apps, .list, .arrow, .match, .infix => |tree| {
                        const apps = tree.root;
                        if (apps.len == 0)
                            return;
                        // print("tag: {s}\n", .{@tagName(apps[0])});
                        try apps[0].writeSExp(writer, optional_indent);
                        if (apps.len == 1) {
                            return;
                        } else for (apps[1 .. apps.len - 1]) |app| {
                            // print("tag: {s}\n", .{@tagName(app)});
                            try writer.writeByte(' ');
                            try app.writeSExp(writer, optional_indent);
                        }
                        try writer.writeByte(' ');
                        // print("tag: {s}\n", .{@tagName(apps[apps.len - 1])});
                        try apps[apps.len - 1]
                            .writeSExp(writer, optional_indent);
                    },
                    else => try self.writeSExp(writer, optional_indent),
                }
            }
        };

        /// The results of matching a pattern exactly (vars are matched literally
        /// instead of by building up a tree of their possible values)
        pub const ExactPrefix = struct {
            len: usize,
            index: ?usize, // Null if no prefix
            leaf: Self,
        };
        /// The longest prefix matching a pattern, where vars match all possible
        /// expressions.
        pub const Prefix = struct {
            len: usize,
            leaf: *Self,
        };

        pub fn ofKey(
            allocator: Allocator,
            optional_key: ?Literal,
        ) Allocator.Error!Self {
            return Self{
                .value = if (optional_key) |key|
                    try Node.createKey(allocator, key)
                else
                    null,
            };
        }

        /// Deep copy a pattern by value, as well as Keys and Variables.
        /// Use deinit to free.
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

        fn keyEql(k1: Literal, k2: Literal) bool {
            return Ctx.eql(undefined, k1, k2, undefined);
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
            variable: Literal,
            index: usize,
            next: *Self,
        };

        /// Follows `pattern` for each app matching structure as well as value.
        /// Does not require allocation because variable branches are not
        /// explored, but rather followed. This is an exact match, so variables
        /// only match variables and a subpattern will be returned. This pointer
        /// is valid unless reassigned in `pat`.
        /// If apps is empty the same `pat` pointer will be returned. If
        /// the entire `apps` is a prefix, a pointer to the last pat will be
        /// returned instead of null.
        /// `pattern` isn't modified.
        pub fn getTerm(
            pattern: Self,
            node: Node,
        ) ?Self {
            return switch (node) {
                .key, .variable => pattern.map.get(node),
                .apps => |sub_apps| blk: {
                    const sub_pat = pattern.map.get(Node.ofApps(&.{})) orelse
                        break :blk null;
                    if (sub_pat.get(sub_apps)) |maybe_sub_value|
                        if (maybe_sub_value.value) |value|
                            break :blk value.pattern;
                },
                .arrow, .match, .list => panic("unimplemented", .{}),
                else => panic("unimplemented", .{}),
            };
        }

        /// Return a pointer to the last pattern in `pat` after the longest path
        /// following `apps`
        pub fn getPrefix(
            pattern: Self,
            apps: []const Node,
        ) ExactPrefix {
            var current = pattern;
            const index: usize = undefined; // TODO
            // Follow the longest branch that exists
            const prefix_len = for (apps, 0..) |app, i| {
                current = current.getTerm(app) orelse
                    break i;
            } else apps.len;

            return .{ .len = prefix_len, .index = index, .leaf = current };
        }

        pub fn get(
            pattern: Self,
            apps: []const Node,
        ) ?Self {
            const prefix = pattern.getPrefix(apps);
            return if (prefix.len == apps.len)
                prefix.leaf
            else
                null;
        }

        /// As a pattern is matched, a hashmap for vars is populated with
        /// each var's bound variable. These can the be used by the caller for
        /// rewriting.
        /// All nodes are copied, not moved, into the pattern.
        pub fn getOrPutTerm(
            pattern: *Self,
            allocator: Allocator,
            node: Node,
        ) Allocator.Error!*Self {
            var result = pattern;
            switch (node) {
                inline .key, .variable, .var_apps => {
                    const get_or_put = try pattern.map
                        .getOrPutValue(allocator, node, Self{});
                    if (get_or_put.found_existing) {
                        print("Found existing\n", .{});
                    } else {
                        // New keys must be copied because we don't own Node
                        get_or_put.key_ptr.* = try node.copy(allocator);
                    }
                    result = get_or_put.value_ptr;
                },
                .pattern => |sub_pat| {
                    const get_or_put = try result.map.getOrPutValue(
                        allocator,
                        Node.ofPattern(Self{}),
                        Self{},
                    );
                    _ = sub_pat;
                    _ = get_or_put;
                    @panic("unimplemented\n");
                },
                // App pattern's values will always be patterns too, which will
                // map nested apps to the next top level app.
                // The resulting encoding appears counter-intuitive when printed
                // because each level of nesting must be a branch to enable
                // pattern matching.
                inline else => |tree, tag| {
                    // Get or put a level of nesting as an empty node branch to
                    // a new pattern.
                    // No need to copy here because empty slices have 0 length
                    const get_or_put = try result.map.getOrPutValue(
                        allocator,
                        @unionInit(Node, @tagName(tag), .{}),
                        Self{},
                    );
                    // All op types are encoded the same way after their top level
                    // hash. These don't need special treatment because their
                    // structure is simple, and their operator unique.
                    result = try get_or_put.value_ptr.getOrPut(allocator, tree.root);
                    const next = result.value orelse blk: {
                        const pat = try Node.createPattern(allocator, Self{});
                        result.value = pat;
                        break :blk pat;
                    };
                    result = &next.pattern;
                },
            }
            return result;
        }

        pub fn getOrPut(
            pattern: *Self,
            allocator: Allocator,
            apps: []const Node,
        ) Allocator.Error!*Self {
            var result = pattern;
            for (apps) |app|
                result = try result.getOrPutTerm(allocator, app);
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
            apps: []const Node,
            maybe_value: ?Node,
        ) Allocator.Error!void {
            const result = try self.getOrPut(allocator, apps);
            if (maybe_value) |value| {
                if (result.value) |prev_value| {
                    print("Deleting old value: {*}\n", .{prev_value});
                    prev_value.writeIndent(streams.err, null) catch unreachable;
                    print("\n", .{});
                    prev_value.destroy(allocator);
                }
                // print("Put Hash: {}\n", .{node.hash()});
                result.value = try value.clone(allocator);
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
            keys: []const Literal,
            optional_value: ?Node,
        ) Allocator.Error!*Self {
            var apps = allocator.alloc(Literal, keys.len);
            defer apps.free(allocator);
            for (apps, keys) |*app, key|
                app.* = Node.ofKey(try Manager.copy(allocator, key));

            return self.put(
                allocator,
                Node.ofApps(apps),
                try optional_value.clone(allocator),
            );
        }

        pub fn getVar(pattern: *Self) ?VarNext {
            const index = pattern.map.getIndex(
                // All vars hash to the same value, so the value of this field
                // will never be read
                Node{ .variable = undefined },
            ) orelse
                return null;

            return VarNext{
                .variable = pattern.map.keys()[index].variable,
                .index = index,
                .next = &pattern.map.values()[index],
            };
        }

        pub fn getVarApps(pattern: *Self) ?VarNext {
            const index = pattern.map.getIndex(
                // All vars hash to the same value, so this field will never
                // be read
                Node{ .var_apps = undefined },
            ) orelse
                return null;

            return VarNext{
                .variable = pattern.map.keys()[index].var_apps,
                .index = index,
                .next = &pattern.map.values()[index],
            };
        }

        /// The longest length of a match of apps against a pattern. If an apps
        /// matched, leaf will be the last match term result that wasn't null.
        const Match = struct {
            value: ?*Node = null, // Null if a branch was found, but no value
            len: usize = 0, // Checks if complete or partial match
            // indices: []usize, // The bounds subsequent matches should be within
            // TODO: append varmaps instead of mutating
            // var_map: LiteralMap = LiteralMap{}, // Bound variables

            pub fn deinit(self: *Match) void {
                _ = self;

                // Node entries are just references, so they don't need freeing
                // self.var_map.deinit(allocator);
            }
        };

        /// The resulting pattern and match index (if any) from successful
        /// matching (otherwise null is returned from `match`), therefore
        /// `pattern` is always a child of the root.
        const Branch = struct {
            pattern: *Self,
            // index: usize, // where this term matched in the node map
        };

        /// The first half of evaluation. The variables in the node match
        /// anything in the pattern, and vars in the pattern match anything in
        /// the expression. Includes partial prefixes (ones that don't match all
        /// apps). This function returns any pattern branches, even if their
        /// value is null, unlike `match`.
        /// - Any node matches a var pattern including a var (the var node is
        ///   then stored in the var map like any other node)
        /// - A var node doesn't match a non-var pattern (var matching is one
        ///   way)
        /// - A literal node that matches a pattern of both literals and vars
        /// matches the literal part, not the var
        /// Returns a nullable struct describing a successful match containing:
        /// - the value for that match in the pattern
        /// - the minimum index a subsequent match should use, which is one
        /// greater than the previous (except for structural recursion).
        /// - null if no match
        /// Caller owns the slice.
        ///
        // TODO: move var_map from params to result
        // TODO: match vars with first available index and increment it
        pub fn branchTerm(
            self: *Self,
            var_map: *LiteralMap,
            node: Node,
        ) Allocator.Error!?Branch {
            const empty_node = node.asEmpty();
            print("Branching `", .{});
            node.asEmpty().writeSExp(streams.err, null) catch unreachable;
            print("`, ", .{});
            return switch (node) {
                .key,
                .variable,
                .var_apps,
                => if (self.map.getIndex(empty_node)) |next_index| blk: {
                    print("exactly: ", .{});
                    self.map.values()[next_index].write(streams.err) catch
                        unreachable;
                    print(" at index: {?}\n", .{next_index});
                    break :blk Branch{
                        // .index = next_index,
                        .pattern = &self.map.values()[next_index],
                    };
                } else null,
                .pattern => @panic(""),
                // |pattern| {

                // },
                inline else => |sub_apps, tag| blk: {
                    // Check Var as Alternative here, but this probably can't be
                    // a recursive call without a SO
                    print("Branching subapps\n", .{});
                    var next = self.map.get(
                        @unionInit(Node, @tagName(tag), .{}),
                    ) orelse break :blk null;
                    const pat_node =
                        try next.matchAll(var_map, sub_apps) orelse
                        break :blk null;
                    break :blk Branch{ .pattern = &pat_node.pattern };
                },
            } orelse if (self.getVar()) |var_next| blk: {
                // index += 1; // TODO use as limit
                // result.index = var_next.index;
                print("as var `{s}`\n", .{var_next.variable});
                var_next.next.write(streams.err) catch unreachable;
                print("\n", .{});
                // print(" at index: {?}\n", .{result.index});
                const var_result =
                    try var_map.getOrPut(var_next.variable);
                // If a previous var was bound, check that the
                // current key matches it
                if (var_result.found_existing) {
                    if (var_result.value_ptr.*.eql(node)) {
                        print("found equal existing var mapping\n", .{});
                    } else {
                        print("found existing non-equal var mapping\n", .{});
                    }
                } else {
                    print("New Var: {s}\n", .{var_result.key_ptr.*});
                    var_result.value_ptr.* = node;
                }
                break :blk Branch{ .pattern = var_next.next };
            } else null;
        }

        /// Same as match, but with matchTerm's signature. Returns a complete
        /// match of all apps or else null. For partial matches, no new vars
        /// are put into the var_map, and null is returned.
        /// Caller owns.
        pub fn matchAll(
            self: *Self,
            var_map: *LiteralMap,
            tree: Tree,
        ) Allocator.Error!?*Node {
            const result = try self.match(var_map, tree);
            // TODO: rollback map if match fails partway
            const prev_len = var_map.keys().len;
            _ = prev_len;
            print("Match All\n", .{});
            // print("Result and Query len equal: {}\n", .{result.len == apps.len});
            // print("Result value null: {}\n", .{result.value == null});
            return if (result.len == tree.root.len)
                result.value
            else
                null;
        }

        /// Follow `apps` in `self` until no matches. Then returns the furthest
        /// pattern node and its corresponding number of matched apps that
        /// was in the trie. Starts matching at [index, ..), in the
        /// longest path otherwise any index for a shorter path.
        /// Caller owns and should free the result's value and var_map with
        /// Match.deinit.
        pub fn match(
            self: *Self,
            var_map: *LiteralMap,
            // indices: []usize,
            tree: Tree,
        ) Allocator.Error!Match {
            var current = self;
            var result = Match{
                .value = self.value,
                // .indices = indices
            };
            if (current.getVarApps()) |var_apps_next| {
                // Store as a Node for convenience
                const node = Node.ofApps(tree);
                print("Matching as var apps `{s}`\n", .{var_apps_next.variable});
                var_apps_next.next.write(streams.err) catch unreachable;
                print("\n", .{});
                const var_result =
                    try var_map.getOrPut(var_apps_next.variable);
                if (var_result.found_existing) {
                    if (var_result.value_ptr.*.eql(node)) {
                        print("found equal existing var apps mapping\n", .{});
                    } else {
                        print("found existing non-equal var apps mapping\n", .{});
                    }
                } else {
                    print("New Var Apps: {s}\n", .{var_result.key_ptr.*});
                    var_result.value_ptr.* = node;
                }
                result.value = var_apps_next.next.value;
                result.len = tree.root.len;
            } else for (tree.root, 1..) |app, len| {
                // TODO: save var_map state and restore if partial match and var
                // apps
                if (try current.branchTerm(var_map, app)) |branch| {
                    current = branch.pattern;
                    if (current.value) |value| {
                        result.value = value;
                        result.len = len;
                    }
                } else break;
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
            var_map: LiteralMap,
            tree: Tree,
        ) Allocator.Error!Tree {
            var result = ArrayListUnmanaged(Node){};
            for (tree.root) |node| switch (node) {
                .key => |key| try result.append(
                    allocator,
                    Node.ofKey(try Manager.copy(allocator, key)),
                ),
                .variable => |variable| {
                    print("Var get: ", .{});
                    if (var_map.get(variable)) |var_node|
                        var_node.write(streams.err) catch unreachable
                    else
                        print("null", .{});
                    print("\n", .{});
                    try result.append(
                        allocator,
                        try (var_map.get(variable) orelse
                            node).copy(allocator),
                    );
                },
                .var_apps => |var_apps| {
                    print("Var apps get: ", .{});
                    if (var_map.get(var_apps)) |var_node|
                        var_node.write(streams.err) catch unreachable
                    else
                        print("null", .{});
                    print("\n", .{});
                    if (var_map.get(var_apps)) |apps_node| {
                        for (apps_node.apps.root) |app|
                            try result.append(
                                allocator,
                                try app.copy(allocator),
                            );
                    } else try result.append(allocator, node);
                },
                inline .apps, .arrow, .match, .list, .infix => |apps, tag| {
                    try result.append(allocator, @unionInit(
                        Node,
                        @tagName(tag),
                        try pattern.rewrite(allocator, var_map, apps),
                    ));
                },
                // .pattern => |sub_pat| {
                //     _ = sub_pat;
                // },
                else => panic("unimplemented", .{}),
            };
            // TODO: add heights
            return Tree{
                .root = try result.toOwnedSlice(allocator),
                .height = tree.height,
            };
        }

        /// Performs a single full match and if possible a rewrite.
        /// Caller owns and should free with deinit.
        pub fn evaluateStep(
            self: *Self,
            allocator: Allocator,
            tree: Tree,
        ) Allocator.Error!Tree {
            var var_map = LiteralMap.init(allocator);
            defer var_map.deinit();
            var match_result = try self.match(&var_map, tree);
            defer match_result.deinit();
            if (match_result.value) |value| {
                print(
                    "Matched {} of {} apps: ",
                    .{ match_result.len, tree.root.len },
                );
                value.write(streams.err) catch unreachable;
                print("\n", .{});
                return self.rewrite(allocator, var_map, value.apps);
            } else {
                print(
                    "No match, after {} nodes followed\n",
                    .{match_result.len},
                );
                return .{};
            }
        }

        /// Given a pattern and a query to match against it, this function
        /// continously matches until no matches are found, or a match repeats.
        /// Match result cases:
        /// - a pattern of lower ordinal: continue
        /// - the same pattern: continue unless patterns are equivalent
        ///   expressions (fixed point)
        /// - a pattern of higher ordinal: break
        // TODO: fix ops as keys not being matched
        // TODO: refactor with evaluateStep
        pub fn evaluate(
            self: *Self,
            allocator: Allocator,
            apps: Tree,
        ) Allocator.Error!Tree {
            var index: usize = 0;
            var result = ArrayListUnmanaged(Node){};
            while (index < apps.len) {
                print("Matching from index: {}\n", .{index});
                const query = apps[index..];
                var var_map = LiteralMap.init(allocator);
                defer var_map.deinit();
                const matched = try self.match(&var_map, query);
                if (matched.len == 0) {
                    print("No match, skipping index {}.\n", .{index});
                    try result.append(
                        allocator,
                        // Evaluate nested apps that failed to match
                        // TODO: replace recursion with a continue
                        switch (apps[index]) {
                            inline .apps, .match, .arrow, .list => |slice, tag|
                            // Recursively eval but preserve node type
                            @unionInit(
                                Node,
                                @tagName(tag),
                                try self.evaluate(allocator, slice),
                            ),
                            else => try apps[index].copy(allocator),
                        },
                    );
                    index += 1;
                    continue;
                }
                print("vars in map: {}\n", .{var_map.entries.len});
                if (matched.value) |next| {
                    // Prevent infinite recursion at this index. Recursion
                    // through other indices will be terminated by match index
                    // shrinking.
                    if (query.len == next.apps.len)
                        for (query, next.apps) |app, next_app| {
                            // check if the same pattern's shape could be matched
                            // TODO: use an app match function here instead of eql
                            if (!app.asEmpty().eql(next_app))
                                break;
                        } else break; // Don't evaluate the same pattern
                    print("Eval matched {s}: ", .{@tagName(next.*)});
                    next.write(streams.err) catch unreachable;
                    streams.err.writeByte('\n') catch unreachable;
                    const rewritten =
                        try self.rewrite(allocator, var_map, next.apps);
                    defer Node.ofApps(rewritten).deinit(allocator);
                    const sub_eval = try self.evaluate(allocator, rewritten);
                    defer allocator.free(sub_eval);
                    try result.appendSlice(allocator, sub_eval);
                } else {
                    try result.appendSlice(allocator, query);
                    print("Match, but no value\n", .{});
                }
                index += matched.len;
            }
            print("Eval: ", .{});
            for (result.items) |app| {
                print("{s} ", .{@tagName(app)});
                app.writeSExp(streams.err, 0) catch unreachable;
                streams.err.writeByte(' ') catch unreachable;
            }
            streams.err.writeByte('\n') catch unreachable;
            return result.toOwnedSlice(allocator);
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
                try writer.writeAll("❬");
                try value.writeIndent(writer, null);
                try writer.writeAll("❭ ");
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

test "Pattern: eql" {
    const Pat = StringPattern();
    const Node = Pat.Node;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p1 = Pat{};
    var p2 = Pat{};

    var value = Node{ .key = "123" };
    const value2 = Node{ .key = "123" };
    // Reverse order because patterns are values, not references
    try p2.map.put(allocator, "Bb", Pat{ .value = &value });
    try p1.map.put(allocator, "Aa", p2);

    var p_put = Pat{};
    _ = try p_put.putApps(allocator, &.{
        Node{ .key = "Aa" },
        Node{ .key = "Bb" },
    }, value2);
    try p1.write(streams.err);
    try streams.err.writeByte('\n');
    try p_put.write(streams.err);
    try streams.err.writeByte('\n');
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
    //         current = current.map.Node.ofKey(i);
    //     }
    // }

    print("\nSet Pattern:\n", .{});
    try pattern.write(streams.err);
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
    const Pat = StringPattern();
    const Node = Pat.Node;
    var nested_pattern = try Pat.create(testing.allocator);
    defer nested_pattern.destroy(testing.allocator);
    nested_pattern.getOrPut(testing.allocator, Pat{}, "subpat's value");

    _ = try nested_pattern.putKeys(
        testing.allocator,
        &.{ "cherry", "blossom", "tree" },
        Node.ofKey("beautiful"),
    );
}

test "Memory: idempotency" {
    const Pat = AutoPattern(usize, void);
    var pattern = Pat{};
    defer pattern.deinit(testing.allocator);
}

test "Memory: nested pattern" {
    const Pat = StringPattern();
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

// TODO: test for multiple patterns with different variables, and with multiple
// equal variables
// TODO: test for patterns with equal keys but different structure, like A (B)
// and (A B)

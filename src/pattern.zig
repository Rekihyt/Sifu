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
const debug_mode = @import("builtin").mode == .Debug;

pub fn AutoPattern(
    comptime Literal: type,
) type {
    if (Literal == []const u8) @compileError(
        \\Cannot make a pattern automatically from []const u8,
        \\please use AutoStringPattern instead.
    );
    return PatternWithContext(Literal, AutoContext(Literal));
}

pub fn StringPattern() type {
    return PatternWithContext(
        []const u8,
        StringContext,
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

const meta = std.meta;
const ArenaAllocator = std.heap.ArenaAllocator;
const t = @import("test.zig");

///
/// A trie-like type based on the given literal type. Each pattern contains zero
/// or more children.
///
/// The literal and var type must be hashable, and must NOT contain any cycles.
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
/// of Keys and Vars. Must have a copy and deinit function for each. For
/// borrowing, simply pass null or a no-op manager.
pub fn PatternWithContext(
    comptime Literal: type,
    comptime Ctx: type,
) type {
    return struct {
        pub const Self = @This();
        /// Keys must be efficiently iterable, but that is provided by the index
        /// map anyways so an array map here isn't needed.
        pub const NodeMap = std.HashMapUnmanaged(
            DetachedNode,
            Self,
            util.IntoContext(DetachedNode),
            std.hash_map.default_max_load_percentage,
        );
        pub const GetOrPutResult = NodeMap.GetOrPutResult;
        /// Caches a mapping of vars to their indices (rules with the same
        /// vars can be repeated arbitrarily) so that they can be efficiently
        /// iterated over.
        const VarCache = std.StringArrayHashMapUnmanaged(
            ArrayListUnmanaged(usize),
        );
        /// Keeps track of which vars and var_apps are bound to what part of an
        /// expression given during matching.
        pub const VarBindings = std.StringHashMapUnmanaged(Node);
        /// A key node and its next term pointer for a pattern, where only the
        /// length of slice types are stored for keys (instead of pointers).
        /// The term/next is a reference to a key/value in the NodeMap, which
        /// owns both. This type is isomorphic to a key-value entry in NodeMap
        /// to form a bijection.
        pub const Branch = struct {
            term: *const DetachedNode,
            next: *const Self,
        };
        /// This maps to branches, but the type is Branch instead of just *Self
        /// to retrieve keys if necessary. The Self pointer references another
        /// field in this pattern, such as `keys`.
        const IndexMap = std.AutoArrayHashMapUnmanaged(usize, Branch);
        /// ArrayMaps are used as both branches and values need to support
        /// efficient iteration, to support recursive matching variables.
        const ValueMap = std.AutoArrayHashMapUnmanaged(usize, *Node);
        const Iterator = ValueMap.Iterator;
        /// Used to store the children, which are the next patterns pointed to
        /// by literal keys.
        pub const PatternList = std.ArrayListUnmanaged(Self);
        /// Tracks the order of entries in the trie and references to next
        /// pointers. An index for an entry is saved at every branch in the trie
        /// for a given key. Branches may or may not contain values in their
        /// ValueMap, for example in `Foo Bar -> 123`, the branch at `Foo` would
        /// have an index to the key `Bar` and a leaf pattern containing the
        /// value `123`.
        indices: IndexMap = .{},
        /// Maps terms to the next pattern, if there is one. These form the
        /// branches of the trie for a specific level of nesting. Each Key is
        /// in the map is unique, but they can be repeated in separate indices.
        /// Therefore this stores its own next Self pointer, and the indices for
        /// each key.
        /// The patterns that for types that are shared (variables and nested
        /// apps/patterns) are encoded by a layer of pointer indirection in
        /// their respective fields here.
        keys: NodeMap = .{},
        /// Caches the indices of vars and var_apps in the keys NodeMap so that
        /// they can be efficiently queried
        var_cache: VarCache = .{},

        /// Similar to the index map, this stores the values of the trie for the
        /// node at a given index/path.
        values: ValueMap = .{},

        /// An apps (a list of nodes) Node with its height cached.
        pub const Apps = struct {
            root: []const Node = &.{},
            height: usize = 1, // apps have a height because they are a branch

            pub fn copy(self: Apps, allocator: Allocator) !Apps {
                const apps_copy = try allocator.alloc(Node, self.root.len);
                for (self.root, apps_copy) |app, *app_copy|
                    app_copy.* = try app.copy(allocator);

                return Apps{
                    .root = apps_copy,
                    .height = self.height,
                };
            }

            // Clears all memory and resets this Apps's root to an empty apps.
            pub fn deinit(apps: Apps, allocator: Allocator) void {
                for (apps.root) |*app| {
                    @constCast(app).deinit(allocator);
                }
                allocator.free(apps.root);
            }

            pub fn eql(self: Apps, other: Apps) bool {
                return self.height == other.height and
                    self.root.len == other.root.len and
                    for (self.root, other.root) |app, other_app|
                {
                    if (!app.eql(other_app))
                        break false;
                } else true;
            }

            pub fn hasherUpdate(self: Apps, hasher: anytype) void {
                // Height isn't hashed because it wouldn't add any new
                // information
                for (self.root) |app|
                    app.hasherUpdate(hasher);
            }
        };

        /// Describes the height and width of an Apps (the level of nesting and
        /// length of the root array respectively)
        pub const Dimension = struct {
            height: usize,
            width: usize,
        };

        /// A node without references (excepting Key types that are, such as
        ///strings, as those are only ever borrowed by the pattern).
        pub const DetachedNode = union(enum) {
            key: Literal,
            variable: Literal,
            apps: void,
            var_apps: Literal,
            infix: void,
            match: void,
            arrow: void,
            long_match: void,
            long_arrow: void,
            long_list: void,
            list: void,
            pattern: void,

            pub const hash = util.hashFromHasherUpdate(DetachedNode);

            pub fn hasherUpdate(self: DetachedNode, hasher: anytype) void {
                hasher.update(&mem.toBytes(@intFromEnum(self)));
                switch (self) {
                    .key, .variable, .var_apps => |slice| hasher.update(
                        &mem.toBytes(Ctx.hash(undefined, slice)),
                    ),
                    inline else => |_, tag| {
                        switch (tag) {
                            .arrow, .long_arrow => hasher.update("->"),
                            .match, .long_match => hasher.update(":"),
                            .list => hasher.update(","),
                            else => {},
                        }
                    },
                }
            }

            pub fn eql(node: DetachedNode, other: DetachedNode) bool {
                return if (@intFromEnum(node) != @intFromEnum(other))
                    false
                else switch (node) {
                    .key, .variable, .var_apps => |k| Ctx
                        .eql(undefined, k, other.key, undefined),
                    // TODO: make exact comparisons work with single place
                    // patterns in hashmaps
                    // .variable => |v| Ctx.eql(undefined, v, other.variable, undefined),
                    .pattern => |_| true,
                    inline else => |len| len == other.apps,
                };
            }

            pub fn toNode(self: DetachedNode) Node {
                return switch (self) {
                    inline .key, .variable, .var_apps => |lit, tag| @unionInit(
                        Node,
                        @tagName(tag),
                        lit,
                    ),
                    inline else => |_, tag| @unionInit(
                        Node,
                        @tagName(tag),
                        .{},
                    ),
                };
            }
        };

        /// Nodes form the keys and values of a pattern type (its recursive
        /// structure forces both to be the same type). In Sifu, it is also the
        /// structure given to a source code entry (a `Node(Token)`). It encodes
        /// sequences, nesting, and patterns. The `Literal` is a custom type
        /// to allow storing of metainfo such as a position, and must implement
        /// `toString()` for pattern conversion. It could also be a simple type
        /// for optimization purposes. Sifu maps the syntax described below to
        /// this data structure, but that syntax is otherwise irrelevant. Any
        /// infix operator that isn't a builtin (match, arrow or list) is parsed
        /// into an app. These are ordered in their precedence, which is used
        /// during parsing.
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
            apps: Apps,
            /// Variables that match apps as a term. These are only strictly
            /// needed for matching patterns with ops, where the nested apps
            /// is implicit.
            var_apps: Literal,
            /// The list following a non-builtin operator.
            infix: Apps,
            /// A postfix encoded match pattern, i.e. `x : Int -> x * 2` where
            /// some node (`x`) must match some subpattern (`Int`) in order for
            /// the rest of the match to continue. Like infixes, the apps to
            /// the left form their own subapps, stored here, but the `:` token
            /// is elided.
            match: Apps,
            /// A postfix encoded arrow expression denoting a rewrite, i.e. `A B
            /// C -> 123`. This includes "long" versions of ops, which have same
            /// semantics, but only play a in part parsing/printing. Parsing
            /// shouldn't concern this abstract data structure, and there is
            /// enough information preserved such that during printing, the
            /// correct precedence operator can be recreated.
            arrow: Apps,
            /// TODO: remove. These are here temporarily until the parser is
            /// refactored to determine precedence by tracking tokens instead of
            /// nodes. The pretty printer must also then reconstruct the correct
            /// tokens based on the precedence needed to preserve a given Ast's
            /// structure.
            long_match: Apps,
            long_arrow: Apps,
            long_list: Apps,
            /// A single element in comma separated list, with the comma elided.
            /// Lists are operators that are recognized as separators for
            /// patterns.
            list: Apps,
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
                    inline .key, .variable, .var_apps => self,
                    .pattern => |p| Node.ofPattern(try p.copy(allocator)),
                    inline else => |apps, tag| @unionInit(
                        Node,
                        @tagName(tag),
                        try apps.copy(allocator),
                    ),
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
                    .key, .variable, .var_apps => {},
                    .pattern => |*p| @constCast(p).deinit(allocator),
                    inline else => |apps| apps.deinit(allocator),
                }
            }

            pub const hash = util.hashFromHasherUpdate(Node);

            pub fn hasherUpdate(self: Node, hasher: anytype) void {
                hasher.update(&mem.toBytes(@intFromEnum(self)));
                switch (self) {
                    // Variables are always the same hash in Patterns (in
                    // varmaps they need unique hashes)
                    // TODO: differentiate between repeated and unique vars
                    .key, .variable, .var_apps => |slice| hasher.update(
                        &mem.toBytes(Ctx.hash(undefined, slice)),
                    ),
                    .pattern => |pattern| pattern.hasherUpdate(hasher),
                    inline else => |apps, tag| {
                        switch (tag) {
                            .arrow, .long_arrow => hasher.update("->"),
                            .match, .long_match => hasher.update(":"),
                            .list => hasher.update(","),
                            else => {},
                        }
                        apps.hasherUpdate(hasher);
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
                    inline else => |apps| apps.eql(other.apps),
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

            pub fn ofApps(apps: Apps) Node {
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
                apps: Apps,
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
            /// This is used for two reasons: it helps prevent functions like
            /// `put` from storing refs to a given key Node's memory, and allows
            /// granular matching while perserving order between different node
            /// kinds.
            fn detach(node: Node) DetachedNode {
                return switch (node) {
                    inline .key,
                    .variable,
                    .var_apps,
                    => |lit, tag| @unionInit(DetachedNode, @tagName(tag), lit),
                    .pattern => .{ .pattern = {} }, // TODO: save pattern length
                    inline else => |_, tag|
                    // All slice types hash to their dimensions
                    @unionInit(DetachedNode, @tagName(tag), {}),
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
                    inline else => |apps, tag| {
                        switch (tag) {
                            .arrow => try writer.writeAll("-> "),
                            .match => try writer.writeAll(": "),
                            .long_arrow => try writer.writeAll("--> "),
                            .long_match => try writer.writeAll(":: "),
                            .list => try writer.writeAll(", "),
                            else => {},
                        }
                        // Don't write an s-exp as its redundant for ops
                        try Node.ofApps(apps).writeIndent(writer, optional_indent);
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
                    inline .apps, .list, .arrow, .match, .infix => |apps| {
                        const slice = apps.root;
                        if (slice.len == 0)
                            return;
                        // print("tag: {s}\n", .{@tagName(apps[0])});
                        try slice[0].writeSExp(writer, optional_indent);
                        if (slice.len == 1) {
                            return;
                        } else for (slice[1 .. slice.len - 1]) |app| {
                            // print("tag: {s}\n", .{@tagName(app)});
                            try writer.writeByte(' ');
                            try app.writeSExp(writer, optional_indent);
                        }
                        try writer.writeByte(' ');
                        // print("tag: {s}\n", .{@tagName(apps[apps.len - 1])});
                        try slice[slice.len - 1]
                            .writeSExp(writer, optional_indent);
                    },
                    else => try self.writeSExp(writer, optional_indent),
                }
            }
        };

        /// The results of matching a pattern exactly (vars are matched literally
        /// instead of by building up a apps of their possible values)
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

        /// Asserts that the index exists.
        pub fn getIndex(self: Self, index: usize) *Node {
            return self.getIndexOrNull(index) orelse
                panic("Index {} doesn't exist\n", .{index});
        }
        /// Returns null if the index doesn't exist in the pattern.
        pub fn getIndexOrNull(self: Self, index: usize) ?*Node {
            var current = self;
            while (current.indices.get(index)) |next| {
                current = next.*;
            }
            return current.values.get(index);
        }

        /// Rebuilds the key for a given index using an allocator for the
        /// arrays necessary to support the tree structure, but pointers to the
        /// underlying keys.
        pub fn rebuildKey(self: Self, allocator: Allocator, index: usize) !Apps {
            _ = index; // autofix
            _ = allocator; // autofix
            _ = self; // autofix
            @panic("unimplemented");
        }

        /// Deep copy a pattern by value, as well as Keys and Variables.
        /// Use deinit to free.
        // TODO: optimize by allocating top level maps of same size and then
        // use putAssumeCapacity
        pub fn copy(self: Self, allocator: Allocator) Allocator.Error!Self {
            var result = Self{};
            var map_iter = self.keys.iterator();
            while (map_iter.next()) |entry|
                try result.keys.putNoClobber(
                    allocator,
                    entry.key_ptr.*,
                    try entry.value_ptr.*.copy(allocator),
                );

            // Deep copy the indices map
            var index_iter = self.indices.iterator();
            while (index_iter.next()) |index_entry| {
                const index = index_entry.key_ptr.*;
                const entry = index_entry.value_ptr.*;
                // TODO retrieve the correct pointer to the new trie based on
                // the kind of entry.node
                const next = switch (entry.next) {
                    else => @panic("unimplemented"),
                };
                // Insert a borrowed pointer to the new key copy.
                try result.indices
                    .putNoClobber(allocator, index, .{ entry.node, next });
            }

            @panic("todo: copy all fields");
            // return result;
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
        /// TODO: check frees properly for owned and borrowed managers
        pub fn deinit(self: *Self, allocator: Allocator) void {
            defer self.keys.deinit(allocator);
            var iter = self.keys.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.*.deinit(allocator);
            }
            defer self.indices.deinit(allocator);
            defer self.values.deinit(allocator);
            for (self.values.values()) |value|
                value.destroy(allocator);
        }

        pub fn hash(self: Self) u32 {
            var hasher = Wyhash.init(0);
            self.hasherUpdate(&hasher);
            return @truncate(hasher.final());
        }

        pub fn hasherUpdate(self: Self, hasher: anytype) void {
            var map_iter = self.keys.iterator();
            while (map_iter.next()) |entry| {
                entry.key_ptr.*.hasherUpdate(hasher);
                entry.value_ptr.*.hasherUpdate(hasher);
            }
            var index_iter = self.indices.iterator();
            // TODO: recurse
            while (index_iter.next()) |*entry| {
                hasher.update(mem.asBytes(entry));
            }
        }

        fn keyEql(k1: Literal, k2: Literal) bool {
            return Ctx.eql(undefined, k1, k2, undefined);
        }

        fn branchEql(comptime E: type, b1: E, b2: E) bool {
            return b1.key_ptr.eql(b2.key_ptr.*) and
                b1.value_ptr.eql(b2.value_ptr.*);
        }

        /// Patterns are equal if they have the same literals, sub-arrays and
        /// sub-patterns and if their debruijn variables are equal. The patterns
        /// are assumed to be in debruijn form already.
        pub fn eql(self: Self, other: Self) bool {
            if (self.keys.count() != other.keys.count() or
                self.indices.entries.len != other.indices.entries.len or
                self.values.entries.len != other.values.entries.len)
                return false;
            var map_iter = self.keys.iterator();
            var other_map_iter = other.keys.iterator();
            while (map_iter.next()) |entry| {
                const other_entry = other_map_iter.next() orelse
                    return false;
                if (!(entry.key_ptr.*.eql(other_entry.key_ptr.*)) or
                    entry.value_ptr != other_entry.value_ptr)
                    return false;
            }
            var index_iter = self.indices.iterator();
            var other_index_iter = other.indices.iterator();
            while (index_iter.next()) |entry| {
                const other_entry = other_index_iter.next() orelse
                    return false;
                const val = entry.value_ptr.*;
                const other_index = other_entry.value_ptr.*;
                if (entry.key_ptr.* != other_entry.key_ptr.* or
                    !val.term.eql(other_index.term.*))
                    return false;
            }
            return true;
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
                .key, .variable => pattern.keys.get(node),
                .apps => |sub_apps| blk: {
                    const sub_pat = pattern.keys.get(Node.ofApps(.{})) orelse
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
            apps: Apps,
        ) ExactPrefix {
            var current = pattern;
            const index: usize = undefined; // TODO
            // Follow the longest branch that exists
            const prefix_len = for (apps.root, 0..) |app, i| {
                current = current.getTerm(app) orelse
                    break i;
            } else apps.len;

            return .{ .len = prefix_len, .index = index, .leaf = current };
        }

        pub fn get(
            pattern: Self,
            apps: Apps,
        ) ?Self {
            const prefix = pattern.getPrefix(apps);
            return if (prefix.len == apps.len)
                prefix.leaf
            else
                null;
        }

        pub fn append(
            pattern: *Self,
            allocator: Allocator,
            key: Apps,
            optional_value: ?*Node,
        ) Allocator.Error!*Self {
            // The length of values will be the next entry index after insertion
            const len = pattern.count();
            var branch = pattern;
            branch = try branch.ensurePath(allocator, len, key);
            // If there isn't a value, use the key as the value instead
            const value = optional_value orelse
                try Node.ofApps(key).clone(allocator);
            try branch.values.putNoClobber(allocator, len, value);
            return branch;
        }

        /// Creates the necessary branches and key entries in the pattern for
        /// apps, and returns a pointer to the branch at the end of the path.
        /// While similar to a hashmap's getOrPut function, ensurePath always
        /// adds a new index, asserting that it did not already exist. There is
        /// no getOrPut equivalent for patterns because they are append-only.
        ///
        /// The index must not already be in the pattern.
        /// Apps are copied.
        /// Returns a pointer to the updated pattern node. If the given apps is
        /// empty (0 len), the returned key and index are undefined.
        fn ensurePath(
            pattern: *Self,
            allocator: Allocator,
            index: usize,
            apps: Apps,
        ) !*Self {
            var current = pattern;
            for (apps.root) |app| {
                const entry = try current.ensurePathTerm(allocator, index, app);
                current = entry.value_ptr;
            }
            return current;
        }

        /// Follows or creates a path as necessary in the pattern's trie and
        /// indices. Only adds branches, not values.
        fn ensurePathTerm(
            pattern: *Self,
            allocator: Allocator,
            index: usize,
            term: Node,
        ) Allocator.Error!NodeMap.Entry {
            const detached = term.detach();
            // Get or put a literal or a level of nesting as an empty node
            // branch to a new pattern.
            // No need to copy here because empty slices have 0 length
            var entry = try pattern.keys.getOrPutValue(
                allocator,
                detached,
                Self{},
            );
            try pattern.indices.putNoClobber(allocator, index, Branch{
                .term = entry.key_ptr,
                .next = entry.value_ptr,
            });
            switch (term) {
                inline .key, .variable, .var_apps => {},
                .pattern => |sub_pat| {
                    _ = sub_pat;
                    @panic("unimplemented\n");
                },
                // App pattern's values will always be patterns too, which will
                // map nested apps to the next app on the current level.
                // The resulting encoding appears counter-intuitive when printed
                // because each level of nesting must be a branch to enable
                // pattern matching.
                inline else => |apps| {
                    // All op types are encoded the same way after their top
                    // level hash. These don't need special treatment because
                    // their structure is simple, and their operator unique.
                    var next = try entry.value_ptr
                        .ensurePath(allocator, index, apps);
                    // Add the next index (always unique because patterns are
                    // append only, hence putNoClobber) to the inner index of
                    // the node's key map.
                    const get_or_put = try next.values.getOrPut(
                        allocator,
                        index,
                    );
                    if (!get_or_put.found_existing) {
                        get_or_put.value_ptr.* = try Node
                            .createPattern(allocator, Self{});
                    }
                    entry.value_ptr = &get_or_put.value_ptr.*.pattern;
                },
            }
            return entry;
        }

        /// Add a node to the pattern by following `keys`, wrapping them into an
        /// App of Nodes.
        /// Allocations:
        /// - The path followed by apps is allocated and copied recursively
        /// - The node, if given, is allocated and copied recursively
        /// Freeing should be done with `destroy` or `deinit`, depending on
        /// how `self` was allocated
        pub fn putKeys(
            self: *Self,
            allocator: Allocator,
            keys: []const Literal,
            optional_value: ?Node,
        ) Allocator.Error!*Self {
            var apps = allocator.alloc(Literal, keys.len);
            defer apps.free(allocator);
            for (apps, keys) |*app, key|
                app.* = Node.ofKey(key);

            return self.put(
                allocator,
                Node.ofApps(apps),
                try optional_value.clone(allocator),
            );
        }

        /// An iterator for all matches of a given apps against a pattern. If
        /// an apps matched, leaf will be the last match term result that wasn't
        /// null.
        const Match = struct {
            values: Iterator, // Iterator for the matched values, if any
            len: usize = 0, // Checks if complete or partial match
            index: usize = 0, // The bounds subsequent matches should be within
            // TODO: append varmaps instead of mutating
            // bindings: LiteralPtrMap = LiteralPtrMap{}, // Bound variables

            pub fn deinit(self: *Match) void {
                _ = self;

                // Node entries are just references, so they don't need freeing
                // self.bindings.deinit(allocator);
            }
        };

        /// The resulting pattern and match index (if any) from a partial,
        /// successful matching (otherwise null is returned from `match`),
        /// therefore `pattern` is always a child of the root. This type is
        /// similar to IndexMap.Entry.
        const BranchResult = struct {
            pattern: Self,
            index: usize, // where this term matched in the node map
        };

        /// The first half of evaluation. The variables in the node match
        /// anything in the pattern, and vars in the pattern match anything in
        /// the expression. Includes partial prefixes (ones that don't match all
        /// apps). This function returns any pattern branches, even if their
        /// value is null, unlike `match`. The position defines the index where
        /// allowable matches begin. As a pattern is matched, a hashmap for vars
        /// is populated with each var's bound variable. These can the be used
        /// by the caller for rewriting.
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
        // TODO: move bindings from params to result
        // TODO: match vars with first available index and increment it
        // TODO: prioritize indices order over exact matching when possible
        pub fn branchTerm(
            self: *Self,
            allocator: Allocator,
            bindings: *VarBindings,
            position: usize,
            node: Node,
        ) Allocator.Error!?BranchResult {
            const detached_node = node.detach();
            print("Branching `", .{});
            node.writeSExp(streams.err, null) catch unreachable;
            print("`, ", .{});
            var index = position;
            return switch (node) {
                .key => if (self.keys.getEntry(detached_node)) |entry| blk: {
                    const current = entry.value_ptr.*;
                    print("exactly: {s}\n", .{node.key});

                    // Check that in the branch matched, there is a valid index
                    // TODO: make O(1) by caching the internal index to skip
                    // previously matched indices
                    // TODO: Check vars if this fails, and prioritize index
                    // ordering over exact literal matches
                    if (current.indices.get(position)) |branch|
                        break :blk BranchResult{
                            .pattern = branch.next.*,
                            .index = index,
                        }
                    else if (current.values.contains(position))
                        break :blk BranchResult{
                            .pattern = current,
                            .index = index,
                        }
                    else for (current.indices.keys()) |next_index| {
                        if (index > position) {
                            index = next_index;
                            break;
                        }
                    } else {
                        print(
                            \\Highest index of {} is smaller than current
                            \\ position {}, not matching.
                            \\
                        ,
                            .{ index, position },
                        );
                        break :blk null;
                    }
                    print(" at index: {}\n", .{index});
                    break :blk BranchResult{
                        .index = index,
                        .pattern = current,
                    };
                } else null,
                .variable, .var_apps => @panic("unimplemented"),
                .pattern => @panic("unimplemented"), // |pattern| {},
                inline else => |sub_apps, tag| blk: {
                    // Check Var as Alternative here, but this probably can't be
                    // a recursive call without a stack overflow
                    print("Branching subapps\n", .{});
                    var next = self.keys.get(
                        @unionInit(DetachedNode, @tagName(tag), {}),
                    ) orelse break :blk null;
                    var matches =
                        try next.matchAll(allocator, bindings, sub_apps) orelse
                        break :blk null;
                    const entry = while (matches.values.next()) |entry| {
                        if (entry.key_ptr.* >= position)
                            break entry;
                    } else break :blk null;
                    break :blk BranchResult{
                        .index = entry.key_ptr.*,
                        .pattern = entry.value_ptr.*.pattern,
                    };
                },
            } orelse if (self.var_cache.count() > 0) blk: {
                // index += 1; // TODO use as limit
                // result.index = var_next.index;
                // TODO: check correct index for next var
                const var_next = self.var_cache.entries.get(0);
                print(
                    "as var `{s}` with index {}\n",
                    .{ var_next.key, var_next.value },
                );
                // print(" at index: {?}\n", .{result.index});
                const var_result =
                    try bindings.getOrPut(allocator, var_next.key);
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
                break :blk {
                    @panic("unimplemented");
                };
                // break :blk BranchResult{ .pattern = var_next.value };
            } else null;
        }

        /// Same as match, but with matchTerm's signature. Returns a complete
        /// match of all apps or else null. For partial matches, no new vars
        /// are put into the bindings, and null is returned.
        /// Caller owns.
        pub fn matchAll(
            self: *Self,
            allocator: Allocator,
            bindings: *VarBindings,
            apps: Apps,
        ) Allocator.Error!?Match {
            const result = try self.match(allocator, bindings, apps);
            // TODO: rollback map if match fails partway
            const prev_len = bindings.size;
            _ = prev_len;
            print("Match All\n", .{});
            // print("Result and Query len equal: {}\n", .{result.len == apps.len});
            // print("Result value null: {}\n", .{result.value == null});
            return if (result.len == apps.root.len)
                result // TODO: maybe return values here?
            else
                null;
        }

        /// Follow `apps` in `self` until no matches. Then returns the furthest
        /// pattern node and its corresponding number of matched apps that
        /// was in the trie. Starts matching at [index, ..), in the
        /// longest path otherwise any index for a shorter path.
        /// Caller owns and should free the result's value and bindings with
        /// Match.deinit.
        pub fn match(
            self: Self,
            allocator: Allocator,
            bindings: *VarBindings,
            apps: Apps,
        ) Allocator.Error!Match {
            var current = self;
            var len: usize = 0;
            var index: usize = 0;
            // if (current.next.variable) |var_next| {
            // _ = var_next; // autofix
            // @panic("unimplemented");
            // } else if (current.next.var_apps) |var_apps| {
            //     // Store as a Node for convenience
            //     const node = Node.ofApps(apps);
            //     print("Matching as var apps `{s}`\n", .{current.var_apps});
            //     var_apps_next.next.write(streams.err) catch unreachable;
            //     print("\n", .{});
            //     const var_result =
            //         try bindings.getOrPut(allocator, var_apps_next.variable);
            //     if (var_result.found_existing) {
            //         if (var_result.value_ptr.*.eql(node)) {
            //             print("found equal existing var apps mapping\n", .{});
            //         } else {
            //             print("found existing non-equal var apps mapping\n", .{});
            //         }
            //     } else {
            //         print("New Var Apps: {s}\n", .{var_result.key_ptr.*});
            //         var_result.value_ptr.* = node;
            //     }
            //     // result.value = var_apps_next.next.value;
            //     result.len = apps.root.len;

            for (apps.root) |app| {
                // TODO: save bindings state and restore if partial match and var
                // apps
                if (try current.branchTerm(allocator, bindings, index, app)) |branch| {
                    current = branch.pattern;
                    index = branch.index;
                    if (index < current.values.count()) {
                        len += 1;
                    } else break;
                }
            }
            return Match{
                .values = current.values.iterator(),
                .len = len,
                .index = index,
            };
        }

        /// The second half of an evaluation step. Rewrites all variable
        /// captures into the matched expression. Copies any variables in node
        /// if they are keys in bindings with their values. If there are no
        /// matches in bindings, this functions is equivalent to copy. Result
        /// should be freed with deinit.
        pub fn rewrite(
            pattern: Self,
            allocator: Allocator,
            bindings: VarBindings,
            apps: Apps,
        ) Allocator.Error!Apps {
            var result = ArrayListUnmanaged(Node){};
            for (apps.root) |node| switch (node) {
                .key => |key| try result.append(allocator, Node.ofKey(key)),
                .variable => |variable| {
                    print("Var get: ", .{});
                    if (bindings.get(variable)) |var_node|
                        var_node.write(streams.err) catch unreachable
                    else
                        print("null", .{});
                    print("\n", .{});
                    try result.append(
                        allocator,
                        try (bindings.get(variable) orelse
                            node).copy(allocator),
                    );
                },
                .var_apps => |var_apps| {
                    print("Var apps get: ", .{});
                    if (bindings.get(var_apps)) |var_node|
                        var_node.write(streams.err) catch unreachable
                    else
                        print("null", .{});
                    print("\n", .{});
                    if (bindings.get(var_apps)) |apps_node| {
                        for (apps_node.apps.root) |app|
                            try result.append(
                                allocator,
                                try app.copy(allocator),
                            );
                    } else try result.append(allocator, node);
                },
                inline .apps, .arrow, .match, .list, .infix => |nested, tag| {
                    try result.append(allocator, @unionInit(
                        Node,
                        @tagName(tag),
                        try pattern.rewrite(allocator, bindings, nested),
                    ));
                },
                // .pattern => |sub_pat| {
                //     _ = sub_pat;
                // },
                else => panic("unimplemented", .{}),
            };
            return Apps{
                .root = try result.toOwnedSlice(allocator),
                .height = apps.height,
            };
        }

        /// Performs a single full match and if possible a rewrite.
        /// Caller owns and should free with deinit.
        pub fn evaluateStep(
            self: *Self,
            allocator: Allocator,
            apps: Apps,
        ) Allocator.Error!Apps {
            var bindings = VarBindings{};
            defer bindings.deinit(allocator);
            var match_result = try self.match(allocator, &bindings, apps);
            defer match_result.deinit();
            while (match_result.values.next()) |entry| {
                const index, const value =
                    .{ entry.key_ptr.*, entry.value_ptr.* };
                print(
                    "Matched {} of {} apps at index {}: ",
                    .{ match_result.len, apps.root.len, index },
                );
                value.write(streams.err) catch unreachable;
                print("\n", .{});
                return self.rewrite(allocator, bindings, value.apps);
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
            apps: Apps,
        ) Allocator.Error!Apps {
            var index: usize = 0;
            var result = ArrayListUnmanaged(Node){};
            while (index < apps.len) {
                print("Matching from index: {}\n", .{index});
                const query = apps[index..];
                var bindings = VarBindings{};
                defer bindings.deinit(allocator);
                const matched = try self.match(&bindings, query);
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
                print("vars in map: {}\n", .{bindings.entries.len});
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
                        try self.rewrite(allocator, bindings, next.apps);
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

        pub fn count(self: Self) usize {
            return self.indices.count() + self.values.count();
        }

        /// Pretty print a pattern on multiple lines
        pub fn pretty(self: Self, writer: anytype) !void {
            try self.writeIndent(writer, 0);
        }

        /// Print a pattern without newlines
        pub fn write(self: Self, writer: anytype) !void {
            try self.writeIndent(writer, null);
        }

        /// Writes a single entry in the pattern canonically. Index must be
        /// valid.
        pub fn writeIndex(self: Self, writer: anytype, index: usize) !void {
            var nested = std.BoundedArray(enum { apps, pattern }, 4096){};
            var current = self;
            if (comptime debug_mode)
                try writer.print("{} | ", .{index});
            while (current.indices.get(index)) |branch| {
                switch (branch.term.*) {
                    .key, .variable, .var_apps => |term| {
                        try writer.writeAll(term);
                        try writer.writeByte(' ');
                    },
                    .apps => {
                        try nested.append(.apps);
                        try writer.writeByte('(');
                    },
                    .pattern => {
                        try nested.append(.pattern);
                        try writer.writeByte('{');
                    },
                    else => @panic("unimplemented"),
                }
                current = branch.next.*;
                // Get the next continuation of the pattern after a level of
                // nesting, which is wrapped as a value
                if (current.values.get(index)) |next| {
                    switch (nested.popOrNull() orelse break) {
                        .apps => try writer.writeByte(')'),
                        .pattern => try writer.writeByte('}'),
                    }
                    try writer.writeByte(' ');
                    current = next.pattern;
                }
            }
            try writer.writeAll("-> ");
            try current.values.get(index).?.writeIndent(writer, null);
        }

        /// Print a pattern in order based on indices.
        pub fn writeCanonical(self: Self, writer: anytype) !void {
            for (0..self.count()) |index| {
                try self.writeIndex(writer, index);
                try writer.writeByte('\n');
            }
        }

        pub const indent_increment = 2;
        fn writeIndent(
            self: Self,
            writer: anytype,
            optional_indent: ?usize,
        ) @TypeOf(writer).Error!void {
            try writer.writeAll("❬");
            for (self.values.entries.items(.value)) |value| {
                try value.writeIndent(writer, null);
                try writer.writeAll(", ");
            }
            try writer.writeAll("❭ ");
            const optional_indent_inc = if (optional_indent) |indent|
                indent + indent_increment
            else
                null;
            try writer.writeByte('{');
            try writer.writeAll(if (optional_indent) |_| "\n" else "");
            try writeEntries(self.keys, writer, optional_indent_inc);
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
                try node.toNode().writeSExp(writer, null);
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
    try testing.expect(pattern.keys.contains(1));
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

    try pattern.keys.put(testing.allocator, Node{ .pattern = &nested_pattern }, value_pattern);

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

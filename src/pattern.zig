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

pub fn PatternWithContext(
    comptime Key: type,
    comptime Var: type,
    comptime KeyCtx: type,
    comptime VarCtx: type,
) type {
    return PatternWithContextAndFree(Key, Var, KeyCtx, VarCtx, null, null);
}

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
pub fn PatternWithContextAndFree(
    comptime Key: type,
    comptime Var: type,
    comptime KeyCtx: type,
    comptime VarCtx: type,
    comptime keyFreeFn: ?(fn (Allocator, anytype) void),
    comptime varFreeFn: ?(fn (Allocator, anytype) void),
) type {
    return struct {
        pub const Self = @This();
        pub const NodeMap = std.ArrayHashMapUnmanaged(
            Node, // The tree
            *Self, // The next pattern in the trie for this key's tree
            util.IntoArrayContext(Node),
            true,
        );
        /// This is a pointer to the pattern at the end of some path of nodes,
        /// and an index to the start of the path.
        const GetOrPutResult = struct {
            // the value in the node map (the value is a pointer, this isn't a
            // pointer to memory managed by the node map)
            pattern_ptr: *Self,
            index: usize, // the index in the top level node map
            found_existing: bool,
        };
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
        /// A null val represents an undefined pattern, for example in `Foo
        /// Bar -> 123`, the val at `Foo` would be null.
        val: ?*Node = null, // TODO: check pointer still necessary

        /// Nodes form the keys and values of a pattern type (its recursive
        /// structure forces both to be the same type). In Sifu, it is also the
        /// structure given to a source code entry (a `Node(Token)`). It encodes
        /// sequences, nesting, and patterns.
        /// The `Key` is a custom type to allow storing of metainfo such as a
        /// position, and must implement `toString()` for pattern conversion.
        /// It could also be a simple type for optimization purposes. Sifu maps
        /// the syntax described below to this data structure, but that syntax
        /// is otherwise irrelevant. Any infix operator that isn't a builtin
        /// (match, arrow or comma) is parsed into an app.
        /// These are ordered in their precedence, which is used during parsing.
        pub const Node = union(enum) {
            /// A unique constant, literal values. Uniqueness when in a pattern
            /// arises from NodeMap referencing the same value multiple times
            /// (based on Key.eql).
            key: Key,
            /// A Var matches and stores a locally-unique key. During rewriting,
            /// whenever the key is encountered again, it is rewritten to this
            /// pattern's val. A Var pattern matches anything, including nested
            /// patterns. It only makes sense to match anything after trying to
            /// match something specific, so Vars always successfully match (if
            /// there is a Var) after a Key or Subpat match fails.
            variable: Var,
            /// Spaces separated juxtaposition, or commas/parens for nested apps.
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
            /// Commas are operators that are recognized as separators for
            /// patterns.
            comma: []const Node,
            // A pointer here saves space depending on the size of `Key`
            /// An expression in braces.
            pattern: Self,

            /// Performs a deep copy, resulting in a Node the same size as the
            /// original.
            /// The copy should be freed with `deinit`.
            pub fn copy(self: Node, allocator: Allocator) Allocator.Error!Node {
                return switch (self) {
                    .key, .variable => self, // TODO: comptime copy if pointer
                    .pattern => |p| Node.ofPattern(try p.copy(allocator)),
                    inline .apps, .arrow, .match, .comma => |apps, tag| blk: {
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

            pub fn destroySlice(
                slice: []const Node,
                allocator: Allocator,
            ) void {
                for (slice) |*app|
                    @constCast(app).deinit(allocator);
                allocator.free(slice);
            }

            pub fn deinit(self: *Node, allocator: Allocator) void {
                switch (self.*) {
                    .key => |key| if (keyFreeFn) |free|
                        free(allocator, key),
                    .variable => |variable| if (varFreeFn) |free|
                        free(allocator, variable),
                    .pattern => |*p| p.deinit(allocator),
                    .apps, .match, .arrow, .comma => |apps| destroySlice(
                        apps,
                        allocator,
                    ),
                }
            }

            pub const hash = util.hashFromHasherUpdate(Node);

            pub fn hasherUpdate(self: Node, hasher: anytype) void {
                hasher.update(&mem.toBytes(@intFromEnum(self)));
                switch (self) {
                    inline .apps, .match, .arrow, .comma => |apps, tag| {
                        for (apps) |app|
                            app.hasherUpdate(hasher);
                        switch (tag) {
                            .arrow => hasher.update("->"),
                            .match => hasher.update(":"),
                            .comma => hasher.update(","),
                            else => {},
                        }
                    },
                    .variable => |v| hasher.update(
                        &mem.toBytes(VarCtx.hash(undefined, v)),
                    ),
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
                    .variable => |v| VarCtx.eql(
                        undefined,
                        v,
                        other.variable,
                        undefined,
                    ),
                    inline .apps, .arrow, .match, .comma => |apps, tag| blk: {
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
                // TODO: move most of this to writeIndent and just call
                // writeIndent between writing parens. This function should
                // always write parens.
                if (optional_indent) |indent| for (0..indent) |_|
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
                    inline .apps, .arrow, .match, .comma => |apps, tag| {
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
                            .comma => try writer.writeAll(","),
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
            end: *Self, // Null if no prefix
        };
        /// The longest prefix matching a pattern, where vars match all possible
        /// expressions.
        pub const PrefixResult = struct {
            len: usize,
            end: *Self,
        };
        pub const VarNext = struct {
            variable: Var,
            pattern: Self,

            pub fn copy(self: VarNext, allocator: Allocator) !VarNext {
                return VarNext{
                    .variable = self.variable,
                    .pattern = try self.pattern.copy(allocator),
                };
            }
            pub fn clone(self: VarNext, allocator: Allocator) !*VarNext {
                var self_copy = try allocator.create(VarNext);
                self_copy.* = try self.copy(allocator);
                return self_copy;
            }
            pub fn deinit(self: *VarNext, allocator: Allocator) void {
                self.pattern.deinit(allocator);
            }
            pub fn destroy(self: *VarNext, allocator: Allocator) void {
                self.destroy(allocator);
                allocator.destroy(self);
            }
        };

        pub fn ofKey(
            allocator: Allocator,
            optional_key: ?Key,
        ) Allocator.Error!Self {
            return Self{
                .val = if (optional_key) |key|
                    try Node.createKey(allocator, key)
                else
                    null,
            };
        }

        /// Deep copy a pattern by value.
        pub fn copy(self: Self, allocator: Allocator) Allocator.Error!Self {
            var result = Self{};
            var map_iter = self.map.iterator();
            while (map_iter.next()) |entry|
                try result.map.putNoClobber(
                    allocator,
                    // TODO: check if this is right and doesn't need copying too
                    entry.key_ptr.*,
                    try entry.value_ptr.*.clone(allocator),
                );
            if (self.val) |val|
                result.val.? = try val.clone(allocator);

            return result;
        }

        /// Deep copy a pattern pointer, returning a pointer to new memory.
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
            for (self.map.values()) |pattern_ptr|
                pattern_ptr.deinit(allocator);

            if (self.val) |val|
                // Value nodes are also allocated recursively
                val.destroy(allocator);
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
            if (self.val) |val|
                hasher.update(&mem.toBytes(val.hash()));
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
            return if (self.val) |self_val| if (other.val) |other_val|
                self_val.*.eql(other_val.*)
            else
                false else other.val == null;
        }

        /// Like getPrefix but matches only a single node exactly (the
        /// select part of the match is skipped).
        // pub fn getNext(pattern: *Self, term: Node) ?*Self {
        //     return switch (term) {
        //         .key => |key| pattern.map.getPtr(key),

        //         // vars with different names are "equal"
        //         .variable => if (pattern.option_var_next) |var_next|
        //             &var_next.pattern
        //         else
        //             null,

        //         .apps => |apps| blk: {
        //             // Check that the entire sub_apps matched sub_apps
        //             // If there isn't a node for another pattern, this match
        //             // fails. Match sub_apps, move to its value, which is also
        //             // always a pattern even though it is wrapped in a Node
        //             if (pattern.sub_apps) |sub_apps|
        //                 if (sub_apps.matchUnique(apps)) |next|
        //                     break :blk &next.pattern;

        //             break :blk null;
        //         },
        //         .match => |match| {
        //             _ = match;
        //             // Do a submatch here
        //             @panic("unimplemented");
        //             // Equal references will always have equal values here
        //             // if (pat_match.pat_ptr != match.pat_ptr)
        //             //     break :blk null;
        //             // if (pat_match.query.eql(match.query))

        //         },
        //         .arrow => |_| @panic("unimplemented"),
        //         .comma => |_| @panic("unimplemented, loop over list and match each app separately"),
        //         .pattern => |pattern_term| blk: {
        //             _ = pattern_term;
        //             break :blk if (pattern.sub_pat) |sub_pat| {
        //                 _ = sub_pat;
        //                 // TODO: submatch
        //                 @panic("unimplemented");
        //             } else null;
        //         },
        //     };
        // }

        pub fn create(allocator: Allocator) !*Self {
            const result = try allocator.create(Self);
            result.* = Self{};
            return result;
        }

        pub const VarResult = struct {
            name: Var,
            next: Self,
        };

        /// Primarily used for matches to generate variable combinations, this
        /// function returns a list of all possible paths from the root node to
        /// the leaves.
        // TODO: implement correctly
        pub fn flattenPattern(
            pattern: *Self,
            allocator: Allocator,
            var_map: *VarMap,
            node: Node,
        ) Allocator.Error![]PrefixResult {
            var prefixes = std.ArrayListUnmanaged(PrefixResult){};
            var current = pattern;
            // Follow the longest branch that exists
            const prefix_len = switch (node) {
                .apps,
                .match,
                .arrow,
                => |apps| for (apps, 0..) |app, i| switch (app) {
                    // TODO: possible bug, not updating current node
                    .variable => |variable| {
                        const result = try var_map.getOrPut(allocator, variable);
                        // If a var was already bound, just check its value is
                        // equal to this one
                        if (result.found_existing and result.value_ptr.*.eql(app)) {
                            // If a var was bound, insert the actual value
                            // instead of a var in the match result.
                            // current.option_var_next = variable;
                            // current.val = result.value_ptr;
                            continue;
                        }
                        // Otherwise add all entries in this pattern
                        // TODO
                        // for (current.map.values()) |val|
                    },
                    // TODO: A match expression represents a subquery and subpattern
                    // that should be matched. For each result of this submatch, the
                    // main match continues.
                    // An arrow expression, when matching, represents a into that
                    // has a value. The values must be equal to match.
                    else => {
                        // Exact matches should preclude any var matches
                        current = panic("TODO: match", .{}) orelse blk: {
                            // If nothing matched, default to current's var, if any
                            if (current.option_var_next) |var_next| {
                                const result = try var_map.getOrPut(
                                    allocator,
                                    var_next.variable,
                                );
                                // If a previous var was bound, check that the
                                // current key matches it
                                if (result.found_existing) {
                                    if (!result.value_ptr.*.eql(app))
                                        continue;
                                } else result.value_ptr.* = app;

                                break :blk &var_next.pattern;
                            }
                            break i;
                        };
                        print("Current updated\n", .{});
                    },
                } else apps.len,
                else => @panic("unimplemented"),
            };
            const prefix = PrefixResult{
                .end = current,
                .len = prefix_len,
                // .var_map = var_map,
            };
            try prefixes.append(allocator, prefix);
            print("Prefix len: {}\n", .{prefix_len});

            return try prefixes.toOwnedSlice(allocator);
        }
        const MatchResult = struct {
            matched_pattern: Self,
            var_map: VarMap,
        };

        /// Follows `pattern` for each of its apps matching by value, or all apps
        /// for var patterns.
        /// The result is an array of all matches' value nodes.
        ///
        /// Caller should free the varmap and array with `allocator.free`, but
        /// not the references (they belong to the pattern).
        pub fn matchRef(
            pattern: *Self,
            allocator: Allocator,
            node: Node,
        ) ![]*Node {
            print("matchref\n", .{});
            var var_map = VarMap{};
            var prefixes = try pattern.flattenPattern(allocator, &var_map, node);
            defer allocator.free(prefixes);
            // Filter list for complete matches
            var matches = std.ArrayListUnmanaged(*Node){};
            print("Prefixes : {}\n", .{prefixes.len});
            for (prefixes) |prefix| {
                print("\tEnd pointer value: ", .{});
                if (prefix.end.val) |val| val.write(err_stream) catch
                    unreachable else print("null", .{});
                print("\n", .{});
                // Unwrap the val as pattern, because it is always
                // inserted as such
                if (prefix.end.val) |val|
                    switch (node) {
                        .apps => |apps| if (prefix.len == apps.len)
                            try matches.append(allocator, val),
                        else => try matches.append(allocator, val),
                    };
            }

            return try matches.toOwnedSlice(allocator);
        }

        /// Same as `matchRef` but returns a copy of the value.
        // pub fn match(
        //     pattern: *Self,
        //     allocator: Allocator,
        //     into: ArrayListUnmanaged(Node),
        // ) !?Node {
        //     return if (pattern.matchRef(into)) |m|
        //         m.copy(allocator)
        //     else
        //         null;
        // }

        /// Given a pattern and a query to match against it, this function
        /// continously matches until no matches are found, or a match repeats.
        /// Match result cases:
        /// - a pattern of lower ordinal: continue
        /// - the same pattern: continue unless patterns are equivalent expressions
        /// - a pattern of higher ordinal: break
        pub fn evaluate(
            pattern: *const Self,
            // var_map: *VarMap,
            allocator: Allocator,
            query: Node,
        ) Allocator.Error!ArrayListUnmanaged(*Node) {
            const result = std.ArrayListUnmanaged(*Node){};
            _ = result;
            const matches = try pattern.match(allocator, query);
            defer matches.free();
            // var scope_len  = pattern.map.;

            var i = 0;
            while (i < matches.len) : (i += 1) {
                if (matches[i].equal()) {}
            }

            //     try results.appendSlice(
            //         allocator,
            //         try evaluate(pattern, allocator, matches[i].apps),
            //     );
            // }
            return matches.toOwnedSlice(allocator);
        }

        /// Add a node to the pattern by following `keys`, wrapping them into an
        /// App of Nodes.
        /// Allocations:
        /// - The path followed by apps is allocated and copied recursively
        /// - The node, if given, is allocated and copied recursively
        /// Freeing should be done with `destroy` or `deinit`, depending
        /// on how `self` was allocated
        pub fn insertKeys(
            self: *Self,
            allocator: Allocator,
            keys: []const Key,
            optional_val: ?Node,
        ) Allocator.Error!*Self {
            var apps = ArrayListUnmanaged(Node){};
            defer apps.deinit(allocator);
            for (keys) |key|
                try apps.append(allocator, Node.ofLit(key));

            return self.insertApps(allocator, apps.items, optional_val);
        }

        pub fn insert(
            self: *Self,
            allocator: Allocator,
            node: Node,
        ) Allocator.Error!*Self {
            return switch (node) {
                .arrow => |arrow| self.insertApps(
                    allocator,
                    arrow[0 .. arrow.len - 1],
                    arrow[arrow.len - 1],
                ),
                .match => @panic("unimplemented"),
                .comma => @panic("unimplemented, insert each element in list"),
                .apps => |apps| self.insertApps(allocator, apps, null),
                else => @panic("Cannot insert non-slice Ast"),
            };
        }

        /// Add a node to the pattern by following `key`.
        /// Allocations:
        /// - The path followed by apps is allocated and copied recursively
        /// - The node, if given, is allocated and copied recursively
        /// Returns a pointer to the pattern directly containing `optional_val`.
        // TODO: decide if this should just take one Node arg
        pub fn insertApps(
            self: *Self,
            allocator: Allocator,
            key: []const Node,
            optional_val: ?Node,
        ) Allocator.Error!*Self {
            var result = try self.getOrPut(allocator, key);
            // TODO: overwrite existing variable names with any new ones
            // Clear existing value node
            if (result.pattern_ptr.val) |prev_val| {
                prev_val.destroy(allocator);
                print("Deleting old val: {*}\n", .{result.pattern_ptr.val});
                result.pattern_ptr.val = null;
            }
            // Add new value node
            if (optional_val) |val| {
                // TODO: check found existing
                result.pattern_ptr.val = try val.clone(allocator);
            }
            return result.pattern_ptr;
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
        pub fn getPrefix(
            pattern: *Self,
            apps: []const Node,
        ) ExactPrefixResult {
            var current = pattern;
            // Follow the longest branch that exists
            const prefix_len = for (apps, 0..) |app, i| {
                current = current.map.get(app) orelse
                    break i;
            } else apps.len;

            return .{ .len = prefix_len, .end = current };
        }

        /// Follows `pattern` for each app matching structure as well as value.
        /// Does not require allocation because variable branches are not
        /// explored, but rather followed.
        pub fn matchUnique(
            pattern: *Self,
            apps: []const Node,
        ) ?*Node {
            const prefix = &pattern.getPrefix(apps);
            return if (prefix.len == apps.len)
                prefix.end.val
            else
                null;
        }

        /// As a pattern is matched, a hashmap for vars is populated with
        /// each var's bound variable. These can the be used by the caller for
        /// rewriting.
        /// All nodes are copied, not moved, into the pattern.
        pub fn getOrPut(
            pattern: *Self,
            allocator: Allocator,
            keys: []const Node,
        ) Allocator.Error!GetOrPutResult {
            var prefix = pattern.getPrefix(keys);
            var current = prefix.end;
            // Create the rest of the branches
            for (keys[prefix.len..]) |app| {
                const next = try Self.create(allocator);
                // Existing entries are already in the prefix
                try current.map.putNoClobber(allocator, app, next);
                current = next;
            }
            return GetOrPutResult{
                .pattern_ptr = current,
                .found_existing = prefix.len == keys.len,
                // TODO: use first match index at for top level
                .index = 0,
            };
        }

        /// Matching a prefix where vars match anything in the pattern, and vars
        /// in the pattern match anything in the expression. Includes partial
        /// prefixes (ones that don't match all apps).
        /// - Any Node matches a var pattern including a var
        /// - A var Node doesn't match a non-var pattern (var matching is one
        ///    way)
        /// - A literal Node that matches a literal-var pattern matches the
        ///    literal part, not the var
        /// Returns a new pattern that only contains branches that matched `apps`.
        // TODO: fix if function is even needed
        pub fn prunePattern(
            pattern: *Self,
            var_map: *VarMap,
            allocator: Allocator,
            apps: ArrayListUnmanaged(Node),
        ) Allocator.Error!MatchResult {
            var matched = Self{};
            var current_matched = &matched;
            _ = current_matched;
            var current = pattern;
            // Follow the longest branch that exists
            const prefix_len = for (apps, 0..) |app, i| { // Exact matches should preclude any var matches
                current = current.matchUnique(app) orelse blk: {
                    // If nothing matched, default to current's var, if any
                    if (current.option_var_next) |v| {
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
            };
            _ = prefix_len;
            return MatchResult{ .matched_pattern = matched, .var_map = var_map };
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
            try writer.writeAll("| { ");
            try writeMap(self.map, writer, null);
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
            const optional_indent_inc = if (optional_indent) |indent|
                indent + indent_increment
            else
                null;
            try writer.writeByte('{');
            try writeMap(self.map, writer, optional_indent_inc);
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
                try entry.value_ptr.*.writeIndent(
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

    var val = Node{ .key = "123" };
    var val2 = Node{ .key = "123" };
    // Reverse order because patterns are values, not references
    try p2.map.put(allocator, "Bb", Pat{ .val = &val });
    try p1.map.put(allocator, "Aa", p2);

    var p_insert = Pat{};
    _ = try p_insert.insertApps(allocator, &.{
        Node{ .key = "Aa" },
        Node{ .key = "Bb" },
    }, val2);
    try p1.write(err_stream);
    try err_stream.writeByte('\n');
    try p_insert.write(err_stream);
    try err_stream.writeByte('\n');
    try testing.expect(p1.eql(p_insert));
}

test "should behave like a set when given void" {
    const Pat = AutoPattern(usize, void);
    const Node = Pat.Node;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    const nodes1 = &.{ Node{ .key = 123 }, Node{ .key = 456 } };
    var pattern = Pat{};
    _ = try pattern.insertApps(al, nodes1, null);

    // TODO: add to a test for insert
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
    // Even though there is a match, the val is null because we didn't insert
    // a value
    try testing.expectEqual(
        @as(?*Node, null),
        prefix.end.val,
    );
    try testing.expectEqual(@as(usize, 2), prefix.len);

    // try testing.expectEqual(@as(?void, null), pattern.matchUnique(nodes1[0..1]));

    // Empty pattern
    // try testing.expectEqual(@as(?void, {}), pattern.match(.{
    //     .val = {},
    //     .kind = .{ .map = Pat.KeyMap{} },
    // }));
}

test "insert single lit" {}

test "insert multiple lits" {
    // Multiple keys
    const Pat = AutoPattern(usize, void);
    const Node = Pat.Node;
    var pattern = Pat{};
    defer pattern.deinit(testing.allocator);

    _ = try pattern.insertApps(
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
    var pattern = try Pat.ofVal(al, 123);
    const prefix = pattern.getPrefix(&.{});
    _ = prefix;
    // Test nested
    // const Pat2 = Pat{};
    // Pat2.pat_map.put( &pat, 456 };
    // _ = Pat2;
}

test "Memory: simple" {
    const Pat = AutoPattern(usize, void);
    var pattern = try Pat.ofVal(testing.allocator, 123);
    defer pattern.deinit(testing.allocator);
}

test "Memory: nesting" {
    const Pat = AutoStringPattern(void);
    const Node = Pat.Node;
    var nested_pattern = try Pat.create(testing.allocator);
    defer nested_pattern.destroy(testing.allocator);
    nested_pattern.getOrPut(testing.allocator, Pat{}, "subpat's val");

    _ = try nested_pattern.insertKeys(
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
    var val_pattern = try Pat.ofVal(testing.allocator, "Val");

    // No need to free this, because key pointers are destroyed
    var nested_pattern = try Pat.ofVal(testing.allocator, "Asdf");

    try pattern.map.put(testing.allocator, Node{ .pattern = &nested_pattern }, val_pattern);

    _ = try val_pattern.insertKeys(
        testing.allocator,
        &.{ "cherry", "blossom", "tree" },
        null,
    );
}

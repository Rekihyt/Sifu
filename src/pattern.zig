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
            Node,
            Self,
            util.IntoArrayContext(Node),
            true,
        );
        pub const VarMap = std.ArrayHashMapUnmanaged(
            Var,
            Node,
            VarCtx,
            true,
        );

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
        pub const Node = union(enum) {
            /// An upper case term.
            key: Key,
            /// A lower case term.
            variable: Var,
            /// Spaces separated juxtaposition, or commas/parens for nested apps.
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
            /// Sort of postfix encoded: second to last arg is the op, last arg
            /// is rhs
            infix: []const Node,
            // multi_match: []const Node,
            // multi_arrow: []const Node,
            // The pointer here saves space depending on the size of `Key`
            /// An expression in braces.
            pattern: *Self,

            /// Performs a deep copy, resulting in a Node the same size as the
            /// original.
            /// The copy should be freed with `deleteChildren`.
            pub fn copy(self: Node, allocator: Allocator) Allocator.Error!Node {
                return switch (self) {
                    .key, .variable => self, // TODO: comptime copy if pointer
                    .pattern => |p| try Node.ofPattern(
                        allocator,
                        try p.copy(allocator),
                    ),
                    .match => |_| @panic("unimplemented"),
                    .arrow => |_| @panic("unimplemented"),
                    .infix => |_| @panic("unimplemented"),
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

            /// Deletes all nodes, then deinits `apps`.
            pub fn deleteApps(
                apps: []const Node,
                allocator: Allocator,
            ) void {
                for (apps) |*app|
                    @constCast(app).deleteChildren(allocator);
                allocator.free(apps);
            }

            pub fn deleteChildren(self: *Node, allocator: Allocator) void {
                switch (self.*) {
                    .key => |key| if (keyFreeFn) |free|
                        free(allocator, key),
                    .variable => |variable| if (varFreeFn) |free|
                        free(allocator, variable),
                    .pattern => |p| p.delete(allocator),
                    .apps, .match, .arrow, .infix => |apps| deleteApps(
                        apps,
                        allocator,
                    ),
                }
            }

            pub const hash = util.hashFromHasherUpdate(Node);

            pub fn hasherUpdate(self: Node, hasher: anytype) void {
                hasher.update(&mem.toBytes(@intFromEnum(self)));
                switch (self) {
                    .apps => |apps| for (apps) |app|
                        app.hasherUpdate(hasher),
                    .variable => |v| hasher.update(
                        &mem.toBytes(VarCtx.hash(undefined, v)),
                    ),
                    .key => |k| hasher.update(
                        &mem.toBytes(KeyCtx.hash(undefined, k)),
                    ),
                    .match => |_| @panic("unimplemented"),
                    .arrow => |_| @panic("unimplemented"),
                    .infix => |_| @panic("unimplemented"),
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
                    .apps => |apps| apps.len == other.apps.len and
                        for (apps, other.apps) |app, other_app|
                    {
                        if (!app.eql(other_app))
                            break false;
                    } else true,
                    .match => |_| @panic("unimplemented"),
                    .arrow => |_| @panic("unimplemented"),
                    .infix => |_| @panic("unimplemented"),
                    .pattern => |p| p.eql(other.pattern.*),
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
                const pattern_ptr = try allocator.create(Self);
                pattern_ptr.* = pattern;
                node.* = Node{ .pattern = pattern_ptr };
                return node;
            }

            pub fn ofPattern(
                allocator: Allocator,
                pattern: Self,
            ) Allocator.Error!Node {
                const pattern_ptr = try allocator.create(Self);
                pattern_ptr.* = pattern;
                return Node{ .pattern = pattern_ptr };
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

            fn writeSExp(
                self: Node,
                writer: anytype,
                optional_indent: ?usize,
            ) !void {
                if (optional_indent) |indent| for (0..indent) |_|
                    try writer.writeByte(' ');
                switch (self) {
                    .key => |key| _ = try util.genericWrite(key, writer),
                    .variable => |variable| _ = try util.genericWrite(
                        variable,
                        writer,
                    ),
                    .apps => {
                        try writer.writeByte('(');
                        try self.writeIndent(writer, optional_indent);
                        try writer.writeByte(')');
                    },
                    .match => |match| {
                        try writer.writeAll(": ");
                        // These parens are for debugging
                        try last(match).writeSExp(writer, optional_indent);
                        try Node.ofApps(match[0 .. match.len - 1])
                            .writeIndent(writer, optional_indent);
                    },
                    .arrow => |arrow| {
                        try writer.writeAll("-> ");
                        // These parens are for debugging
                        try last(arrow).writeSExp(writer, optional_indent);
                        try Node.ofApps(arrow[0 .. arrow.len - 1])
                            .writeIndent(writer, optional_indent);
                    },
                    .infix => |infix| {
                        // These parens are for debugging
                        try Node.ofApps(infix[0 .. infix.len - 2])
                            .writeIndent(writer, optional_indent);
                        try infix[infix.len - 2]
                            .writeIndent(writer, optional_indent);
                        try last(infix)
                            .writeSExp(writer, optional_indent);
                    },
                    .pattern => |pattern| try pattern.writeIndent(
                        writer,
                        optional_indent,
                    ),
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
                    .apps => |apps| for (apps) |app| {
                        try app.writeSExp(writer, optional_indent);
                        try writer.writeByte(' ');
                    },
                    else => {
                        try self.writeSExp(writer, optional_indent);
                        try writer.writeByte(' ');
                    },
                }
            }
        };

        /// The results of matching a pattern exactly (vars are matched literally
        /// instead of by building up a tree of their possible values)
        pub const ExactPrefixResult = struct {
            len: usize,
            end: Self,
        };

        /// The longest prefix matching a pattern, where vars match all possible
        /// expressions.
        pub const PrefixResult = struct {
            len: usize,
            end: Self,
        };

        /// Maps asts to the next pattern, if there is one. These form the
        /// branches of the trie.
        map: NodeMap = NodeMap{},

        /// A null val represents an undefined pattern, for example in `Foo
        /// Bar -> 123`, the val at `Foo` would be null.
        val: ?*Node = null, // TODO: check pointer still necessary

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
                    // TODO: test if this is right and doesn't need copying too
                    entry.key_ptr.*,
                    try entry.value_ptr.copy(allocator),
                );

            if (self.val) |val| {
                result.val = try allocator.create(Node);
                result.val.?.* = try val.copy(allocator);
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
            defer self.map.deinit(allocator);
            for (self.map.values()) |*pattern|
                pattern.deleteChildren(allocator);

            if (self.val) |val|
                // Value nodes are allocated recursively
                val.delete(allocator);
        }

        pub fn hash(self: Self) u32 {
            var hasher = Wyhash.init(0);
            self.hasherUpdate(&hasher);
            return @truncate(hasher.final());
        }

        pub fn hasherUpdate(self: Self, hasher: anytype) void {
            _ = hasher;
            _ = self;
            // for (self.map.keys()) |key|
            //     hasher.update(&mem.toBytes(KeyCtx.hash(undefined, key)));
            // for (self.map.values()) |p|
            //     p.hasherUpdate(hasher);

            // if (self.pat_map) |pat_map| {
            //     for (pat_map.keys()) |p|
            //         p.hasherUpdate(hasher);
            //     for (pat_map.values()) |p|
            //         p.hasherUpdate(hasher);
            // }

            // if (self.option_var) |v|
            //     hasher.update(&mem.toBytes(VarCtx.hash(undefined, v)));
            // if (self.var_next) |var_next|
            //     var_next.*.hasherUpdate(hasher);

            // if (self.val) |val|
            //     hasher.update(&mem.toBytes(val.hash()));

            // if (self.sub_apps) |sub_apps|
            //     sub_apps.hasherUpdate(hasher);

            // if (self.match) |_| {
            //     @panic("unimplemented");
            // }
            // if (self.arrow) |_| {
            //     @panic("unimplemented");
            // }
        }

        fn keyEql(k1: Key, k2: Key) bool {
            return KeyCtx.eql(undefined, k1, k2, undefined);
        }

        /// Patterns are equal if they have the same literals, sub-arrays and
        /// sub-patterns and if their debruijn variables are equal. The patterns
        /// are assumed to be in debruijn form already.
        pub fn eql(self: Self, other: Self) bool {
            const val_eql = if (self.val) |self_val|
                if (other.val) |other_val|
                    self_val.*.eql(other_val.*)
                else
                    false
            else
                other.val == null;
            if (!val_eql) return false;
            _ = util.sliceEql(self.map.keys(), other.map.keys(), Node.eql) or
                return false;

            _ = util.sliceEql(
                self.map.values(),
                other.map.values(),
                Self.eql,
            ) or return false;

            return true;
        }

        pub fn create(allocator: Allocator) !*Self {
            const result = try allocator.create(Self);
            result.* = Self{};
            return result;
        }

        pub fn get(self: Self, node: Node) ?Self {
            return self.map.get(node);
        }

        pub const VarResult = struct {
            name: Var,
            next: Self,
        };
        pub fn getVar(self: Self) ?VarResult {
            // TODO: check the var hash, which is always the same, but get the
            // actual var's value which may not be (names are preserved despite
            // redundant semantics)
            return if (self.map.get(Node.ofVar(""))) |v| .{
                .name = "unimplemented",
                .next = v,
            } else null;
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
        pub fn matchUniquePrefix(
            pattern: *Self,
            apps: []const Node,
        ) ExactPrefixResult {
            var current = pattern;
            // Follow the longest branch that exists
            const prefix_len = for (apps, 0..) |app, i| {
                current = current.get(app) orelse
                    break i;
            } else apps.len;

            return .{ .len = prefix_len, .end = current };
        }

        /// Follows `pattern` for each app matching structure as well as value.
        /// Does not require allocation because variable branches are not
        /// explored, but rather followed.
        pub fn matchUniqueApps(
            pattern: *Self,
            apps: []const Node,
        ) ?*Node {
            const prefix = pattern.matchUniquePrefix(apps);
            return if (prefix.len == apps.len)
                prefix.end.val
            else
                null;
        }

        /// Primarily used for matches to generate variable combinations, this
        /// function returns a list of all possible paths from the root node to
        /// the leaves.
        // TODO: implement correctly
        pub fn flattenPattern(
            pattern: Self,
            allocator: Allocator,
            var_map: *VarMap,
            node: Node,
        ) Allocator.Error![]PrefixResult {
            var prefixes = std.ArrayListUnmanaged(PrefixResult){};
            var current = pattern;
            // Follow the longest branch that exists
            const prefix_len = switch (node) {
                .apps => |apps| for (apps, 0..) |app, i| switch (app) {
                    // TODO: possible bug, not updating current node
                    .variable => |variable| {
                        const result = try var_map.getOrPut(allocator, variable);
                        // If a var was already bound, just check its value is
                        // equal to this one
                        if (result.found_existing and result.value_ptr.*.eql(app)) {
                            // If a var was bound, insert the actual value
                            // instead of a var in the match result.
                            // current.option_var = variable;
                            // current.val = result.value_ptr;
                            // current = try util.getOrInit(
                            //     .var_next,
                            //     current,
                            //     allocator,
                            // );
                            continue;
                        }
                        // Otherwise add all entries in this pattern
                        // for (current.map.values()) |val|
                    },
                    // TODO: A match expression represents a subquery and subpattern
                    // that should be matched. For each result of this submatch, the
                    // main match continues.
                    // An arrow expression, when matching, represents a into that
                    // has a value. The values must be equal to match.
                    else => {
                        // Exact matches should preclude any var matches
                        current = current.get(app) orelse blk: {
                            // If nothing matched, default to current's var, if any
                            if (current.getVar()) |var_result| {
                                const result = try var_map.getOrPut(
                                    allocator,
                                    var_result.name,
                                );
                                // If a previous var was bound, check that the
                                // current key matches it
                                if (result.found_existing) {
                                    if (!result.value_ptr.*.eql(app))
                                        continue;
                                } else result.value_ptr.* = app;

                                break :blk var_result.next;
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
        //     pattern: *const Self,
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
        /// For multiple matches, each match proceeds independently. First,
        /// each match has its vars rewritten (if any aren't rewritten, the
        /// expression is invalid).
        /// Match result cases:
        /// - a pattern of lower ordinal: continue
        /// - the same pattern: continue unless patterns are equivalent expressions
        /// - a pattern of higher ordinal: break
        pub fn evaluate(
            pattern: *const Self,
            // var_map: *VarMap,
            allocator: Allocator,
            query: ArrayListUnmanaged(Node),
        ) Allocator.Error![]*Node {
            const results = std.ArrayListUnmanaged(*Node){};
            const matches = try pattern.match(allocator, query);
            defer matches.free();

            for (matches) |m| {
                try results.appendSlice(
                    allocator,
                    try evaluate(pattern, allocator, m.apps),
                );
            }
            return matches.toOwnedSlice(allocator);
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
            optional_val: ?Node,
        ) Allocator.Error!*Self {
            var apps = ArrayListUnmanaged(Node){};
            defer apps.deinit(allocator);
            for (keys) |key|
                try apps.append(allocator, Node.ofLit(key));

            return self.insertApps(allocator, apps.items, optional_val);
        }

        pub fn insertApps(
            self: *Self,
            allocator: Allocator,
            apps: []const Node,
            optional_val: ?Node,
        ) Allocator.Error!*Self {
            return self.insert(
                allocator,
                Node.ofApps(@constCast(apps)),
                optional_val,
            );
        }

        pub fn insertNode(
            self: *Self,
            allocator: Allocator,
            node: Node,
        ) Allocator.Error!*Self {
            return switch (node) {
                .arrow => |arrow| {
                    _ = arrow;
                    @panic("unimplemented");
                },
                // self.insert(
                //     allocator,
                //     arrow.from,
                //     arrow.into,
                // ),
                else => self.insert(allocator, node, null),
            };
        }
        /// Add a node to the pattern by following `apps`.
        /// Allocations:
        /// - The path followed by apps is allocated and copied recursively
        /// - The node, if given, is allocated and copied recursively
        /// Returns a pointer to the pattern directly containing `optional_val`.
        // TODO: decide if this should just take one Node arg
        pub fn insert(
            self: *Self,
            allocator: Allocator,
            key: Node,
            optional_val: ?Node,
        ) Allocator.Error!*Self {
            var result = try self.getOrPut(allocator, key);
            // TODO: overwrite existing variable names with any new ones
            // Clear existing value node
            if (result.end.val) |prev_val| {
                prev_val.delete(allocator);
                print("Deleting old val: {*}\n", .{result.end.val});
                result.end.val = null;
            }

            // Add new value node
            if (optional_val) |val| {
                const new_val = try allocator.create(Node);
                // TODO: check found existing
                new_val.* = try val.copy(allocator);
                result.end.val = new_val;
            }
            return result.end;
        }

        // / Because of the recursive type, we need to use a *Node
        // / here instead of a *Pattern, so any pattern gets wrapped into
        // / a `Node.pattern`.

        /// Similar to ArrayHashMap's type, but the index is specific to the
        /// last hashmap.
        pub const GetOrPutResult = struct {
            end: *Self,
            found_existing: bool,
            index: usize,
        };

        /// As a pattern is matched, a hashmap for vars is populated with
        /// each var's bound variable. These can the be used by the caller for
        /// rewriting.
        /// All nodes are copied, not moved, into the pattern.
        pub fn getOrPut(
            pattern: *Self,
            allocator: Allocator,
            query: Node,
        ) Allocator.Error!GetOrPutResult {
            var current = pattern;
            var found_existing = true;
            // TODO: loop
            const put_result = try pattern.map.getOrPut(allocator, query);
            _ = put_result;

            return GetOrPutResult{
                .end = current,
                .found_existing = found_existing,
                .index = 0,
            };
        }
        pub fn getOrPutApps(
            pattern: *Self,
            allocator: Allocator,
            query: []const Node,
        ) Allocator.Error!GetOrPutResult {
            const prefix = pattern.matchUniquePrefix(query);
            var current = prefix.end;
            var found_existing = true;

            // Create the rest of the branches
            for (query[prefix.len..]) |app| {
                const result = try current.getOrPut(allocator, app);
                found_existing = found_existing and result.found_existing;
                current = result.end;
            }
            return GetOrPutResult{
                .end = current,
                .found_existing = found_existing,
                .index = 0, // TODO
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
            pattern: *const Self,
            var_map: *VarMap,
            allocator: Allocator,
            apps: ArrayListUnmanaged(Node),
        ) Allocator.Error!MatchResult {
            var matched = Self{};
            var current_matched = &matched;
            var current = pattern;
            // Follow the longest branch that exists
            const prefix_len = for (apps, 0..) |app, i| switch (app) {
                // TODO: possible bug, not updating current node
                .variable => |variable| {
                    const result = try var_map.getOrPut(allocator, variable);
                    // If a var was already bound, just check its value is
                    // equal to this one
                    if (result.found_existing and result.value_ptr.*.eql(app)) {
                        // TODO: app may need to be copied here
                        // If a var was bound, insert the actual value
                        // instead of a var in the match result.
                        current_matched.option_var = app;
                        current_matched.val = current.val;
                        current.val;
                        current_matched = util.getOrInit(
                            .var_next,
                            current_matched,
                            allocator,
                        );
                        continue;
                    }
                    // Otherwise add all entries in this pattern
                    for (current.map.values()) |val| {
                        _ = val;
                    }
                    for (current.pat_map.values()) |sub_pattern| {
                        _ = sub_pattern;
                    }
                    if (current.sub_apps) |sub_apps| {
                        _ = sub_apps;
                    }
                    if (current.var_next) |var_next| {
                        _ = var_next;
                    }
                },
                else => {
                    // Exact matches should preclude any var matches
                    current = current.matchUnique(app) orelse blk: {
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
            _ = prefix_len;

            return MatchResult{ .matched_pattern = matched, .var_map = var_map };
        }

        /// Pretty print a pattern
        // TODO: fix infix and builtin inserting and printing
        // TODO: print sub apps in a pattern the same way they were inserted
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
                    if (self.map.count() > 0) "\n" else ""
                else
                    " ",
            );
            const optional_indent_inc = if (optional_indent) |indent|
                indent + indent_increment
            else
                null;

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
    const prefix = pattern.matchUniquePrefix(nodes1);
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
    //     .kind = .{ .map = Pat.NodeMap{} },
    // }));
}

test "insert single lit" {}

test "insert multiple lits" {
    // Multiple keys
    const Pat = AutoPattern(usize, void);
    const Node = Pat.Node;
    var pattern = Pat{};
    defer pattern.deleteChildren(testing.allocator);

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
    const prefix = pattern.matchUniquePrefix(&.{});
    _ = prefix;
    // Test nested
    // const Pat2 = Pat{};
    // Pat2.pat_map.put( &pat, 456 };
    // _ = Pat2;
}

test "Memory: simple" {
    const Pat = AutoPattern(usize, void);
    var pattern = try Pat.ofVal(testing.allocator, 123);
    defer pattern.deleteChildren(testing.allocator);
}

test "Memory: nesting" {
    const Pat = AutoStringPattern(void);
    const Node = Pat.Node;
    var nested_pattern = try Pat.create(testing.allocator);
    defer nested_pattern.delete(testing.allocator);
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
    defer pattern.deleteChildren(testing.allocator);
}

test "Memory: nested pattern" {
    const Pat = AutoStringPattern(void);
    const Node = Pat.Node;
    _ = Node;
    var pattern = try Pat.create(testing.allocator);
    defer pattern.delete(testing.allocator);
    var val_pattern = try Pat.ofVal(testing.allocator, "Val");

    // No need to free this, because key pointers are deleted
    var nested_pattern = try Pat.ofVal(testing.allocator, "Asdf");

    try (try util.getOrInit(.pat_map, pattern, testing.allocator))
        .put(testing.allocator, nested_pattern, val_pattern);

    _ = try val_pattern.insertKeys(
        testing.allocator,
        &.{ "cherry", "blossom", "tree" },
        null,
    );
}

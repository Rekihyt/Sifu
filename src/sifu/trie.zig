const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;
const math = std.math;
const util = @import("../util.zig");
const assert = std.debug.assert;
const panic = util.panic;
const Order = math.Order;
const Wyhash = std.hash.Wyhash;
const array_hash_map = std.array_hash_map;
const AutoContext = std.array_hash_map.AutoContext;
const StringContext = std.array_hash_map.StringContext;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const DoublyLinkedList = std.DoublyLinkedList;
const meta = std.meta;
const ArenaAllocator = std.heap.ArenaAllocator;
const print = util.print;
const first = util.first;
const last = util.last;
const streams = util.streams;
const verbose_errors = @import("build_options").verbose_errors;
const debug_mode = @import("builtin").mode == .Debug;

pub const Pattern = @import("pattern.zig").Pattern;
pub const Node = Pattern.Node;

pub const HashMap = std.StringHashMapUnmanaged(Trie);
pub const GetOrPutResult = HashMap.GetOrPutResult;

/// This maps to branches, but the type is Branch instead of just *Self to
/// retrieve keys if necessary. The Self pointer references another field in
/// this trie, such as `keys`. Stores any and all values, vars and their indices
/// at each branch in the trie. Tracks the order of entries in the trie and
/// references to next pointers. An index for an entry is saved at every branch
/// in the trie for a given key. Branches may or may not contain values in their
/// ValueMap, for example in `Foo Bar -> 123`, the branch at `Foo` would have an
/// index to the key `Bar` and a leaf trie containing the value `123`.
// const IndexMap = std.AutoArrayHashMapUnmanaged(usize, Branch);

/// A key node and its next term pointer for a trie, where only the
/// length of slice types are stored for keys (instead of pointers).
/// The term/next is a reference to a key/value in the HashMaps,
/// which owns both.
const Entry = struct {
    name: []const u8,
    next: *Trie,
};

/// A single index and its next pointer in the trie. The union disambiguates
/// between values and the next variables/key. Keys are borrowed from the trie's
/// hashmap, but variables are owned (as they aren't stored as keys in the trie)
const Branch = struct {
    index: usize,
    entry: Entry,
};

const Value = struct {
    index: usize,
    pattern: Pattern,
};

const BranchList = ArrayListUnmanaged(Branch);
const ValueList = ArrayListUnmanaged(Value);
const IndexedValues = struct {
    keys: BranchList = .{},
    vars: BranchList = .{},
    values: ValueList = .{},

    pub fn deinit(self: IndexedValues, allocator: Allocator) void {
        for (self.values.items) |*value| {
            value.pattern.deinit(allocator);
        }
    }

    pub fn copy(self: IndexedValues, allocator: Allocator) !IndexedValues {
        _ = allocator; // autofix
        var result = IndexedValues{};
        result = result;
        // TODO Deep copy the new pointers to the new copy
        for (self.values.items) |branch| {
            const index = branch.index;
            _ = index; // autofix
            const entry = branch.pattern;
            _ = entry; // autofix
            // TODO: Insert a borrowed pointer to the new key copy.
            // try result.value.append(
            //     allocator,
            //     Branch{ .index = index, .entry = entry },
            // );
        }
        return result;
    }
};

/// Maps terms to the next trie, if there is one. These form the branches of the
/// trie for a specific level of nesting. Each Key is in the map is unique, but
/// they can be repeated in separate indices. Therefore this stores its own next
/// Self pointer, and the indices for each key.
///
/// Keys must be efficiently iterable, but that is provided by the index map
/// anyways so an array map isn't needed for the trie's hashmap.
///
/// The tries that for types that are shared (variables and nested pattern/tries)
/// are encoded by a layer of pointer indirection in their respective fields
/// here.
pub const Trie = struct {
    pub const Self = @This();

    map: HashMap = .{},
    value: IndexedValues = .{},

    /// The results of matching a trie exactly (vars are matched literally
    /// instead of by building up a pattern of their possible values)
    pub const ExactPrefix = struct {
        len: usize,
        index: ?usize, // Null if no prefix
        leaf: Self,
    };

    /// Asserts that the index exists.
    pub fn getIndex(self: Self, index: usize) Pattern {
        return self.getIndexOrNull(index) orelse
            panic("Index {} doesn't exist\n", .{index});
    }
    /// Returns null if the index doesn't exist in the trie.
    pub fn getIndexOrNull(self: Self, index: usize) ?Pattern {
        var current = self;
        while (current.value.get(index)) |next| {
            current = next.value_ptr.*;
        }
        return current.value.get(index);
    }

    /// Rebuilds the key for a given index using an allocator for the
    /// arrays necessary to support the pattern structure, but pointers to the
    /// underlying keys.
    pub fn rebuildKey(
        self: Self,
        allocator: Allocator,
        index: usize,
    ) !Pattern {
        _ = index; // autofix
        _ = allocator; // autofix
        _ = self; // autofix
        @panic("unimplemented");
    }

    /// Deep copy a trie by value, as well as Keys and Variables.
    /// Use deinit to free.
    // TODO: optimize by allocating top level maps of same size and then
    // use putAssumeCapacity
    pub fn copy(self: Self, allocator: Allocator) Allocator.Error!Self {
        var result = Self{};
        var keys_iter = self.map.iterator();
        while (keys_iter.next()) |entry|
            try result.map.putNoClobber(
                allocator,
                entry.key_ptr.*,
                try entry.value_ptr.*.copy(allocator),
            );

        result.value = try self.value.copy(allocator);
        @panic("todo: copy all fields");
        // return result;
    }

    /// Deep copy a trie pointer, returning a pointer to new memory. Use
    /// destroy to free.
    pub fn clone(self: *Self, allocator: Allocator) !*Self {
        const clone_ptr = try allocator.create(Self);
        clone_ptr.* = try self.copy(allocator);
        return clone_ptr;
    }

    /// Frees all memory recursively, leaving the Trie in an undefined
    /// state. The `self` pointer must have been allocated with `allocator`.
    /// The opposite of `clone`.
    pub fn destroy(self: *Self, allocator: Allocator) void {
        self.deinit(allocator);
        allocator.destroy(self);
    }

    /// The opposite of `copy`.
    /// TODO: check frees properly for owned and borrowed managers
    pub fn deinit(self: *Self, allocator: Allocator) void {
        defer self.map.deinit(allocator);
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit(allocator);
        }
        defer self.value.deinit(allocator);
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
        // No need to hash indices, only vars and values
        var vars_iter = self.values.vars.iterator();
        while (vars_iter.next()) |*entry| {
            hasher.update(entry.value_ptr.*);
        }
        var values_iter = self.values.values.iterator();
        // TODO: recurse
        while (values_iter.next()) |*entry| {
            entry.value_ptr.hasherUpdate(hasher);
        }
    }

    fn branchEql(comptime E: type, b1: E, b2: E) bool {
        return b1.key_ptr.eql(b2.key_ptr.*) and
            b1.value_ptr.eql(b2.value_ptr.*);
    }

    /// Tries are equal if they have the same literals, sub-arrays and
    /// sub-tries and if their debruijn variables are equal. The tries
    /// are assumed to be in debruijn form already.
    pub fn eql(self: Self, other: Self) bool {
        if (self.map.count() != other.map.count() or
            self.value.entries.len !=
            other.value.entries.len or
            self.value.entries.len != other.value.entries.len)
            return false;
        var map_iter = self.map.iterator();
        var other_map_iter = other.map.iterator();
        while (map_iter.next()) |entry| {
            const other_entry = other_map_iter.next() orelse
                return false;
            if (!(mem.eql(u8, entry.key_ptr.*, other_entry.key_ptr.*)) or
                entry.value_ptr != other_entry.value_ptr)
                return false;
        }
        var value_iter = self.value.iterator();
        var other_value_iter = other.value.iterator();
        while (value_iter.next()) |entry| {
            const other_entry = other_value_iter.next() orelse
                return false;
            const value = entry.value_ptr.*;
            const other_value = other_entry.value_ptr.*;
            if (entry.key_ptr.* != other_entry.key_ptr.* or
                !value.eql(other_value))
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
        variable: []const u8,
        index: usize,
        next: *Self,
    };

    /// Follows `trie` for each trie matching structure as well as value.
    /// Does not require allocation because variable branches are not
    /// explored, but rather followed. This is an exact match, so variables
    /// only match variables and a subtrie will be returned. This pointer
    /// is valid unless reassigned in `pat`.
    /// If trie is empty the same `pat` pointer will be returned. If
    /// the entire `pattern` is a prefix, a pointer to the last pat will be
    /// returned instead of null.
    /// `trie` isn't modified.
    pub fn getTerm(
        trie: Self,
        node: Node,
    ) ?Self {
        return switch (node) {
            .key => |key| trie.map.get(key),
            .variable => |variable| trie.value.vars.get(variable),
            .pattern => |sub_pattern| blk: {
                var current = trie.map.get("(") orelse
                    break :blk null;
                for (sub_pattern.root) |sub_node|
                    current = current.getTerm(sub_node) orelse
                        break :blk null;
                break :blk current.map.get(")");
            },
            .arrow, .match, .list => panic("unimplemented", .{}),
            else => panic("unimplemented", .{}),
        };
    }

    /// Return a pointer to the last trie in `pat` after the longest path
    /// following `pattern`
    pub fn getPrefix(
        trie: Self,
        pattern: Pattern,
    ) ExactPrefix {
        var current = trie;
        const index: usize = undefined; // TODO
        // Follow the longest branch that exists
        const prefix_len = for (pattern.root, 0..) |node, i| {
            current = current.getTerm(node) orelse
                break i;
        } else pattern.root.len;

        return .{ .len = prefix_len, .index = index, .leaf = current };
    }

    pub fn get(
        trie: Self,
        pattern: Pattern,
    ) ?Self {
        const prefix = trie.getPrefix(pattern);
        return if (prefix.len == pattern.root.len)
            prefix.leaf
        else
            null;
    }

    pub fn append(
        trie: *Self,
        allocator: Allocator,
        key: Pattern,
        optional_value: ?Pattern,
    ) Allocator.Error!*Self {
        // The length of values will be the next entry index after insertion
        const len = trie.count();
        var branch = trie;
        branch = try branch.ensurePath(allocator, len, key);
        // If there isn't a value, use the key as the value instead
        const value = optional_value orelse
            try key.copy(allocator);
        try branch.value.values.append(
            allocator,
            Value{ .index = len, .pattern = value },
        );
        return branch;
    }

    /// Creates the necessary branches and key entries in the trie for
    /// pattern, and returns a pointer to the branch at the end of the path.
    /// While similar to a hashmap's getOrPut function, ensurePath always
    /// adds a new index, asserting that it did not already exist. There is
    /// no getOrPut equivalent for tries because they are append-only.
    ///
    /// The index must not already be in the trie.
    /// Pattern are copied.
    /// Returns a pointer to the updated trie node. If the given pattern is
    /// empty (0 len), the returned key and index are undefined.
    fn ensurePath(
        trie: *Self,
        allocator: Allocator,
        index: usize,
        pattern: Pattern,
    ) !*Self {
        var current = trie;
        for (pattern.root) |node| {
            current = try current.ensurePathTerm(allocator, index, node);
        }
        return current;
    }

    fn getOrPutKey(
        trie: *Self,
        allocator: Allocator,
        index: usize,
        key: []const u8,
    ) !*Self {
        const entry = try trie.map
            .getOrPutValue(allocator, key, Self{});
        try trie.value.keys.append(allocator, Branch{
            .index = index,
            .entry = .{
                .name = entry.key_ptr.*,
                .next = entry.value_ptr,
            },
        });
        return entry.value_ptr;
    }

    fn getOrPutVar(
        trie: *Self,
        allocator: Allocator,
        index: usize,
        variable: []const u8,
    ) !*Self {
        const entry = try trie.map
            .getOrPutValue(allocator, variable, Self{});
        try trie.value.vars.append(allocator, Branch{
            .index = index,
            .entry = .{
                .name = entry.key_ptr.*,
                .next = entry.value_ptr,
            },
        });
        return entry.value_ptr;
    }

    /// Follows or creates a path as necessary in the trie and
    /// indices. Only adds branches, not values.
    fn ensurePathTerm(
        trie: *Self,
        allocator: Allocator,
        index: usize,
        term: Node,
    ) Allocator.Error!*Self {
        return switch (term) {
            .key => |key| try trie.getOrPutKey(allocator, index, key),
            .variable,
            .var_pattern,
            => |variable| try trie.getOrPutVar(allocator, index, variable),
            .trie => |sub_pat| {
                const entry = try trie.getOrPutKey(allocator, index, "{");
                _ = entry;
                _ = sub_pat;
                @panic("unimplemented\n");
            },
            // Pattern trie's values will always be tries too, which will
            // map nested pattern to the next trie on the current level.
            // The resulting encoding is counter-intuitive when printed
            // because each level of nesting must be a branch to enable
            // trie matching.
            inline else => |pattern| blk: {
                var next = try trie.getOrPutKey(allocator, index, "(");
                // All op types are encoded the same way after their top
                // level hash. These don't need special treatment because
                // their structure is simple, and their operator unique.
                next = try next.ensurePath(allocator, index, pattern);
                next = try next.getOrPutKey(allocator, index, ")");
                break :blk next;
            },
        };
    }

    /// Add a node to the trie by following `keys`, wrapping them into an
    /// Pattern of Nodes. Assumes
    /// Allocations:
    /// - The value, if given, is allocated and copied recursively
    /// Freeing should be done with `destroy` or `deinit`, depending on
    /// how `self` was allocated
    pub fn appendKey(
        self: *Self,
        allocator: Allocator,
        key: []const []const u8,
        value: Pattern,
    ) Allocator.Error!*Self {
        const root = try allocator.alloc(Node, key.len);
        for (root, key) |*node, token|
            node.* = Node.ofKey(token);

        return self.append(allocator, Pattern{ .root = root }, value);
    }

    /// A partial or complete match of a given pattern against a trie.
    const Match = struct {
        /// Keeps track of which vars and var_pattern are bound to what part of an
        /// expression given during matching.
        pub const VarBindings = std.StringHashMapUnmanaged(Node);

        value: ?Value = null,
        index: usize,
        len: usize, // Checks if complete or partial match
        bindings: VarBindings = .{}, // Bound variables

        /// The second half of an evaluation step. Rewrites all variable
        /// captures into the matched expression. Copies any variables in node
        /// if they are keys in bindings with their values. If there are no
        /// matches in bindings, this functions is equivalent to copy. Result
        /// should be freed with deinit.
        pub fn rewrite(
            match_state: Match,
            allocator: Allocator,
            pattern: Pattern,
        ) Allocator.Error!Pattern {
            var result = ArrayListUnmanaged(Node){};
            for (pattern.root) |node| switch (node) {
                .key => |key| try result.append(allocator, Node.ofKey(key)),
                .variable => |variable| {
                    print("Var get: ", .{});
                    if (match_state.bindings.get(variable)) |var_node|
                        var_node.writeSExp(streams.err, null) catch unreachable
                    else
                        print("null", .{});
                    print("\n", .{});
                    try result.append(
                        allocator,
                        try (match_state.bindings.get(variable) orelse
                            node).copy(allocator),
                    );
                },
                .var_pattern => |var_pattern| {
                    print("Var pattern get: ", .{});
                    if (match_state.bindings.get(var_pattern)) |var_node|
                        var_node.writeSExp(streams.err, null) catch unreachable
                    else
                        print("null", .{});
                    print("\n", .{});
                    if (match_state.bindings.get(var_pattern)) |pattern_node| {
                        for (pattern_node.pattern.root) |trie|
                            try result.append(
                                allocator,
                                try trie.copy(allocator),
                            );
                    } else try result.append(allocator, node);
                },
                inline .pattern, .arrow, .match, .list, .infix => |nested, tag| {
                    try result.append(allocator, @unionInit(
                        Node,
                        @tagName(tag),
                        try match_state.rewrite(allocator, nested),
                    ));
                },
                // .trie => |sub_pat| {
                //     _ = sub_pat;
                // },
                else => panic("unimplemented", .{}),
            };
            return Pattern{
                .root = try result.toOwnedSlice(allocator),
                .height = pattern.height,
            };
        }

        /// Node entries are just references, so they aren't freed by this
        /// function.
        pub fn deinit(self: *Match, allocator: Allocator) void {
            defer self.bindings.deinit(allocator);
        }
    };

    // Find the next branch starting from bound.
    fn findNextByIndex(Elem: type, bound: usize, list: anytype) ?Elem {
        // To compare by bound with other branches, it must be put into a Branch
        // first. Its kind can be undefined since it will never be returned.
        var elem: Elem = undefined;
        elem.index = bound;
        const index = std.sort.lowerBound(
            Elem,
            elem,
            list.items,
            {},
            struct {
                fn lessThan(_: void, lhs: Elem, rhs: Elem) bool {
                    return lhs.index < rhs.index;
                }
            }.lessThan,
        );
        // No index found if lowerBound returned the length of branches
        return if (index == list.items.len)
            null
        else
            list.items[index];
    }

    fn findNextValue(self: Self, bound: usize) ?Value {
        return findNextByIndex(Value, bound, self.value.values);
    }

    fn findNextBranch(self: Self, bound: usize) ?Branch {
        // TODO: prioritize order
        return findNextByIndex(Branch, bound, self.value.keys) orelse
            findNextByIndex(Branch, bound, self.value.vars);
    }

    /// The first half of evaluation. The variables in the node match
    /// anything in the trie, and vars in the trie match anything in
    /// the expression. Includes partial prefixes (ones that don't match all
    /// pattern). This function returns any trie branches, even if their
    /// value is null, unlike `match`. The position defines the index where
    /// allowable matches begin. As a trie is matched, a hashmap for vars
    /// is populated with each var's bound variable. These can the be used
    /// by the caller for rewriting.
    /// - Any node matches a var trie including a var (the var node is
    ///   then stored in the var map like any other node)
    /// - A var node doesn't match a non-var trie (var matching is one
    ///   way)
    /// - A literal node that matches a trie of both literals and vars
    /// matches the literal part, not the var
    /// Returns a nullable struct describing a successful match containing:
    /// - the value for that match in the trie
    /// - the minimum index a subsequent match should use, which is one
    /// greater than the previous (except for structural recursion).
    /// - null if no match
    /// Time Complexity: O(mlogn) where m is the key len and n is the size of
    /// the trie.
    /// Returns a trie of the subset of branches that matches `node`. Caller
    /// owns the trie returned, but it is a shallow copy and thus cannot be
    /// freed with destroy/deinit without freeing references in self.
    fn matchTerm(
        self: Self,
        bound: usize,
        node: Node,
    ) Allocator.Error!?Branch {
        print("Branching `", .{});
        node.writeSExp(streams.err, null) catch unreachable;
        print("`, ", .{});
        switch (node) {
            .key => |key| if (self.map.get(key)) |next| {
                print("exactly: {s} ", .{node.key});
                const branch = next.findNextBranch(bound) orelse
                    return null;
                print("with next index at {}\n", .{branch.index});
                return branch;
            },
            .variable, .var_pattern => {
                // // If a previous var was bound, check that the
                // // current key matches it
                // if (var_result.found_existing) {
                //     if (var_result.value_ptr.*.eql(node)) {
                //         print("found equal existing var match\n", .{});
                //     } else {
                //         print("found existing non-equal var matching\n", .{});
                //     }
                // } else {
                //     print("New Var: {s}\n", .{var_result.key_ptr.*});
                //     var_result.value_ptr.* = node;
                // }
            },
            .trie => @panic("unimplemented"), // |trie| {},
            else => @panic("unimplemented"),
        }
        return null;
    }

    /// Finds the lowest bound index that also matches pattern. Returns its
    /// value as well as the length of the prefix of pattern matched (which
    /// is equal to the pattern's length if all nodes matched at least once).
    /// Returns the value of `self` if given trie if pattern is empty (base
    /// case).
    pub fn match(
        self: Self,
        allocator: Allocator,
        bound: usize,
        pattern: Pattern,
    ) Allocator.Error!Match {
        var current = self;
        // Matching branches that can be backtracked to. Indices are tracked
        // because they are always matched in ascending order, but not
        // necessarily sequentially.
        var branches: BranchList = .{};
        _ = allocator;
        var len: usize = 0;
        var index = bound;
        branches = branches; // TODO: backtracking
        if (current.findNextValue(bound)) |value|
            return Match{ .index = value.index, .value = value, .len = len };
        for (pattern.root) |node| {
            const branch = try current.matchTerm(bound, node) orelse
                break;
            len += 1;
            index = branch.index;
            current = branch.entry.next.*;
        }
        print(
            "No match in range [{}, {}], after {} nodes followed\n",
            .{ bound, index, len },
        );
        return Match{ .index = index, .value = null, .len = len };
    }

    /// Follow `pattern` in `self` until no matches. Then returns the furthest
    /// trie node and its corresponding number of matched pattern that
    /// was in the trie. Starts matching at [index, ..), in the
    /// longest path otherwise any index for a shorter path.
    /// Caller owns and should free the result's value and bindings with
    /// Match.deinit.
    /// If nothing matches, then a single node trie with the same value as self
    /// is returned.
    pub fn matchIter() void {}

    /// Performs a single full match and if possible a rewrite.
    /// Caller owns and should free with deinit.
    pub fn evaluateStep(
        self: Self,
        allocator: Allocator,
        bound: usize,
        pattern: Pattern,
    ) Allocator.Error!Pattern {
        while (bound < self.count()) {
            var next = try self.match(allocator, bound, pattern);
            defer next.deinit(allocator);
            print(
                "Matched {} of {} pattern at index {}: ",
                .{ next.len, pattern.root.len, next.index },
            );
            const value = next.value orelse
                break;
            value.pattern.write(streams.err) catch unreachable;
            print("\n", .{});
            return next.rewrite(allocator, value.pattern);
        }
        return pattern.copy(allocator);
    }

    /// Given a trie and a query to match against it, this function
    /// continously matches until no matches are found, or a match repeats.
    /// Match result cases:
    /// - a trie of lower ordinal: continue
    /// - the same trie: continue unless tries are equivalent
    /// - a trie of higher ordinal: break
    // TODO: fix ops as keys not being matched
    // TODO: refactor with evaluateStep
    pub fn evaluate(
        self: *Self,
        allocator: Allocator,
        pattern: Pattern,
    ) Allocator.Error!Pattern {
        var index: usize = 0;
        var result = ArrayListUnmanaged(Node){};
        while (index < pattern.len) {
            print("Matching from index: {}\n", .{index});
            const query = pattern[index..];
            const matched = try self.match(allocator, query);
            if (matched.len == 0) {
                print("No match, skipping index {}.\n", .{index});
                try result.append(
                    allocator,
                    // Evaluate nested pattern that failed to match
                    // TODO: replace recursion with a continue
                    switch (pattern[index]) {
                        inline .pattern, .match, .arrow, .list => |slice, tag|
                        // Recursively eval but preserve node type
                        @unionInit(
                            Node,
                            @tagName(tag),
                            try self.evaluate(allocator, slice),
                        ),
                        else => try pattern[index].copy(allocator),
                    },
                );
                index += 1;
                continue;
            }
            print("vars in map: {}\n", .{matched.bindings.entries.len});
            if (matched.value) |next| {
                // Prevent infinite recursion at this index. Recursion
                // through other indices will be terminated by match index
                // shrinking.
                if (query.len == next.pattern.len)
                    for (query, next.pattern) |trie, next_trie| {
                        // check if the same trie's shape could be matched
                        // TODO: use a trie match function here instead of eql
                        if (!trie.asEmpty().eql(next_trie))
                            break;
                    } else break; // Don't evaluate the same trie
                print("Eval matched {s}: ", .{@tagName(next.*)});
                next.write(streams.err) catch unreachable;
                streams.err.writeByte('\n') catch unreachable;
                const rewritten =
                    try self.rewrite(allocator, matched.bindings, next.pattern);
                defer Node.ofPattern(rewritten).deinit(allocator);
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
        for (result.items) |trie| {
            print("{s} ", .{@tagName(trie)});
            trie.writeSExp(streams.err, 0) catch unreachable;
            streams.err.writeByte(' ') catch unreachable;
        }
        streams.err.writeByte('\n') catch unreachable;
        return result.toOwnedSlice(allocator);
    }

    pub fn count(self: Self) usize {
        return self.value.keys.items.len +
            self.value.vars.items.len +
            self.value.values.items.len;
    }

    /// Caller owns the slice, but not the patterns in it.
    fn setKeys(
        self: Self,
        allocator: Allocator,
        result: []ArrayListUnmanaged([]const u8),
    ) !void {
        for (self.value.keys) |key| {
            try result[key.index].appendSlice(allocator, key.name + ' ');
        }
        for (self.value.keys.items) |entry|
            entry.next.setKeys(result);
        for (self.value.vars.items) |entry|
            entry.next.setKeys(result);
    }

    /// Caller owns the slice, but not the patterns in it.
    fn setValues(self: Self, result: []Pattern) void {
        for (self.value.values) |value| {
            result[value.index] = value.pattern;
        }
        for (self.value.keys.items) |entry|
            entry.next.setValues(result);
        for (self.value.vars.items) |entry|
            entry.next.setValues(result);
    }

    /// Returns a slice of keys, where each key is concatenated into a string.
    pub fn keys(self: Self, allocator: Allocator) ![][]const u8 {
        const result = try allocator.alloc([][]const u8, self.count());
        for (result) |slice_ptr| {
            var key = ArrayListUnmanaged([]const u8){};
            try self.writeValues(allocator, key);
            slice_ptr = key.toOwnedSlice(allocator);
        }
        return result;
    }

    pub fn values(self: Self, allocator: Allocator) ![]Pattern {
        const result = try allocator.alloc(Pattern, self.count());
        self.writeValues(result);
        return result;
    }

    /// Pretty print a trie on multiple lines
    pub fn pretty(self: Self, writer: anytype) !void {
        try self.writeIndent(writer, 0);
    }

    /// Print a trie without newlines
    pub fn write(self: Self, writer: anytype) !void {
        try self.writeIndent(writer, null);
    }

    /// Writes a single entry in the trie canonically. Index must be
    /// valid.
    pub fn writeIndex(self: Self, writer: anytype, index: usize) !void {
        var current = self;
        if (comptime debug_mode)
            try writer.print("{} | ", .{index});

        while (current.findNextBranch(index)) |branch| {
            if (branch.index != index)
                break;
            try writer.writeAll(branch.entry.name);
            try writer.writeByte(' ');
            current = branch.entry.next.*;
        }
        try writer.writeAll("-> ");
        try current.findNextValue(index).?.pattern
            .writeIndent(writer, null);
    }

    /// Print a trie in order based on indices.
    pub fn writeCanonical(self: Self, writer: anytype) !void {
        for (0..self.count()) |index| {
            try self.writeIndex(writer, index);
            try writer.writeByte('\n');
        }
    }

    pub const indent_increment = 2;
    pub fn writeIndent(
        self: Self,
        writer: anytype,
        optional_indent: ?usize,
    ) @TypeOf(writer).Error!void {
        try writer.writeAll("❬");
        for (self.value.values.items) |value| {
            try value.pattern.writeIndent(writer, null);
            try writer.writeAll(", ");
        }
        try writer.writeAll("❭ ");
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
            try util.genericWrite(node, writer);
            try writer.writeAll(" -> ");
            try entry.value_ptr.*.writeIndent(writer, optional_indent);
            try writer.writeAll(if (optional_indent) |_| "" else ", ");
        }
    }
};

const testing = std.testing;

test "Trie: eql" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var trie1 = Trie{};
    var trie2 = Trie{};

    const key = Pattern{ .root = &.{
        .{ .key = "Aa" },
        .{ .key = "Bb" },
    } };
    const ptr1 = try trie1.append(allocator, key, Pattern{
        .root = &.{.{ .key = "Value" }},
    });
    const ptr2 = try trie2.append(allocator, key, Pattern{
        .root = &.{.{ .key = "Value" }},
    });

    try testing.expect(trie1.getIndexOrNull(0) != null);
    try testing.expect(trie2.getIndexOrNull(0) != null);

    // Compare leaves that share the same value
    try testing.expect(ptr1.eql(ptr2.*));

    // Compare tries that have the same key and value
    try testing.expect(trie1.eql(trie2));
    try testing.expect(trie2.eql(trie1));
}

test "Structure: put single lit" {}

test "Structure: put multiple lits" {
    // Multiple keys
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    const val = Pattern{ .root = &.{.{ .key = "Val" }} };
    _ = try trie.append(
        testing.allocator,
        Pattern{ .root = &.{
            Node{ .key = "1" },
            Node{ .key = "2" },
            Node{ .key = "3" },
        } },
        val,
    );
    try testing.expect(trie.map.contains("1"));
    try testing.expect(trie.map.get("1").?.map.contains("2"));
    try testing.expectEqualDeep(trie.getIndex(0), val);
}

test "Memory: simple" {
    var trie = Trie{};
    defer trie.deinit(testing.allocator);

    const ptr1 = try trie.append(
        testing.allocator,
        Pattern{ .root = &.{} },
        Pattern{ .root = &.{.{ .key = "123" }} },
    );
    const ptr2 = try trie.append(
        testing.allocator,
        Pattern{ .root = &.{ .{ .key = "01" }, .{ .key = "12" } } },
        Pattern{ .root = &.{.{ .key = "123" }} },
    );
    const ptr3 = try trie.append(
        testing.allocator,
        Pattern{ .root = &.{ .{ .key = "01" }, .{ .key = "12" } } },
        Pattern{ .root = &.{.{ .key = "234" }} },
    );

    try testing.expect(ptr1 != ptr2);
    try testing.expectEqual(ptr2, ptr3);
}

test "Behavior: vars" {
    var nested_trie = try Trie.create(testing.allocator);
    defer nested_trie.destroy(testing.allocator);

    _ = try nested_trie.appendKey(
        testing.allocator,
        &.{
            "cherry",
            "blossom",
            "tree",
        },
        Pattern{ .root = &.{.{ .key = "Beautiful" }} },
    );
}

test "Behavior: nesting" {
    @panic("unimplemented");
}

test "Behavior: equal variables" {
    @panic("unimplemented");
}

test "Behavior: equal keys, different indices" {
    @panic("unimplemented");
}

test "Behavior: equal keys, different structure" {
    @panic("unimplemented");
}

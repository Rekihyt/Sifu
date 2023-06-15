const std = @import("std");
const meta = std.meta;
const Allocator = std.mem.Allocator;
const AutoArrayHashMapUnmanaged = std.AutoArrayHashMapUnmanaged;
const ArrayHashMapUnmanaged = std.ArrayHashMapUnmanaged;
const ArenaAllocator = std.heap.ArenaAllocator;
const math = std.math;
const Order = math.Order;

///
/// A trie-like type based on the given term type. Each pattern contains zero or
/// more children.
///
/// The term and var type must be hashable. Nodes track context, the recursive
/// structures (apps, match) do not.
///
/// Params
/// `Lit` - the type of literal keys
/// `Var` - the type of variable keys
/// `Val` - the type of values that a successful key match will evaluate to
/// `Context` - arbitrary data, not used for matching
///
pub fn Pattern(
    comptime Lit: type,
    comptime Var: type,
    comptime Val: type,
    comptime Context: type,
) type {
    return struct {
        pub const Self = @This();

        pub const Kind = union(enum) {
            // Hashmaps can be used as keys because they are (probably) created
            // deterministically, as long as they have only had elements
            // inserted and not removed.
            pub const Map = AutoArrayHashMapUnmanaged(*Self, Self);

            pub const Match = struct {
                key: *Self,
                pat: *Self,
            };

            // Literals and variables are leaves

            lit: Lit,

            /// The Var kind matches and stores a locally-unique key. During
            /// rewriting, whenever the key is encountered again, it is
            /// rewritten to this pattern's value.
            @"var": Var,

            // Apps and Matches are the branches of the AST

            apps: Map,

            match: Match,

            pub fn ofMap() Kind {
                return .{
                    .apps = Map{},
                };
            }

            /// Create a singleton kind from one key
            pub fn ofMapWith(allocator: Allocator, key: Self) Kind {
                var m = Map{};
                m.put(allocator, key, null);
                return .{ .apps = m };
            }

            pub fn ofVar(key: Self) Kind {
                return .{ .@"var" = key };
            }

            pub fn ofMatch(sub_key: Self, sub_pat: Self, val: ?Lit) Self {
                _ = val;
                _ = sub_pat;
                _ = sub_key;
                return .{};
            }
        };

        /// The kind primarily determines how this pattern matches, and stores
        /// sub-patterns, if any.
        // kind: Kind,

        /// The value this pattern holds, if any.
        val: ?Val,

        /// `Context` is intended for optional debug/tooling information like
        /// `Span`.
        context: Context,

        /// Inserts the value for this array of keys. The keys must already be
        /// converted to pattern kinds.
        pub fn insert(
            self: *Self,
            keys: []const Self.Kind,
            val: ?Lit,
            allocator: Allocator,
        ) !void {
            var current = self.*;
            var i: usize = 0;
            // Follow the longest branch that exists
            while (i < keys.len) : (i += 1)
                switch (current.kind) {
                    .apps => |map| {
                        if (map.get(keys[i])) |pat_node|
                            current = pat_node
                        else
                            // Key mismatch
                            break;
                    },
                    .match => {},
                    .variable => {},
                };
            // Create new branches while necessary
            while (i < keys.len) : (i += 1) {
                const next = .{
                    .pattern = current,
                    .kind = .{ .variable = .{ .key = keys[i] } },
                };
                current.apps.put(allocator, keys[i], next);
            }
            // Put the value in this last node
            current.val = val;
        }

        pub fn match(self: *Self, key: Self) ?Val {
            _ = key;
            _ = self;
        }

        /// Match the key against the given pattern `other`, and if that doesn't
        /// match, fallback to matching this pattern.
        pub fn matchUnion(self: *Self, key: Self, other: Self) ?Val {
            if (other.match(key)) |result|
                return result;

            // var var_map = AutoArrayHashMapUnmanaged(Self, Lit){};
            var current = self.*;
            var i: usize = 0;
            switch (self.kind) {
                .apps => |apps| {
                    // Follow the longest branch that exists
                    while (i < key.len) : (i += 1)
                        switch (current.kind) {
                            .apps => |map| {
                                if (map.get(apps[i])) |pat_node|
                                    current = pat_node
                                else
                                    // Key mismatch
                                    return null;
                            },
                            .match => {},
                            .variable => {},
                        }
                    else
                        // All keys were matched, return the value.
                        return current.val;
                },
                else => undefined,
            }
        }

        /// Compares by value, not by len, pos, or pointers.
        pub fn compare(self: Pattern, other: Pattern) Order {
            return self.kind.compare(other.kind);
        }

        /// Compares by value, not by len, pos, or pointers.
        pub fn equalTo(self: Pattern, other: Pattern) bool {
            return .eq == self.compare(other);
        }
    };
}

const testing = std.testing;

test "should behave like a set when given void" {
    const Pat = Pattern(usize, void, void, void);
    const Kind = Pat.Kind;
    var pat = Kind.ofMap();
    pat.val = {};
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    var nodes1: [1]Pat.Kind = undefined;
    var nodes3: [3]Pat.Kind = undefined;

    for (&nodes1, 0..) |*node, i|
        node.* = Kind.ofMapWith(al, i);

    // Empty pattern
    try testing.expectEqual(@as(?void, {}), pat.match(&.{}));
    try testing.expectEqual(@as(?void, null), pat.match(nodes1));
    try testing.expectEqual(@as(?void, null), pat.match(nodes3));

    // Singleton

    // Multiple keys
    try pat.insert(&.{ 1, 2, 3 }, {}, al);
    // try testing.expect(pat.kind.apps.contains(1));
}

const std = @import("std");
const meta = std.meta;
const Allocator = std.mem.Allocator;
const AutoArrayHashMapUnmanaged = std.AutoArrayHashMapUnmanaged;
const ArrayHashMapUnmanaged = std.ArrayHashMapUnmanaged;
const ArenaAllocator = std.heap.ArenaAllocator;
const ast = @import("ast.zig");

/// A trie-like type based on the given hashmap type. Patterns are either a Map,
/// Match, or Var.
/// Every pattern contains zero or more children.
///
pub fn Pattern(comptime Key: type, comptime Val: type) type {
    return struct {
        pub const Self = @This();

        /// The Map kind matches any key in its hashmap.
        pub const Map = AutoArrayHashMapUnmanaged(Key, Self);

        /// The Match kind only matches if its sub_key matches its sub_pat
        /// at least once.
        pub const Match = struct {
            sub_key: Key,
            sub_pat: *Self,
        };

        /// The Var kind matches any key. During rewriting, whenever the key is
        /// encountered again, it is rewritten to this pattern's value.
        pub const Var = struct {
            key: Key,
        };

        ///
        // var var_map = AutoArrayHashMapUnmanaged(Key, Val){};

        /// The value this pattern holds, if any.
        val: ?Val,

        /// The kind primarily determines what how this pattern matches.
        kind: union(enum) {
            /// A trie pattern, stores the first node of all Apps in
            /// this Pattern, forming a trie.
            map: Map,

            /// A pattern match, stores a key and a sub-pattern that must match
            /// for this pattern to match.
            match: Match,

            /// A var pattern, a single node which stores a locally-unique key
            /// for rewriting. Maps to zero or one nodes.
            variable: Var,
        },

        pub fn ofMap(val: ?Val) Self {
            return .{
                .val = val,
                .kind = .{ .map = Self.Map{} },
            };
        }

        /// Create a singlton pattern from one key and an optional value
        pub fn ofMapWith(allocator: Allocator, key: []const Key, val: ?Val) Self {
            var m = Map{};
            m.put(allocator, key, val);
            return .{
                .val = val,
                .kind = .{ .map = m },
            };
        }

        pub fn ofVar(key: Key, val: ?Val) Self {
            return .{
                .val = val,
                .kind = .{ .variable = .{ .key = key } },
            };
        }
        pub fn ofMatch(val: ?Val, sub_key: Key, sub_pat: Self) Self {
            _ = sub_pat;
            _ = sub_key;
            return .{
                .val = val,
            };
        }

        pub fn insert(
            self: *Self,
            keys: []const Key,
            val: ?Val,
            allocator: Allocator,
        ) !void {
            _ = allocator;
            var pattern = self.*;
            var i: usize = 0;
            // Follow the longest branch that exists
            while (i < keys.len) : (i += 1) {
                if (pattern.map.get(keys[i])) |pat_node|
                    pattern = pat_node.pattern
                else
                    break;
            }
            // Create new branches while necessary, but stop before the last
            while (i + 1 < keys.len) : (i += 1) {
                // var node = try allocator.create(Node);
                // node.* = .{
                // .pattern = pattern,
                // .varPat,
                // };
                // var pat = {
                // pattern.map.insert(slice[i], node);
            }
            i += 1;
            // Create the last branch
            pattern.map.insert(keys[i], val);
        }

        pub fn match(self: *Self, keys: []const Key) ?Val {
            var current = self.*;
            var i: usize = 0;
            // Follow the longest branch that exists
            while (i < keys.len) : (i += 1)
                switch (current.kind) {
                    .map => |map| {
                        if (map.get(keys[i])) |pat_node|
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
        }
    };
}

const testing = std.testing;
const Term = @import("../sifu/Term.zig");

test "should behave like a set when given void" {
    const Pat = Pattern(usize, void);
    var pat = Pat.ofMap({});

    // try pat.insert(&.{ 1, 2, 3 }, {}, testing.allocator);
    // try testing.expect(pat.kind.map.contains(1));
    try testing.expectEqual(@as(?void, {}), pat.match(&.{}));
    try testing.expectEqual(@as(?void, null), pat.match(&.{0}));
    try testing.expectEqual(@as(?void, null), pat.match(&.{ 1, 2, 3 }));
}

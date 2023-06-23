const std = @import("std");
const meta = std.meta;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const math = std.math;
const Order = math.Order;

///
/// A trie-like type based on the given term type. Each pattern contains zero or
/// more children.
///
/// The term and var type must be hashable. Nodes track context, the recursive
/// structures (map, match) do not.
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
) type {
    return struct {
        pub const Self = @This();

        // Hashmaps can be used as keys because they are (probably) created
        // deterministically, as long as they have only had elements
        // inserted and not removed.
        pub const Map = if (Lit == []const u8)
            std.StringArrayHashMapUnmanaged(Self)
        else
            std.AutoArrayHashMapUnmanaged(*Self, Self);

        pub const Kind = union(enum) {
            // Literals and variables are leaves
            lit: Lit,

            /// The Var kind matches and stores a locally-unique key. During
            /// rewriting, whenever the key is encountered again, it is
            /// rewritten to this pattern's value.
            @"var": Var,

            /// Maps form the branches of the AST
            map: Map,
        };

        /// The kind primarily determines how this pattern matches, and stores
        /// sub-patterns, if any.
        kind: Kind,

        /// The value this pattern holds, if any.
        val: ?Val,

        pub fn ofMap(val: ?Val) Self {
            return .{
                .kind = .{ .map = Map{} },
                .val = val,
            };
        }

        pub fn ofLit(
            lit: Lit,
            val: ?Val,
        ) Self {
            return .{
                .kind = .{ .lit = lit },
                .val = val,
            };
        }

        pub fn ofVar(key: Self, val: ?Val) Self {
            return .{
                .@"var" = key,
                .val = val,
            };
        }

        pub fn insert(
            self: *Self,
            key: Self,
            val: Val,
            allocator: Allocator,
        ) !void {
            _ = allocator;
            _ = val;
            _ = key;
            switch (self.kind) {
                .lit => {},
                .@"var" => {},
                .map => {},
            }
        }

        fn insertMap(
            self: *Self,
            key: Self,
            val: Val,
            allocator: Allocator,
        ) !void {
            var current = self.*;
            // Follow the longest branch that exists
            while (current.contains(key)) |next| : (current = next)
                switch (current.kind) {
                    .map => |map| {
                        if (map.get()) |pat_node|
                            current = pat_node
                        else
                            // Key mismatch
                            break;
                    },
                    .variable => {},
                };
            // Create new branches while necessary
            while (current.contains(key)) {
                const next = .{
                    .pattern = current,
                    .kind = .{ .variable = .{ .key = key } },
                };
                current.map.put(allocator, key, next);
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
                .map => |map| {
                    _ = map;
                    // Follow the longest branch that exists
                    while (i < key.len) : (i += 1)
                        switch (current.kind) {
                            // .map => |map| {
                            //     if (map.get(map[i])) |pat_node|
                            //         current = pat_node
                            //     else
                            //         // Key mismatch
                            //         return null;
                            // },
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
        pub fn order(self: Pattern, other: Pattern) Order {
            return self.kind.order(other.kind);
        }

        /// Compares by value, not by len, pos, or pointers.
        pub fn equalTo(self: Pattern, other: Pattern) bool {
            return .eq == self.order(other);
        }
    };
}

const testing = std.testing;

test "should behave like a set when given void" {
    const Pat = Pattern(usize, void, void);
    var pat = Pat.ofMap({});
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    _ = al;

    // TODO: insert some apps here once insert is implemented
    // var nodes1: [1]Pat = undefined;
    // var nodes3: [3]Pat = undefined;
    // for (&nodes1, 0..) |*node, i| {
    //     node.* = Pat.ofLit(i, {}, {});
    // }
    // try testing.expectEqual(@as(?void, null), pat.match(nodes1));
    // try testing.expectEqual(@as(?void, null), pat.match(nodes3));

    // Empty pattern
    try testing.expectEqual(@as(?void, {}), pat.match(.{
        .val = {},
        .kind = .{ .map = Pat.Map{} },
    }));
}

test "insert single lit" {}

test "insert multiple lits" {
    // Multiple keys
    // try pat.insert(&.{ 1, 2, 3 }, {}, al);
    // try testing.expect(pat.kind.map.contains(1));
}

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
///
pub fn Pattern(
    comptime Lit: type,
    comptime Var: type,
    comptime Val: type,
) type {
    return struct {
        pub const Self = @This();

        // Subpatterns can be used as keys because they are (probably) created
        // deterministically, as long as they have only had elements inserted
        // and not removed.
        // TODO: define a hash function for keys, including patterns.
        const Map = std.AutoArrayHashMapUnmanaged(Lit, Self);

        /// A Var matches and stores a locally-unique key. During rewriting,
        /// whenever the key is encountered again, it is rewritten to this
        /// pattern's value. A Var pattern matches anything, including nested
        /// patterns. It only makes sense to match anything after trying to
        /// match something specific, so Vars always successfully match (if
        /// there is a Var) after a Lit or Subpat match fails.
        @"var": ?Var = null,

        /// Nested patterns can also be keys. Each layer of pointers encodes
        /// a nested pattern, and are necessary because patterns are difficult
        /// to use as keys directly. This is null when there are no nested
        /// patterns.
        sub_pat: ?*Self = null,

        /// Maps literal terms to the next pattern, if there is one. These form
        /// the branches of the trie.
        map: Map = Map{},

        /// A null value represents an undefined pattern, for example in `Foo
        /// Bar -> 123`, the value at `Foo` would be null.
        val: ?Val = null,

        pub fn empty() Self {
            return .{
                // .map = Map{},
                .val = null,
            };
        }

        pub fn ofLit(
            allocator: Allocator,
            lit: Lit,
            val: ?Val,
        ) !Self {
            var map = Map{};
            try map.put(allocator, lit, .{ .val = val });
            return .{
                .map = map,
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
            var current = self;
            // Follow the longest branch that exists
            while (current) |next| : (current = next)
                switch (current) {
                    .map => |m| {
                        if (m.get()) |pat|
                            current = pat
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

            // .@"var" => |v| .{ .@"var" = v },
            // .token => |token| .{ .lit = token.toString() },
        }

        pub fn match(self: *Self, key: Self) ?Val {
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
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    var pat = try Pat.ofLit(al, 123, {});
    _ = pat;
    // TODO: insert some apps here once insert is implemented
    // var nodes1: [1]Pat = undefined;
    // var nodes3: [3]Pat = undefined;
    // for (&nodes1, 0..) |*node, i| {
    //     node.* = Pat.ofLit(i, {}, {});
    // }
    // try testing.expectEqual(@as(?void, null), pat.match(nodes1));
    // try testing.expectEqual(@as(?void, null), pat.match(nodes3));

    // Empty pattern
    // try testing.expectEqual(@as(?void, {}), pat.match(.{
    //     .val = {},
    //     .kind = .{ .map = Pat.Map{} },
    // }));
}

test "insert single lit" {}

test "insert multiple lits" {
    // Multiple keys
    // try pat.insert(&.{ 1, 2, 3 }, {}, al);
    // try testing.expect(pat.kind.map.contains(1));
}

test "compile: nested" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const Pat = Pattern(usize, void, void);
    var pat = try Pat.ofLit(al, 123, {});
    // Test nested
    const Pat2 = Pat{ .sub_pat = &pat };
    _ = Pat2;
}

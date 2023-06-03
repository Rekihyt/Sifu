const std = @import("std");
const meta = std.meta;
const Allocator = std.mem.Allocator;
const AutoArrayHashMapUnmanaged = std.AutoArrayHashMapUnmanaged;
const ArrayHashMapUnmanaged = std.ArrayHashMapUnmanaged;
const ArenaAllocator = std.heap.ArenaAllocator;
const ast = @import("ast.zig");

/// A trie based on the given hashmap type.
///
/// Uses an arena, therefore does not work with managed hashmap types.
pub fn Pattern(comptime K: type, comptime V: type) type {
    return union(enum) {
        /// A trie pattern, stores the first node of all Apps in
        /// this Pattern, forming a trie.
        map: Map,

        /// A var pattern, a single node which stores a key for rewriting. May
        /// contain a value.
        variable: struct {
            id: K,
            value: ?V,
        },

        pub const Self = @This();
        pub const Ast = ast.Ast(K);
        // pub const PatternNode = struct { value: ?V, pattern: Pattern, };
        pub const Map = AutoArrayHashMapUnmanaged(
            Ast,
            struct {
                value: ?V,
                pattern: Self,
            },
        );

        pub fn empty() Self {
            return .{ .map = Self.Map{} };
        }

        pub fn singleton(allocator: Allocator, key: K, val: V) Self {
            var map = Self.Map{};
            map.put(allocator, key, val);
            return .{ .map = map };
        }

        pub fn varPat(id: K, value: ?V) Self {
            return .{
                .variable = .{
                    .id = id,
                    .value = value,
                },
            };
        }

        pub fn insert(self: *Self, slice: []const K, val: V, allocator: Allocator) !void {
            _ = allocator;
            _ = val;
            var pat = self;
            _ = pat;
            var i: usize = 0;
            // Follow the longest branch that exists
            while (i < slice.len) : (i += 1) {
                // if (pat.map.get(slice[i])) |next_pat|
                //     pat = next_pat
                // else
                //     break;
            }
            // Create new branches while necessary
            while (i < slice.len) : (i += 1) {
                // pat.map.insert();
            }
        }
    };
}

const testing = std.testing;
const Term = @import("../sifu/Term.zig");

test "should behave like a set when given void" {
    // const Pat = Pattern(Term, void);
    // var pat = Pat.empty();
    // _ = pat;

    // try pat.insert(&.{ 1, 2, 3 }, {}, testing.allocator);
    // try testing.expect(pat.map.contains(1));
}

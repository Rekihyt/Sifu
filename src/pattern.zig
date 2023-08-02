const std = @import("std");
const meta = std.meta;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const math = std.math;
const Order = math.Order;
const util = @import("util.zig");
const t = @import("test.zig");
const mem = std.mem;

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

        const Map = if (Lit == []const u8)
            std.StringArrayHashMapUnmanaged(Self)
        else
            std.AutoArrayHashMapUnmanaged(Lit, Self);

        const VarPat = struct {
            @"var": Var,
            next: ?*Self = null,
        };

        const PatMap = std.AutoArrayHashMapUnmanaged(*Self, Self);

        /// A Var matches and stores a locally-unique key. During rewriting,
        /// whenever the key is encountered again, it is rewritten to this
        /// pattern's value. A Var pattern matches anything, including nested
        /// patterns. It only makes sense to match anything after trying to
        /// match something specific, so Vars always successfully match (if
        /// there is a Var) after a Lit or Subpat match fails.
        var_pat: ?VarPat = null,

        /// Nested patterns can also be keys because they are (probably) created
        /// deterministically, as long as they have only had elements inserted
        /// and not removed. This is empty when there are no / nested patterns in
        /// this pattern.
        // TODO: define a hash function for keys, including patterns.
        pat_map: PatMap = PatMap{},

        /// This is for nested apps that this pattern should match. Each layer
        /// of pointer redirection encodes a level of app nesting (parens).
        sub_pat: ?*Self = null,

        /// Maps literal terms to the next pattern, if there is one. These form
        /// the branches of the trie.
        map: Map = Map{},

        /// A null value represents an undefined pattern, for example in `Foo
        /// Bar -> 123`, the value at `Foo` would be null.
        val: ?Val = null,

        pub fn empty() Self {
            return Self{};
        }

        pub fn ofLit(
            allocator: Allocator,
            lit: Lit,
            val: ?Val,
        ) !Self {
            var map = Map{};
            try map.put(allocator, lit, Self{ .val = val });
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

        pub fn eql(self: Self, other: Self) bool {
            var iter = self.map.iterator();
            var other_iter = other.map.iterator();
            while (iter.next()) |next| {
                if (other_iter.next()) |other_next| {
                    // std.debug.print(
                    //     "\n{s}, {s}\n",
                    //     .{ next.key_ptr.*, other_next.key_ptr.* },
                    // );
                    if (util.deepEql(next, other_next))
                        continue;
                }
                return false;
            }
            return other_iter.next() == null and
                util.deepEql(self, other);
        }

        pub fn deepEql(self: Self, other: Self) bool {
            _ = other;
            _ = self;
        }

        /// Pretty print a pattern
        pub fn print(self: Self, writer: anytype) !void {
            try self.printIndent(writer, 0);
        }

        // TODO: add all pattern fields
        fn printIndent(self: Self, writer: anytype, indent: usize) !void {
            try writer.writeByte('|');
            if (self.val) |val| {
                try util.genericWrite(val, writer);
            }
            try writer.writeByte('|');
            try writer.print(" {s}\n", .{"{"});

            var iter = self.map.iterator();
            while (iter.next()) |entry| {
                for (0..indent + 4) |_|
                    try writer.print(" ", .{});

                try writer.print("{s} -> ", .{entry.key_ptr.*});
                try entry.value_ptr.*.printIndent(writer, indent + 4);
            }
            for (0..indent) |_|
                try writer.print(" ", .{});

            try writer.print("{s}\n", .{"}"});
        }
    };
}

const testing = std.testing;

// for debugging with zig test --test-filter, comment this import
const verbose_tests = @import("build_options").verbose_tests;
// const stderr = if (true)
const stderr = if (verbose_tests)
    std.io.getStdErr().writer()
else
    std.io.null_writer;

test "Pattern: eql" {
    const Pat = Pattern([]const u8, void, usize);
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p1 = Pat{};
    var p2 = Pat{
        .val = 123,
    };
    // Reverse order because patterns are values, not references
    try p2.map.put(
        allocator,
        "p1",
        Pat{ .val = 123 },
    );
    try p1.map.put(allocator, "Aa", p2);
    // try testing.expect(p1.eql(p2));

    // try p1.print(stderr);
    // try p2.print(stderr);
}

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
    _ = pat;
    // Test nested
    // const Pat2 = Pat{};
    // Pat2.pat_map.put( &pat, 456 };
    // _ = Pat2;
}

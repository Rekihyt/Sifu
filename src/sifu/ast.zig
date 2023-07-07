const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;
const math = std.math;
const assert = std.debug.assert;
const util = @import("../util.zig");
const Order = math.Order;
const pattern = @import("../pattern.zig");

/// The AST is the first form of structure given to the source code. It handles
/// infix, nesting, and separator operators but does not differentiate between
/// builtins. The `Token` is a custom type to allow storing of metainfo such as
/// `Location`, and must implement `toString()` for pattern conversion.
pub fn Ast(comptime Token: type) type {
    return union(enum) {
        token: Token,
        @"var": []const u8,
        apps: []const Self,
        pattern: Pattern,

        pub const Self = @This();

        /// The Pattern type specific to the Sifu interpreter.
        pub const Pattern = pattern
            .Pattern([]const u8, []const u8, []const Self);

        pub fn of(token: Token) Self {
            return .{ .token = token };
        }

        pub fn ofApps(apps: []const Self) Self {
            return .{ .apps = apps };
        }

        /// Compares by value, not by len, pos, or pointers.
        pub fn order(self: Self, other: Self) Order {
            const ord = math.order(@intFromEnum(self), @intFromEnum(other));
            return if (ord == .eq)
                switch (self) {
                    .apps => |apps| util.orderWith(apps, other.apps, Self.order),
                    .@"var" => |v| mem.order(u8, v, other.@"var"),
                    .token => |token| token.order(other.token),
                    .pattern => |pat| pat.order(other.pattern),
                }
            else
                ord;
        }

        pub fn insert(
            apps: []const Self,
            allocator: Allocator,
            pat: *Pattern,
            val: ?[]const Self,
        ) !bool {
            var current: *Pattern = pat;
            var i: usize = 0;
            // Follow the longest branch that exists
            while (true) : (i += 1) {
                switch (apps[i]) {
                    .token => |token| {
                        if (current.map.getPtr(token.lit)) |next|
                            current = next // TODO: sus
                        else
                            break;
                    },
                    .@"var" => |v| if (current.var_pat) |var_pat| {
                        _ = v;
                        if (var_pat.next) |var_next|
                            current = var_next;
                    },
                    // .apps => |sub_apps| _ =
                    //     try insert(sub_apps, allocator, current, null),
                    else => @panic("unimplemented"),
                }
            }
            // Create new branches while necessary
            for (apps[i..]) |ast| {
                switch (ast) {
                    .token => |token| switch (token.type) {
                        .Val, .Str, .Infix => {
                            const put_result = try current.*.map.getOrPut(
                                allocator,
                                token.lit,
                            );
                            const value_ptr = put_result.value_ptr;
                            value_ptr.* = Pattern.empty();
                            current = value_ptr;
                        },
                        else => @panic("unimplemented"),
                    },
                    else => @panic("unimplemented"),
                }
            }

            const updated = current.val != null;

            // Put the value in this last node
            current.val = val;
            return updated;
        }

        /// As a pattern is matched, a hashmap for vars is populated with
        /// each var's bound variable. These can the be used by the caller for
        /// rewriting.
        pub fn match(self: *Self, allocator: Allocator, key: Self) ?Ast {
            _ = allocator;
            var var_map = std.AutoArrayHashMapUnmanaged(Self, Token){};
            _ = var_map;
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
            return null;
        }
    };
}

const testing = std.testing;
const syntax = @import("syntax.zig");
const Location = syntax.Location;
const Tok = syntax.Token(Location);
const Term = syntax.Term;
const Type = syntax.Type;

test "simple ast to pattern" {
    const term = Tok{
        .type = .Val,
        .lit = "My-Token",
        .context = .{ .uri = null, .pos = 0 },
    };
    _ = term;
    const ast = Ast(Tok){
        .token = .{
            .type = .Val,
            .lit = "Some-Other-Token",
            .context = .{ .uri = null, .pos = 20 },
        },
    };
    _ = ast;
    // _ = Pattern.ofTokenType(term, ast);
}

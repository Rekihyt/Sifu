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
            .Pattern([]const u8, []const u8, *const Self);

        pub const VarMap = std.StringArrayHashMapUnmanaged(Self);

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

        fn rewrite(
            apps: []const Self,
            allocator: Allocator,
            var_map: VarMap,
        ) Allocator.Error![]const Self {
            _ = var_map;
            _ = allocator;
            _ = apps;
        }

        /// Modifies the `pat` pointer to point to the next pattern after the
        /// longest matching prefix. Returns a usize describing this position in
        /// apps, or the len of apps if the entire array was matched.
        fn matchPrefix(
            apps: []const Self,
            allocator: Allocator,
            pat: **const Pattern,
        ) Allocator.Error!usize {
            var current = pat.*;
            defer pat.* = current;
            var i: usize = 0;
            // Follow the longest branch that exists
            while (i < apps.len) : (i += 1) switch (apps[i]) {
                .token => |token| {
                    if (current.map.getPtr(token.lit)) |next|
                        current = next
                    else
                        break;
                },
                .@"var" => |v| if (current.var_pat) |var_pat| {
                    _ = v;
                    if (var_pat.next) |var_next|
                        current = var_next;
                },
                .apps => |sub_apps| if (current.*.sub_pat) |sub_pat|
                    if (try match(sub_apps, allocator, sub_pat.*) == null)
                        break
                    else
                        break,
                .pattern => |sub_pat| {
                    // TODO: lookup sub_pat in current's pat_map
                    _ = sub_pat;
                    @panic("unimplemented");
                },
            };
            return i;
        }

        pub fn match(
            apps: []const Self,
            allocator: Allocator,
            pat: Pattern,
        ) Allocator.Error!?*const Self {
            var var_map = std.AutoArrayHashMapUnmanaged(Self, Token){};
            _ = var_map;
            var current = &pat;
            const i = try matchPrefix(apps, allocator, &current);
            return if (i == apps.len)
                current.val
            else
                null;
        }

        /// As a pattern is matched, a hashmap for vars is populated with
        /// each var's bound variable. These can the be used by the caller for
        /// rewriting.
        pub fn insert(
            apps: []const Self,
            allocator: Allocator,
            pat: *Pattern,
            val: ?*const Self,
        ) Allocator.Error!bool {
            var current = pat;
            const i = try matchPrefix(apps, allocator, &current);
            // Create the rest of the branches
            for (apps[i..]) |ast| switch (ast) {
                .token => |token| switch (token.type) {
                    .Val, .Str, .Infix, .I, .F, .U => {
                        const put_result = try current.map.getOrPut(
                            allocator,
                            token.lit,
                        );
                        current = put_result.value_ptr;
                        current.* = Pattern.empty();
                    },
                    .Var => {
                        const next = try allocator.create(Pattern);
                        next.* = Pattern.empty();
                        current.var_pat = .{
                            .@"var" = token.lit,
                            .next = next,
                        };
                        current = next;
                    },
                    else => @panic("unimplemented"),
                },
                else => @panic("unimplemented"),
            };
            const updated = current.val != null;
            // Put the value in this last node
            current.val = val;
            return updated;
        }

        pub fn write(self: Self, writer: anytype) !void {
            switch (self) {
                .apps => |apps| for (apps) |app| {
                    try app.write(writer);
                    try writer.writeByte(' ');
                },
                .@"var" => |v| try writer.writeAll(v),
                .token => |token| try writer.writeAll(token.lit),
                // .pattern => |pat| try pat.write(writer),
                else => @panic("unimplemented"),
            }
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

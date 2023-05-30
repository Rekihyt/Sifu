const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const fsize = @import("util.zig").fsize;
const assert = std.debug.assert;
const mem = std.mem;
const math = std.math;
const Order = math.Order;

/// The Sifu AST primarily serves to abstract both infix operations and
/// juxtaposition into `App`.
pub const Ast = union(enum) {
    /// Because a term cannot be contained by more than one app (besides
    /// being in a nested app), they can be stored by value.
    apps: []const Ast,

    term: Term,

    pub const Term = struct {
        kind: Kind,
        pos: usize,
        len: usize,

        pub fn toAst(self: Term) Ast {
            return Ast{ .term = self };
        }

        pub fn compare(self: Term, other: Term) Order {
            return self.kind.compare(other.kind);
        }
    };

    // May need to use `std.meta.fieldInfo(Term, .kind).field_type` if the
    // compiler complains about self-dependency
    pub const Kind = union(enum) {
        sep: u8,
        val: []const u8,
        @"var": []const u8,
        infix: []const u8,
        int: usize,
        // unboundInt: []const u1,
        float: fsize(),
        comment: []const u8,

        pub fn compare(self: Kind, other: Kind) Order {
            return if (@enumToInt(self) == @enumToInt(other))
                switch (self) {
                    .infix => |str| mem.order(u8, str, other.infix),
                    .val => |str| mem.order(u8, str, other.val),
                    .@"var" => |str| mem.order(u8, str, other.@"var"),
                    .comment => |str| std.mem.order(u8, str, other.comment),
                    .int => |num| math.order(num, other.int),
                    .float => |num| math.order(num, other.float),
                    .sep => |sep| math.order(sep, other.sep),
                }
            else
                math.order(@enumToInt(self), @enumToInt(other));
        }
    };

    // TODO: figure out a valid ordering here
    pub fn compare(self: Ast, other: Ast) Order {
        return switch (self) {
            .apps => |apps| switch (other) {
                .apps => |others| for (apps, others) |app, other_app|
                    switch (app.compare(other_app)) {
                        .lt => break .lt,
                        .eq => continue,
                        .gt => break .gt,
                    }
                    // equal length strings that compared all their elements
                else
                    .eq,
                // apps are less than non-apps (sort of like in a dictionary)
                else => .lt,
            },
            .term => |term| switch (other) {
                .term => term.compare(other.term),
                .apps => .gt,
            },
        };
    }

    pub fn print(self: Ast, writer: anytype) !void {
        switch (self) {
            .apps => |asts| if (asts.len > 0 and asts[0] == .term and asts[0].term.kind == .infix) {
                // An infix always forms an App with at least 2 nodes, the
                // second of which must be an App
                assert(asts.len >= 2);
                assert(asts[1] == .apps);
                try writer.writeAll("(");
                try asts[1].print(writer);
                try writer.writeByte(' ');
                try writer.writeAll(asts[0].term.kind.infix);
                if (asts.len >= 2)
                    for (asts[2..]) |arg| {
                        try writer.writeByte(' ');
                        try arg.print(writer);
                    };
                try writer.writeAll(")");
            } else if (asts.len != 0) {
                try asts[0].print(writer);
                for (asts[1..]) |ast| {
                    try writer.writeByte(' ');
                    try ast.print(writer);
                }
            },
            .term => |term| switch (term.kind) {
                .sep => |sep| try writer.writeByte(sep),
                .val, .@"var" => |ident| try writer.writeAll(ident),
                .infix => |ident| try writer.writeAll(ident),
                .comment => |cmt| {
                    try writer.writeByte('#');
                    try writer.writeAll(cmt);
                },
                .int => |i| try writer.print("{}", .{i}),
                .float => |f| try writer.print("{}", .{f}),
            },
        }
    }

    // pub fn equalTo(self: Ast, other: Ast) bool {
    //     return self.kind == other.kind and
    //         self.pos == other.pos and
    //         self.len == other.len and
    //         switch (self) {
    //             .apps => |asts|for (asts, others) |ast, other_ast| ast.ast(other_ast);
};

const std = @import("std");
const Token = @import("token.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

/// The Sifu AST primarily serves to abstract both infix operations and
/// juxtaposition into `Apps`.
pub const Ast = struct {
    pub const Kind = union(enum) {
        /// The only node type that can contain other nodes
        apps: []const *Ast,
        val: []const u8,
        @"var": []const u8,
        infix: []const u8,
        int: u64,
        double: f64,
        comment: []const u8,
    };
    kind: Kind,

    pub fn create(allocator: Allocator, kind: Kind) !*Ast {
        const ast = try allocator.create(Ast);
        ast.* = Ast{
            .kind = kind,
        };
        return ast;
    }

    pub fn destroy(self: *Ast, allocator: Allocator) void {
        switch (self.kind) {
            .apps => |asts| for (asts) |ast| ast.destroy(allocator),
            .val => {},
            .@"var" => {},
            .infix => {},
            .int => {},
            .double => {},
            .comment => {},
        }
        allocator.destroy(self);
    }
};

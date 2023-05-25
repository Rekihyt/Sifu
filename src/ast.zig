const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const fsize = @import("util.zig").fsize;

/// A single leaf node in Sifu's AST. It cannot contain other nodes. Keeps
/// track of its position in the original source.
pub const Term = struct {
    // May need to use `std.meta.fieldInfo(Term, .kind).field_type` if the
    // compiler complains about self-dependency
    pub const Kind = union(enum) {
        sep: u8,
        val: []const u8,
        @"var": []const u8,
        infix: []const u8,
        int: usize,
        // unboundInt: []const u1,
        double: f64,
        comment: []const u8,
    };
    kind: Kind,
    pos: usize,
    len: usize,

    pub fn create(allocator: Allocator, term: Term) !*Term {
        const term_ptr = try allocator.create(Term);
        const x: []const u8 = switch (term) {
            .val, .@"var", .infix, .comment => |str| allocator.dupe(str),
            .int, .double => |i| allocator.create(@TypeOf(i)),
        };
        _ = x;
        term_ptr.* = term;
        return term_ptr;
    }
};

/// The Sifu AST primarily serves to abstract both infix operations and
/// juxtaposition into `Apps`.
pub const Ast = union(enum) {
    term: *Term,
    /// The only node type that can contain other nodes
    apps: []const Ast,

    pub fn create(allocator: Allocator, ast: Ast) !*Ast {
        const ast_ptr = try allocator.create(Ast);
        ast.* = ast;
        return ast_ptr;
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

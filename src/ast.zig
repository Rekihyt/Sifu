const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const fsize = @import("util.zig").fsize;

pub const Term = struct {};

/// The Sifu AST primarily serves to abstract both infix operations and
/// juxtaposition into `App`.
pub const Ast = struct {
    kind: Kind,
    pos: usize,
    len: usize,

    // May need to use `std.meta.fieldInfo(Term, .kind).field_type` if the
    // compiler complains about self-dependency
    pub const Kind = union(enum) {
        /// The only node type that can contain other nodes. Because a term
        /// cannot be contained by more than one app (besides being in a
        /// nested app), they can be stored by value.
        apps: []const Ast,
        sep: u8,
        val: []const u8,
        @"var": []const u8,
        infix: []const u8,
        int: usize,
        // unboundInt: []const u1,
        double: f64,
        comment: []const u8,
    };
};

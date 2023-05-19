const std = @import("std");
const Token = @import("token.zig");
const Errors = @import("error.zig").Errors;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

/// Ast represents all parsed Nodes
pub const Ast = struct {
    nodes: []const Node,
    arena: ArenaAllocator,

    pub fn init(self: *Ast, allocator: Allocator) void {
        self.arena.init(allocator);
    }

    /// Frees all memory
    pub fn deinit(self: Ast) void {
        self.arena.deinit();
    }
};

/// Possible Nodes which are supported
pub const NodeType = enum {
    app,
    val,
    @"var",
    infix,
    double,
    int,
    comment,
};

/// Node represents a grammatical token within the language
/// i.e. a mutable statement such as mut x = 5
pub const Node = struct {
    token: Token,
    node_type: union(NodeType) {
        app: *App,
        val: *Val,
        @"var": *Var,
        infix: *Infix,
        int: *Int,
        double: *Double,
        comment: *Comment,
    },

    /// Concatentation of nodes
    pub const App = struct {
        lhs: Node,
        rhs: Node,
    };

    /// Val identifier literal, or a string literal
    pub const Val = struct {
        name: []const u8,
    };

    /// Var identifier literal
    pub const Var = struct {
        name: []const u8,
    };

    /// An infix identifier literal
    pub const Infix = struct {
        name: []const u8,
    };

    /// Integer literal
    pub const Int = struct {
        value: u64,
    };

    /// Floating point literal (an `Int` with a `.`)
    pub const Double = struct {
        value: f64,
    };

    /// Represents a single line comment
    pub const Comment = struct {
        value: []const u8,
    };
};

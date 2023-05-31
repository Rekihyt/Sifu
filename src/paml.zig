const std = @import("std");
const parser = @import("Paml/parser.zig");

const Allocator = std.mem.Allocator;

/// The core rewrite engine for Sifu.
// const Paml = @This();

// root: Trie,

arena: Allocator,

// pub fn init(self: *Paml) Paml {
//     _ = self;
// }

// pub fn deinit(self: *Paml) Paml {
//     self.arena.deinit();
// }

test "Submodules" {
    _ = @import("Paml/util.zig");
    _ = @import("Paml/ast.zig");
    _ = @import("Paml/parser.zig");
}

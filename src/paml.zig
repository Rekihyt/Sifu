const std = @import("std");

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
    _ = @import("paml/ast.zig");
    _ = @import("paml/pattern.zig");
}

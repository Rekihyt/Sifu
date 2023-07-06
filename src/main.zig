const std = @import("std");
const sifu = @import("sifu.zig");
const pattern = @import("pattern.zig");
const Ast = @import("sifu/ast.zig").Ast(Location);
const syntax = @import("sifu/syntax.zig");
const Location = syntax.Location;
const Pattern = Ast.Pattern;

const Allocator = std.mem.Allocator;

const log = std.log.scoped(.sifu_cli);

pub fn main() !void {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_alloc.deinit();
    const gpa = gpa_alloc.allocator();
    _ = gpa;
}

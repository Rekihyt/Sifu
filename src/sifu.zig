/// This file contains the specific instantiated versions of the langauge's
/// general types.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Pattern = @import("../pattern.zig")
    .Pattern([]const u8, []const u8, Ast);
pub const Errors = @import("sifu/errors.zig").Errors;
const Lexer = @import("sifu/Lexer.zig");
const syntax = @import("sifu/syntax.zig");
const Ast = @import("sifu/ast.zig").Ast;
const parser = @import("sifu/parser.zig");
const ArenaAllocator = std.heap.ArenaAllocator;

pub fn parse(allocator: Allocator, source: []const u8) !Pattern {
    var lexer = Lexer.init(allocator, source);
    defer lexer.deinit();

    var arena = ArenaAllocator.init(allocator);
    defer arena.deinit();

    return parser.parse(
        arena,
        try lexer.apps(),
    );
}

const testing = std.testing;
test "Submodules" {
    _ = @import("sifu/ast.zig");
    _ = @import("sifu/errors.zig");
    _ = @import("sifu/interpreter.zig");
    _ = @import("sifu/Lexer.zig");
    _ = @import("sifu/parser.zig");
    _ = @import("sifu/pattern.zig");
    _ = @import("sifu/syntax.zig");
}

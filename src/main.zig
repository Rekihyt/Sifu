const std = @import("std");
const sifu = @import("sifu.zig");
const pattern = @import("pattern.zig");
const Ast = @import("sifu/ast.zig").Ast(Location);
const syntax = @import("sifu/syntax.zig");
const Location = syntax.Location;
const Pattern = Ast.Pattern;
const interpreter = @import("sifu/interpreter.zig");
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const Lexer = @import("sifu/lexer.zig").Lexer(fs.File.Reader);
const io = std.io;
const fs = std.fs;
const log = std.log.scoped(.sifu_cli);

pub fn main() !void {
    // var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    // defer _ = gpa_alloc.deinit();
    // const gpa = gpa_alloc.allocator();
    var arena = ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    _ = allocator;

    const stdin = io.getStdIn().reader();
    const stdout = io.getStdOut().writer();
    _ = stdout;
    const buffer_size = 2048;
    var buffer: [buffer_size]u8 = undefined;
    var fbs = io.fixedBufferStream(&buffer);
    while (true) {
        if (stdin.streamUntilDelimiter(fbs.writer(), '\n', buffer_size)) {
            std.debug.print("{s}\n", .{buffer});
        } else |e| if (e == error.EndOfStream)
            break
        else
            return e;
    }
}

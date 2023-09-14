const std = @import("std");
const sifu = @import("sifu.zig");
const Ast = @import("sifu/ast.zig").Ast;
const Pat = Ast.Pat;
const syntax = @import("sifu/syntax.zig");
const interpreter = @import("sifu/interpreter.zig");
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const Lexer = @import("sifu/Lexer.zig");
const parse = @import("sifu/parser.zig").parse;
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

    const stdin = io.getStdIn().reader();
    const stdout = io.getStdOut().writer();
    var buff_writer = io.bufferedWriter(stdout);
    const buff_stdout = buff_writer.writer();
    const buff_size = 4096;
    var buff: [buff_size]u8 = undefined;
    var fbs = io.fixedBufferStream(&buff);

    // TODO: Fix repl specific behavior
    //    - restart parsing after 2 newlines
    //    - exit on EOF
    var lexer = Lexer.init(allocator);
    var repl_pat = Pat{};
    while (stdin.streamUntilDelimiter(fbs.writer(), '\n', null)) |_| {
        var fbs_reader = io.fixedBufferStream(fbs.getWritten());
        for (fbs_reader.getWritten()) |char| {
            if (char == 0x1b) { // escape

            }
        }
        const ast = try parse(allocator, &lexer, fbs_reader.reader()) orelse
            break;

        _ = try repl_pat.matchPrefix(allocator, ast.apps);
        try ast.write(buff_stdout);
        try repl_pat.print(buff_stdout);
        try buff_writer.flush();
        fbs.reset();
    } else |e| switch (e) {
        error.EndOfStream => return {},
        // error.StreamTooLong => return e, // TODO: handle somehow
        else => return e,
    }
}

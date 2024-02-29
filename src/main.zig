const std = @import("std");
const sifu = @import("sifu.zig");
const Pat = @import("sifu/ast.zig").Pat;
const Ast = Pat.Node;
const syntax = @import("sifu/syntax.zig");
const interpreter = @import("sifu/interpreter.zig");
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const Lexer = @import("sifu/Lexer.zig").Lexer;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const parseAst = @import("sifu/parser.zig").parseAst;
const io = std.io;
const fs = std.fs;
const log = std.log.scoped(.sifu_cli);
const mem = std.mem;
const print = std.debug.print;

pub fn main() !void {
    // @compileLog(@sizeOf(Pat));
    // @compileLog(@sizeOf(Pat.Node));
    // @compileLog(@sizeOf(ArrayListUnmanaged(Pat.Node)));

    var token_arena = ArenaAllocator.init(std.heap.page_allocator);
    defer token_arena.deinit();
    const token_allocator = token_arena.allocator();

    var gpa =
        std.heap.GeneralPurposeAllocator(
        .{ .safety = false, .verbose_log = false, .enable_memory_limit = true },
    ){};
    defer _ = gpa.detectLeaks();
    const allocator = gpa.allocator();

    var parser_gpa =
        std.heap.GeneralPurposeAllocator(
        .{ .safety = true, .verbose_log = false },
    ){};
    defer _ = parser_gpa.deinit();
    const parser_allocator = parser_gpa.allocator();

    var match_gpa =
        std.heap.GeneralPurposeAllocator(
        .{ .safety = true, .verbose_log = true },
    ){};
    defer _ = match_gpa.deinit();
    const match_allocator = match_gpa.allocator();

    const stdin = io.getStdIn().reader();
    const stdout = io.getStdOut().writer();
    const stderr = io.getStdErr().writer();
    var buff_writer = io.bufferedWriter(stdout);
    const buff_stdout = buff_writer.writer();
    const buff_size = 4096;
    var buff: [buff_size]u8 = undefined;
    var fbs = io.fixedBufferStream(&buff);
    // TODO: Fix repl specific behavior
    //    - restart parsing after 2 newlines
    //    - exit on EOF
    var repl_pat = Pat{};
    defer repl_pat.deleteChildren(allocator);
    // try stderr.print("Repl Pat Address: {*}", .{&repl_pat});

    while (stdin.streamUntilDelimiter(fbs.writer(), '\n', fbs.buffer.len)) |_| {
        try repl_pat.pretty(buff_stdout);
        try stderr.print("Allocated: {}\n", .{gpa.total_requested_bytes});

        var fbs_written = io.fixedBufferStream(fbs.getWritten());
        var fbs_written_reader = fbs_written.reader();
        var lexer = Lexer(@TypeOf(fbs_written_reader))
            .init(token_allocator, fbs_written_reader);
        // for (fbs.getWritten()) |char| {
        // escape (from pressing alt+enter in most terminals)
        // if (char == 0x1b) {}
        // }
        var ast = try parseAst(parser_allocator, &lexer);
        // defer _ = parser_gpa.detectLeaks();
        defer ast.deleteChildren(parser_allocator);

        try stderr.writeAll("Parsed: ");
        try ast.write(stderr);
        _ = try stderr.write("\n");
        // for (ast.apps) |debug_ast|
        //     try debug_ast.write(buff_stdout);

        // TODO: insert with shell command like @insert instead of special
        // casing a top level insert
        if (ast.apps.len == 1 and ast.apps[0] == .arrow) {
            const arrow = ast.apps[0];
            const result = try repl_pat.insertNode(allocator, arrow);
            try stderr.print("New pat ptr: {*}\n", .{result});
        } else {
            defer _ = match_gpa.detectLeaks();
            var var_map = Pat.VarMap{};
            defer var_map.deinit(match_allocator);
            const matches = try repl_pat.flattenPattern(
                match_allocator,
                &var_map,
                ast,
            );
            defer match_allocator.free(matches);
            // If not inserting, then try to match the expression
            if (matches.len > 0) {
                for (matches) |matched| {
                    print("Match: ", .{});
                    try matched.end.write(buff_stdout);
                    _ = try buff_writer.write("\n");
                }
            } else print("No match\n", .{});
        }
        try buff_writer.flush();
        fbs.reset();
    } else |e| switch (e) {
        error.EndOfStream => return {},
        // error.StreamTooLong => return e, // TODO: handle somehow
        else => return e,
    }
}

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
    var buff_writer_stdout = io.bufferedWriter(stdout);
    const buff_stdout = buff_writer_stdout.writer();
    const buff_size = 4096;
    var buff: [buff_size]u8 = undefined;
    var fbs = io.fixedBufferStream(&buff);
    // TODO: Fix repl specific behavior
    //    - exit on EOF
    var repl_pat = Pat{};
    defer repl_pat.deinit(allocator);

    while (stdin.streamUntilDelimiter(fbs.writer(), '\n', fbs.buffer.len)) |_| {
        var fbs_written = io.fixedBufferStream(fbs.getWritten());
        var fbs_written_reader = fbs_written.reader();
        var lexer = Lexer(@TypeOf(fbs_written_reader))
            .init(token_allocator, fbs_written_reader);
        // for (fbs.getWritten()) |char| {
        // escape (from pressing alt+enter in most shells)
        // if (char == 0x1b) {}
        // }
        // TODO: combine lexer and parser allocators, avoid token/parsing memory
        // leaks when freeing asts in the loop
        var ast = try parseAst(parser_allocator, &lexer);
        defer _ = parser_gpa.detectLeaks();
        defer ast.deinit(parser_allocator);

        try stderr.print("Parsed {s}:\n", .{@tagName(ast)});
        try ast.write(stderr);
        _ = try stderr.write("\n");

        // TODO: put with shell command like @put instead of special
        // casing a top level insert
        if (ast == .arrow) {
            const arrow = ast.arrow;
            const apps = Ast.ofApps(arrow[0 .. arrow.len - 1]);
            const val = arrow[arrow.len - 1];
            print("Parsed apps hash: {}\n", .{apps.hash()});
            try repl_pat.put(allocator, apps, val);
        } else {
            print("Parsed ast hash: {}\n", .{ast.hash()});
            defer _ = match_gpa.detectLeaks();
            var var_map = Pat.VarMap{};
            defer var_map.deinit(match_allocator);
            const maybe_match = try repl_pat.match(
                match_allocator,
                &var_map,
                ast,
            );
            // defer if (maybe_match) |match|
            //     match.result.deinit(allocator);
            // If not inserting, then try to match the expression
            if (maybe_match) |match|
                if (match.result) |result| {
                    print("Match: ", .{});
                    try result.write(buff_stdout);
                    try buff_stdout.writeByte('\n');
                } else print("Match, but no result\n", .{})
            else
                print("No match\n", .{});
            const rewrite = try repl_pat.rewrite(match_allocator, ast);
            defer rewrite.deinit(match_allocator);
            print("Rewrite: ", .{});
            try rewrite.write(buff_stdout);
            try buff_stdout.writeByte('\n');
            // const evaluation = try repl_pat.evaluate(match_allocator, ast);
            // defer match_allocator.free(evaluation);
            // print("Eval: ", .{});
            // if (evaluation) |eval|
            //     eval.pretty(buff_stdout);
        }
        try repl_pat.pretty(buff_stdout);
        try stderr.print("Allocated: {}\n", .{gpa.total_requested_bytes});
        try buff_writer_stdout.flush();
        fbs.reset();
    } else |e| switch (e) {
        error.EndOfStream => return {},
        // error.StreamTooLong => return e, // TODO: handle somehow
        else => return e,
    }
}

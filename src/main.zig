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
const log = std.log.scoped(.sifu_cli);
const mem = std.mem;
const print = std.debug.print;
const wasm = @import("builtin").os.tag == .freestanding;
const stderr = if (wasm)
    io.getStdErr().writer()
else
    std.io.null_writer;
const GeneralPurposeAllocator = std.heap.GeneralPurposeAllocator(
    .{ .safety = false, .verbose_log = false, .enable_memory_limit = true },
);

pub fn main() !void {

    // // @compileLog(@sizeOf(Pat));
    // // @compileLog(@sizeOf(Pat.Node));
    // // @compileLog(@sizeOf(ArrayListUnmanaged(Pat.Node)));

    var gpa = GeneralPurposeAllocator{};
    defer _ = gpa.detectLeaks();
    const stdin = io.getStdIn().reader();
    const stdout = io.getStdOut().writer();
    var buff_writer_stdout = io.bufferedWriter(stdout);
    const buff_stdout = buff_writer_stdout.writer();
    // TODO: Implement repl specific behavior
    var pattern = Pat{};
    defer pattern.deinit(gpa.allocator());

    while (repl(&pattern, &gpa, stdin, buff_stdout)) |_| {
        try buff_writer_stdout.flush();
        try stderr.print(
            "Pattern Allocated: {}\n",
            .{gpa.total_requested_bytes},
        );
    } else |err| switch (err) {
        error.EndOfStream => return {},
        // error.StreamTooLong => return e, // TODO: handle somehow
        else => return err,
    }
    _ = gpa.detectLeaks();
}
fn repl(
    pattern: *Pat,
    pattern_gpa: *GeneralPurposeAllocator,
    input: anytype,
    output: anytype,
) !void {
    const pat_allocator = pattern_gpa.allocator();
    // For single-loop lifespans, like lexing, parsing and matching
    var arena = ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const buff_size = 4096;
    var buff: [buff_size]u8 = undefined;
    var fbs = io.fixedBufferStream(&buff);
    return if (input.streamUntilDelimiter(fbs.writer(), '\n', fbs.buffer.len)) |_| {
        var fbs_written = io.fixedBufferStream(fbs.getWritten());
        const fbs_written_reader = fbs_written.reader();
        var lexer = Lexer(@TypeOf(fbs_written_reader))
            .init(arena_allocator, fbs_written_reader);
        // for (fbs.getWritten()) |char| {
        // escape (from pressing alt+enter in most shells)
        // if (char == 0x1b) {}
        // }
        // TODO: combine lexer and parser allocators
        var apps = try parseAst(arena_allocator, &lexer);
        const ast = Ast.ofApps(apps);

        // Future parsing will always return apps
        try stderr.print("Parsed:\n", .{});
        try ast.write(stderr);
        _ = try stderr.write("\n");

        // TODO: put with shell command like @put instead of special
        // casing a top level insert
        if (apps.len > 0 and apps[apps.len - 1] == .arrow) {
            const key = apps[0 .. apps.len - 1];
            const val = Ast.ofApps(apps[apps.len - 1].arrow);
            // print("Parsed apps hash: {}\n", .{apps.hash()});
            try pattern.put(pat_allocator, key, val);
        } else {
            // // print("Parsed ast hash: {}\n", .{ast.hash()});
            // if (repl_pat.get(ast.apps)) |got| {
            //     print("Got: ", .{});
            //     try got.write(stderr);
            //     print("\n", .{});
            // } else print("Got null\n", .{});
            // var indices = try match_allocator.alloc(usize, ast.apps.len);
            // defer match_allocator.free(indices);
            // var match = try repl_pat.match(
            //     match_allocator,
            //     // indices,
            //     ast.apps,
            // );
            // defer match.deinit(match_allocator);
            // // If not inserting, then try to match the expression
            // if (match.value) |value| {
            //     try buff_stdout.writeAll(
            //         if (match.len == ast.apps.len)
            //             "Match "
            //         else
            //             "Partial Match ",
            //     );
            //     try buff_stdout.print("of len {}: ", .{match.len});
            //     try value.write(buff_stdout);
            //     try buff_stdout.writeByte('\n');
            // } else {
            //     try buff_stdout.print(
            //         "No match, after {} nodes followed\n",
            //         .{match.len},
            //     );
            // }
            // const rewrite = try repl_pat.rewrite(match_allocator, ast);
            // defer rewrite.deinit(match_allocator);
            // print("Rewrite: ", .{});
            // try rewrite.write(buff_stdout);
            // try buff_stdout.writeByte('\n');
            const eval = try pattern.evaluate(arena_allocator, apps);
            try output.print("Eval: ", .{});
            for (eval) |app| {
                try app.writeSExp(output, 0);
                try output.writeByte(' ');
            }
            try output.writeByte('\n');
        }
        try pattern.pretty(output);
        fbs.reset();
    } else |err| err;
}

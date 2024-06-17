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
// const log = if (wasm) std.log.scoped(.sifu_cli) else

const mem = std.mem;
const print = std.debug.print;
const wasm = @import("wasm.zig");
const is_wasm = @import("builtin").os.tag == .freestanding;
const GeneralPurposeAllocator = std.heap.GeneralPurposeAllocator(
    .{ .safety = true, .verbose_log = false, .enable_memory_limit = true },
);

pub fn main() !void {

    // // @compileLog(@sizeOf(Pat));
    // // @compileLog(@sizeOf(Pat.Node));
    // // @compileLog(@sizeOf(ArrayListUnmanaged(Pat.Node)));

    var gpa = GeneralPurposeAllocator{};
    const allocator = gpa.allocator();
    var arena_allocator = ArenaAllocator.init(std.heap.page_allocator);

    const arena = arena_allocator.allocator();
    defer _ = gpa.detectLeaks();
    const stdin, const stdout, const stderr = if (is_wasm)
        wasm.Streams
    else
        .{
            io.getStdIn().reader(),
            io.getStdOut().writer(),
            io.getStdErr().writer(),
        };
    var buff_writer_stdout = io.bufferedWriter(stdout);
    const buff_stdout = buff_writer_stdout.writer();
    // TODO: Implement repl specific behavior
    var pattern = Pat{};
    defer pattern.deinit(allocator);

    while (repl(&pattern, allocator, arena, stdin, buff_stdout, stderr)) |_| {
        try buff_writer_stdout.flush();
        try stderr.print(
            "Pattern Allocated: {}\n",
            .{gpa.total_requested_bytes},
        );
        _ = arena_allocator.reset(.free_all);
        try stderr.print(
            "Arena Capacity: {}\n",
            .{arena_allocator.queryCapacity()},
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
    // For persistent lifespans, like lexing or parsing done for inserting
    allocator: Allocator,
    // For single-loop lifespans, like lexing or parsing done for matching
    arena: Allocator,
    input: anytype,
    output: anytype,
    err_output: anytype,
) !void {
    const buff_size = 4096;
    var buff: [buff_size]u8 = undefined;
    var fbs = io.fixedBufferStream(&buff);
    return if (input.streamUntilDelimiter(fbs.writer(), '\n', fbs.buffer.len)) |_| {
        var fbs_written = io.fixedBufferStream(fbs.getWritten());
        var lexer = Lexer(@TypeOf(fbs_written).Reader)
            .init(arena, fbs_written.reader());
        // for (fbs.getWritten()) |char| {
        // escape (from pressing alt+enter in most shells)
        // if (char == 0x1b) {}
        // }
        // TODO: combine lexer and parser allocators
        var apps = try parseAst(arena, &lexer);
        const ast = Ast.ofApps(apps);

        // Future parsing will always return apps
        try err_output.print("Parsed:\n", .{});
        try ast.write(err_output);
        _ = try err_output.write("\n");

        // TODO: put with shell command like @put instead of special
        // casing a top level insert
        if (apps.len > 0 and apps[apps.len - 1] == .arrow) {
            const key = apps[0 .. apps.len - 1];
            const val = Ast.ofApps(apps[apps.len - 1].arrow);
            // print("Parsed apps hash: {}\n", .{apps.hash()});
            try pattern.put(allocator, key, val);
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
            const eval = try pattern.evaluate(arena, apps);
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

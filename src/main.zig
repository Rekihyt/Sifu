const std = @import("std");
const sifu = @import("sifu.zig");
const Pat = @import("sifu/ast.zig").Pat;
const Ast = Pat.Node;
const syntax = @import("sifu/syntax.zig");
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const Lexer = @import("sifu/Lexer.zig").Lexer;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const parseAst = @import("sifu/parser.zig").parseAst;
const streams = @import("streams.zig").streams;
const io = std.io;
const mem = std.mem;
const wasm = @import("wasm.zig");
const builtin = @import("builtin");
const no_os = builtin.target.os.tag == .freestanding;
const panic = @import("util.zig").panic;
// TODO: merge these into just GPA, when it eventually implements wasm_allocator
// itself
var gpa = if (no_os) undefined else std.heap.GeneralPurposeAllocator(
    .{ .safety = true, .verbose_log = false, .enable_memory_limit = true },
){};

pub fn main() void {
    // @compileLog(@sizeOf(Pat));
    // @compileLog(@sizeOf(Pat.Node));
    // @compileLog(@sizeOf(ArrayListUnmanaged(Pat.Node)));

    const allocator = if (no_os)
        std.heap.wasm_allocator
    else
        gpa.allocator();

    if (comptime !no_os) {
        defer _ = gpa.detectLeaks();
    }
    repl(allocator) catch |e|
        panic("{}", .{e});

    if (comptime !no_os)
        _ = gpa.detectLeaks();
}

fn repl(
    allocator: Allocator,
) !void {
    var arena_allocator = ArenaAllocator.init(allocator);
    const arena = arena_allocator.allocator();
    var buff_writer_stdout = io.bufferedWriter(streams.out);
    const buff_stdout = buff_writer_stdout.writer();
    const io_streams = .{ streams.in, buff_stdout, streams.err };
    // TODO: Implement repl specific behavior
    var pattern = Pat{};
    defer pattern.deinit(allocator);
    while (replStep(&pattern, allocator, arena, io_streams)) |_| {
        try buff_writer_stdout.flush();
        if (comptime !no_os) try streams.err.print(
            "Pattern Allocated: {}\n",
            .{gpa.total_requested_bytes},
        );
        _ = arena_allocator.reset(.free_all);
    } else |err| switch (err) {
        error.EndOfStream => return {},
        // error.StreamTooLong => return e, // TODO: handle somehow
        else => return err,
    }
}

fn replStep(
    pattern: *Pat,
    pat_allocator: Allocator,
    arena: Allocator,
    io_streams: anytype,
) !void {
    const in_stream, const out_stream, const err_stream = io_streams;
    const buff_size = 4096;
    var buff: [buff_size]u8 = undefined;
    var fbs = io.fixedBufferStream(&buff);

    if (in_stream.streamUntilDelimiter(fbs.writer(), '\n', fbs.buffer.len)) |_| {
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
        try err_stream.print("Parsed {} apps: ", .{apps.len});
        try ast.write(err_stream);
        _ = try err_stream.write("\n");

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
            const eval = try pattern.evaluate(arena, apps);
            try out_stream.print("Eval: ", .{});
            for (eval) |app| {
                try app.writeSExp(out_stream, 0);
                try out_stream.writeByte(' ');
            }
            try out_stream.writeByte('\n');
        }
        try pattern.pretty(out_stream);
        fbs.reset();
    } else |err| return err;
}

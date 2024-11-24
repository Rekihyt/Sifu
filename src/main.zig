const std = @import("std");
const sifu = @import("sifu.zig");
const Pattern = @import("sifu/pattern.zig").Pattern;
const syntax = @import("sifu/syntax.zig");
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const parse = @import("sifu/parser.zig").parse;
const streams = @import("streams.zig").streams;
const io = std.io;
const mem = std.mem;
const wasm = @import("wasm.zig");
const builtin = @import("builtin");
const no_os = builtin.target.os.tag == .freestanding;
const util = @import("util.zig");
const panic = util.panic;
const print = util.print;
const detect_leaks = @import("build_options").detect_leaks;
const debug_mode = @import("builtin").mode == .Debug;
// TODO: merge these into just GPA, when it eventually implements wasm_allocator
// itself
var gpa = if (no_os) {} else GPA{};
const GPA = util.GPA;

pub fn main() void {
    // @compileLog(@sizeOf(Pat));
    // @compileLog(@sizeOf(Pat.Node));
    // @compileLog(@sizeOf(ArrayListUnmanaged(Pat.Node)));

    const backing_allocator = if (no_os)
        std.heap.wasm_allocator
    else
        std.heap.page_allocator;

    var arena = if (comptime detect_leaks)
        gpa
    else
        ArenaAllocator.init(backing_allocator);

    repl(arena.allocator()) catch |e|
        panic("{}", .{e});

    if (comptime detect_leaks)
        _ = gpa.detectLeaks()
    else
        arena.deinit();
}

// TODO: Implement repl/file specific behavior
fn repl(
    allocator: Allocator,
) !void {
    var buff_writer_out = io.bufferedWriter(streams.out);
    const buff_out = buff_writer_out.writer();
    var trie = Pat{}; // This will be cleaned up with the arena

    while (replStep(&trie, allocator, buff_out)) |_| {
        try buff_writer_out.flush();
        if (comptime !no_os and detect_leaks) try streams.err.print(
            "GPA Allocated: {} bytes\n",
            .{gpa.total_requested_bytes},
        );
    } else |err| switch (err) {
        error.EndOfStream => return {},
        // error.StreamTooLong => return e, // TODO: handle somehow
        else => return err,
    }
}

fn replStep(
    trie: *Pat,
    allocator: Allocator,
    writer: anytype,
) !?void {
    // An arena for match lifetimes: parsed strings and pattern/sub tries

    const pattern, var str_arena = try parse(allocator, streams.in) orelse
        return error.EndOfStream;
    defer tree.deinit(allocator);

    const pattern = tree.root;
    const ast = Ast.ofPattern(tree);

    print(
        "Parsed pattern {} high and {} wide: ",
        .{ tree.height, pattern.len },
    );
    try pattern.write(streams.err);
    print("\nof types: ", .{});
    for (pattern) |app| {
        print("{s} ", .{@tagName(app)});
        app.writeSExp(streams.err, 0) catch unreachable;
        streams.err.writeByte(' ') catch unreachable;
    }
    print("\n", .{});

    // for (fbs.getWritten()) |char| {
    // escape (from pressing alt+enter in most shells)
    // if (char == 0x1b) {}
    // }
    // TODO: read a "file" from stdin first, until eof, then start eval/matching
    // until another eof.
    if (pattern.len > 0 and pattern[pattern.len - 1] == .arrow) {
        const key = pattern[0 .. pattern.len - 1];
        const val = pattern[pattern.len - 1].arrow;
        // TODO: calculate correct tree height
        _ = try trie.append(
            allocator,
            .{ .root = key, .height = tree.height },
            try Pat.Node.ofPattern(val).clone(allocator),
        );
    } else {
        // Free the rest of the match's string allocations. Those used in
        // rewriting must be completely copied.
        defer str_arena.deinit();
        // If not inserting, then try to match the expression
        // TODO: put into a comptime for eval kind
        // print("Parsed ast hash: {}\n", .{ast.hash()});
        // TODO: change to get by index or something
        if (trie.get(ast.pattern)) |got| {
            print("Got: ", .{});
            try got.write(streams.err);
            print("\n", .{});
        } else print("Got null\n", .{});

        // const step = try trie.evaluateStep(allocator, 0, tree);
        // defer Ast.ofPattern(step).deinit(allocator);
        // print("Match Rewrite: ", .{});
        // try Ast.ofPattern(step).write(writer);
        // try writer.writeByte('\n');

        // const eval = try trie.evaluate(allocator, pattern);
        // defer if (comptime detect_leaks)
        //     Ast.ofPattern(eval).deinit(allocator)
        // else
        //     eval.deinit();
        // try writer.print("Eval: ", .{});
        // for (eval) |pattern| {
        //     try pattern.writeSExp(writer, 0);
        //     try writer.writeByte(' ');
        // }
        // try writer.writeByte('\n');
    }
    try trie.pretty(writer);
    try trie.writeCanonical(writer);
}

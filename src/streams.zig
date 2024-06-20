const std = @import("std");
const io = std.io;
const is_wasm = @import("builtin").target.cpu.arch == .wasm32;
const wasm = @import("wasm.zig");
const verbose_tests = @import("build_options").verbose_errors;

pub const streams = if (is_wasm) wasm.streams else .{
    io.getStdIn().reader(),
    io.getStdOut().writer(),
    if (verbose_tests)
        std.io.getStdErr().writer()
    else
        std.io.null_writer,
};

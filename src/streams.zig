const std = @import("std");
const io = std.io;
const no_os = @import("builtin").target.os.tag == .freestanding;
const wasm = @import("wasm.zig");
const verbose_tests = @import("build_options").verbose_errors;

pub const streams = if (no_os) wasm.streams else .{
    io.getStdIn().reader(),
    io.getStdOut().writer(),
    if (verbose_tests)
        std.io.getStdErr().writer()
    else
        std.io.null_writer,
};

const std = @import("std");
// for debugging with zig test --test-filter, comment this import
const verbose_errors = @import("build_options").verbose_errors;

extern "env" fn log(msg_ptr: [*]const u8, msg_len: usize) void;
extern "env" fn promptIntoAddr(
    result_addr_ptr: *const [*]u8,
    result_len_ptr: *const usize,
) void;

// TODO: add errors / return len
fn writeFn(ctx: *const anyopaque, bytes: []const u8) error{}!usize {
    _ = ctx;
    log(bytes.ptr, bytes.len);
    return bytes.len;
}

fn readFn(ctx: *const anyopaque, bytes: []u8) error{}!usize {
    _ = ctx;
    promptIntoAddr(&bytes.ptr, &bytes.len);
    return bytes.len;
}

pub fn panic(comptime msg: []const u8, args: anytype) noreturn {
    streams[2].print(msg, args) catch {};
    // TODO
    @panic("Panic was called with the following format message: " ++ msg);
}

pub const streams = .{
    std.io.AnyReader{ .readFn = readFn, .context = undefined },
    std.io.AnyWriter{ .writeFn = writeFn, .context = undefined },
    if (verbose_errors)
        std.io.AnyWriter{ .writeFn = writeFn, .context = undefined }
    else
        std.io.null_writer,
};

const std = @import("std");
const fmt = std.fmt;
// for debugging with zig test --test-filter, comment this import
const verbose_errors = @import("build_options").verbose_errors;

extern "js" fn log(msg_ptr: [*]const u8, msg_len: usize) void;
extern "js" fn promptIntoAddr(
    result_addr_ptr: *const [*]u8,
    result_len_ptr: *const usize,
) void;

// Allocator `len` bytes using the wasm allocator
export fn alloc(len: usize) [*]const u8 {
    var buff: [256]u8 = undefined;
    const str = fmt.bufPrint(&buff, "Alloc: {}\n", .{len}) catch unreachable;
    log(str.ptr, str.len);
    const slice = std.heap.wasm_allocator.alloc(u8, len) catch
        panic("Allocation of {} bytes failed", .{len});
    return slice.ptr;
}

export fn free(ptr: [*]const u8, len: usize) void {
    // const ptr: [*]usize = @ptrFromInt(ptr_num);
    std.heap.wasm_allocator.free(ptr[0..len]);
}

// TODO: add errors / return len
fn writeFn(ctx: *const anyopaque, bytes: []const u8) error{}!usize {
    _ = ctx;
    var buff: [256]u8 = undefined;
    const str = fmt.bufPrint(
        &buff,
        "Write {} bytes: {s}\n",
        .{ bytes.len, bytes },
    ) catch
        unreachable;
    log(str.ptr, str.len);
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

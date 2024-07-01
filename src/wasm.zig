const std = @import("std");
const fmt = std.fmt;
const io = std.io;
// for debugging with zig test --test-filter, comment this import
const verbose_errors = @import("build_options").verbose_errors;

extern "js" fn log(msg_ptr: [*]const u8, msg_len: usize) void;
extern "js" fn readInput(ptr: *[*]const u8, len: *usize) void;

// Allocator `len` bytes using the wasm allocator
export fn alloc(len: usize) [*]const u8 {
    const slice = std.heap.wasm_allocator.alloc(u8, len) catch
        panic("Allocation of {} bytes failed", .{len});
    bufDebug("Alloc {} bytes at {*}\n", .{ slice.len, slice.ptr });
    return slice.ptr;
}

export fn free(ptr: [*]const u8, len: usize) void {
    // const ptr: [*]usize = @ptrFromInt(ptr_num);
    std.heap.wasm_allocator.free(ptr[0..len]);
}

pub fn bufDebug(comptime fmt_str: []const u8, args: anytype) void {
    var buff: [256]u8 = undefined;
    const str = fmt.bufPrint(&buff, fmt_str, args) catch
        unreachable;
    log(str.ptr, str.len);
}

// TODO: add errors / return len
fn writeFn(ctx: *const anyopaque, bytes: []const u8) error{}!usize {
    _ = ctx;
    log(bytes.ptr, bytes.len);
    return bytes.len;
}

/// This is packed so it can be "returned" by a js function allocating its
/// fields and returning a pointer
const InputCtx = packed struct {
    ptr: [*]const u8,
    len: usize = 0,
    pos: usize = 0,
};

// TODO: match error sets and return errors correctly
fn readFn(ctx: *InputCtx, bytes: []u8) error{OutOfMemory}!usize {
    // Check if we finished reading and need new input from js
    if (!(ctx.pos < ctx.len)) {
        readInput(&ctx.ptr, &ctx.len);
        bufDebug("Read {} bytes at {*}\n", .{ ctx.len, ctx.ptr });
        ctx.pos = 0;
        // Avoid continously trying to read empty strings
        if (ctx.len == 0)
            return 0;
    }
    const slice = ctx.ptr[ctx.pos..bytes.len];
    bufDebug("Copy {} bytes at {*}\n", .{ slice.len, bytes.ptr });
    std.mem.copyForwards(u8, bytes, slice);
    ctx.pos += slice.len;
    return slice.len;
}

pub fn panic(comptime msg: []const u8, args: anytype) noreturn {
    streams.err.print(msg, args) catch {};
    // TODO
    @panic("Panic was called with the following format message: " ++ msg);
}

pub const Streams = struct {
    var input_ctx: InputCtx = .{ .ptr = undefined };
    in: io.GenericReader(*InputCtx, error{OutOfMemory}, readFn) = .{
        .context = &input_ctx,
    },
    out: io.AnyWriter = io.AnyWriter{
        .writeFn = writeFn,
        .context = undefined,
    },
    err: io.AnyWriter = if (verbose_errors)
        std.io.AnyWriter{
            .writeFn = writeFn,
            .context = undefined,
        }
    else
        std.io.null_writer,
};
pub const streams = Streams{};

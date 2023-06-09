///
/// Credit: Luukdegram, https://github.com/Luukdegram/luf
///
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = struct {
    /// The formatted message
    fmt: []const u8,
    /// type of the error: Error, Warning, Info
    kind: ErrorType,
    /// index of the token which caused the error
    index: usize,

    const ErrorType = enum {
        err,
        info,
        warn,
    };
};

pub const Errors = struct {
    /// internal list, containing all errors
    /// call deinit() on `Errors` to free its memory
    list: std.ArrayListUnmanaged(Error),
    /// Allocator used to allocPrint error messages
    allocator: Allocator,

    /// Creates a new Errors object that can be catch errors and print them out to a writer
    pub fn init(allocator: Allocator) Errors {
        return .{ .list = std.ArrayListUnmanaged(Error){}, .allocator = allocator };
    }

    /// Appends a new error to the error list
    pub fn add(self: *Errors, comptime fmt: []const u8, index: usize, kind: Error.ErrorType, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        errdefer self.allocator.free(msg);

        return self.list.append(self.allocator, .{
            .fmt = msg,
            .kind = kind,
            .index = index,
        });
    }

    /// Frees the memory of the errors
    pub fn deinit(self: *Errors) void {
        for (self.list.items) |err| {
            self.allocator.free(err.fmt);
        }
        self.list.deinit(self.allocator);
        self.* = undefined;
    }

    /// Consumes the errors and writes the errors to the writer interface
    /// source is required as we do not necessarily know the source when we init() `Errors`
    pub fn write(self: *Errors, source: []const u8, writer: anytype) !void {
        while (self.list.popOrNull()) |err| {
            defer self.allocator.free(err.fmt);
            const color_prefix = switch (err.kind) {
                .err => "\x1b[0;31m",
                .info => "\x1b[0;37m",
                .warn => "\x1b[0;36m",
            };
            try writer.print("{s}error: \x1b[0m{s}\n", .{ color_prefix, err.fmt });

            const start = findStart(source, err.index);
            const end = findEnd(source[err.index..]);

            //write the source code lines and point to token's index
            try writer.print("{s}\n", .{source[start .. err.index + end]});
            try writer.writeByteNTimes('~', err.index - start);
            try writer.writeAll("\x1b[0;35m^\n\x1b[0m");
        }
    }

    /// Finds the position of the first character of the token's index
    fn findStart(source: []const u8, index: usize) usize {
        var i = index;
        while (i != 0) : (i -= 1) if (source[i] == '\n') return i + 1;
        return 0;
    }

    /// finds the line ending in the given slice
    fn findEnd(slice: []const u8) usize {
        var count: usize = 0;
        for (slice, 0..) |c, i| count += if (c == '\n') return i else @as(usize, 1);
        return count;
    }
};

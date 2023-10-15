const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const util = @import("../util.zig");
const mem = std.mem;
const fsize = util.fsize();
const Order = math.Order;
const math = std.math;
const assert = std.debug.assert;
const Oom = Allocator.Error;
const Lexer = @import("Lexer.zig");
const Wyhash = std.hash.Wyhash;

/// Builtin Sifu types, values here correspond exactly to a type name in Sifu.
pub const Type = enum {
    Val,
    Str,
    Var,
    Infix,
    // Ints/UInts are be applied to a number which signifies their size
    I, // signed
    U, // unsigned
    F, // float
    Comment,
    NewLine, // New line separator

    /// Compares by value, not by len, pos, or pointers.
    pub fn order(self: Type, other: Type) Order {
        return math.order(@intFromEnum(self), @intFromEnum(other));
    }
};

// This isn't really used yet, but may be in the future
pub const Term = union(Type) {
    Val: []const u8,
    Var: []const u8,
    Infix: []const u8,
    Str: []const u8,
    I: isize,
    U: usize,
    F: fsize,
    Comment: []const u8,
};

/// Any source code word with with context, including vars.
pub fn Token(comptime Context: type) type {
    return struct {
        /// The string value of this token.
        lit: []const u8,

        /// The token type, to be used in patterns
        type: Type,

        /// `Context` is intended for optional debug/tooling information like
        /// `Location`.
        context: Context,

        pub const Self = @This();

        pub fn getHashData(self: Self) []const u8 {
            return self.lit;
        }

        /// Ignores Context.
        pub fn order(self: Self, other: Self) Order {
            // Doesn't use `Token.Type` because it depends entirely on the
            // literal anyways.
            return mem.order(u8, self.lit, other.lit);
        }

        pub fn hasherUpdate(self: Self, hasher: anytype) void {
            hasher.update(self.lit);
        }

        pub fn hash(self: Self) u32 {
            var hasher = Wyhash.init(0);
            // Don't need to use `Token.Type` because it depends entirely on the
            // literal anyways.
            self.hasherUpdate(&hasher);
            return @truncate(hasher.final());
        }

        /// Ignores Context.
        pub fn eql(self: Self, other: Self) bool {
            return mem.eql(u8, self.lit, other.lit);
        }

        /// Memory valid until this token is freed.
        // TODO: print all fields instead of just `lit`
        pub fn toString(self: Self) []const u8 {
            return self.lit;
        }

        pub fn write(self: Self, writer: anytype) !void {
            _ = try writer.write(self.lit);
        }

        /// Convert this to a term by parsing its literal value.
        pub fn parse(self: Self, allocator: Allocator) Oom!Term {
            _ = allocator;
            return switch (self.type) {
                .Val, .Str, .Var, .Comment => self.lit,
                .Infix => self.lit,
                .I => if (std.fmt.parseInt(usize, self.lit, 10)) |i|
                    i
                else |err| switch (err) {
                    // token should only have consumed digits
                    error.InvalidCharacter => unreachable,
                    // TODO: arbitrary ints here
                    error.Overflow => unreachable,
                },

                .U => if (std.fmt.parseUnsigned(usize, self.lit, 10)) |i|
                    i
                else |err| switch (err) {
                    error.InvalidCharacter => unreachable,
                    // TODO: arbitrary ints here
                    error.Overflow => unreachable,
                },
                .F => std.fmt.parseFloat(fsize, self.lit) catch
                    unreachable,
            };
        }
    };
}

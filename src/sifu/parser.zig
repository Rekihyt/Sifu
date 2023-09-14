/// The parser for Sifu tries to make as few decisions as possible. Mostly, it
/// greedily lexes seperators like commas into their own ast nodes, separates
/// vars and vals based on the first character's case, and lazily lexes non-
/// strings. There are no errors, any utf-8 text is parsable.
///
const Parser = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const panic = std.debug.panic;
const util = @import("../util.zig");
const fsize = util.fsize();
const Ast = @import("ast.zig").Ast;
const AstOf = @import("../ast.zig").Ast;
const syntax = @import("syntax.zig");
const Token = syntax.Token(usize);
const Term = syntax.Term;
const Type = syntax.Type;
const Set = util.Set;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const ArrayList = std.ArrayList;
const Oom = Allocator.Error;
const Order = std.math.Order;
const mem = std.mem;
const math = std.math;
const assert = std.debug.assert;
const debug = std.debug;

// TODO: add indentation tracking, and separate based on newlines+indent

fn parseLit(token: Token) Ast {
    const lit = token.lit;
    return if (mem.eql(u8, lit, "->")) {
        // The next pattern is the key in an App, followed by the val as args
        // parseApps(allocator, )
    } else if (mem.eql(u8, lit, "{")) {
        //
    } else if (mem.eql(u8, lit, "}")) {
        //
    } else Ast{
        .kind = switch (token.type) {
            .Var => .{ .@"var" = lit },
            else => .{ .lit = lit },
        },
    };
}

fn consumeNewLines(lexer: anytype, reader: anytype) !bool {
    var consumed: bool = false;
    // Parse all newlines
    while (try lexer.peek(reader)) |next_token|
        if (next_token.type == .NewLine) {
            _ = try lexer.next(reader);
            consumed = true;
        } else break;

    return consumed;
}

/// Parse a nonempty App if possible, returning null otherwise.
pub fn parse(allocator: Allocator, lexer: *Lexer, reader: anytype) !?Ast {
    var result = ArrayListUnmanaged(Ast){};
    _ = try parseUntil(allocator, lexer, reader, &result, null) orelse
        return null;

    // assert(result.items.len != 0); // returned null if so

    return Ast{ .apps = try result.toOwnedSlice(allocator) };
}

/// Parse until sep is encountered, or a newline. The `lexer` should be a
/// mutable instance of `Lexer()`.
///
/// Memory can be freed by using an arena allocator, or walking the tree and
/// freeing each app.
/// Returns:
/// - true if sep was found
/// - false if sep wasn't found, but something was parsed
/// - null if only whitespace was parsed
fn parseUntil(
    allocator: Allocator,
    lexer: *Lexer,
    reader: anytype,
    result: *ArrayListUnmanaged(Ast),
    sep: ?u8, // must be a greedily parsed, single char sep
) !?bool {
    _ = try lexer.peek(reader) orelse
        return null;

    return while (try lexer.next(reader)) |token| {
        const lit = token.lit;
        switch (token.type) {
            .NewLine => break '\n' == sep,
            // Vals always have at least one char
            .Val => if (lit[0] == sep)
                break true // ignore sep
            else switch (lit[0]) {
                // Separators are parsed greedily, so its impossible to
                // encounter any with more than one char (like "{}")
                '(' => {
                    var nested = ArrayListUnmanaged(Ast){};
                    // Try to parse a nested app
                    const matched =
                        try parseUntil(allocator, lexer, reader, &nested, ')');

                    try stderr.print("Matched: {?}\n", .{matched});
                    // if (!matched) // copy and free nested to result
                    // else
                    try result.append(
                        allocator,
                        Ast{ .apps = try nested.toOwnedSlice(allocator) },
                    );
                },
                else => try result.append(allocator, Ast.ofLit(token)),
            },
            // The current list becomes the first argument to the infix, then we
            // add any following asts to that
            .Infix => {
                var infix_apps = ArrayListUnmanaged(Ast){};
                try infix_apps.append(allocator, Ast.ofLit(token));
                try infix_apps.append(allocator, Ast{
                    .apps = try result.toOwnedSlice(allocator),
                });
                result.* = infix_apps;
            },
            else => try result.append(allocator, Ast.ofLit(token)),
        }
    } else false;
}

// This function is the responsibility of the Parser, because it is the dual
// to parsing.
// `AstOf` is just then Ast type function, but avoids a name collision.
pub fn print(ast: anytype, writer: anytype) !void {
    switch (ast) {
        .apps => |asts| if (asts.len > 0 and asts[0] == .key and
            asts[0].key.type == .Infix)
        {
            const key = asts[0].key;
            // An infix always forms an App with at least 2
            // nodes, the second of which must be an App (which
            // may be empty)
            assert(asts.len >= 2);
            assert(asts[1] == .apps);
            try writer.writeAll("(");
            try print(asts[1], writer);
            try writer.writeByte(' ');
            try writer.writeAll(key.lit);
            if (asts.len >= 2)
                for (asts[2..]) |arg| {
                    try writer.writeByte(' ');
                    try print(arg, writer);
                };
            try writer.writeAll(")");
        } else if (asts.len > 0) {
            try writer.writeAll("(");
            try print(asts[0], writer);
            for (asts[1..]) |it| {
                try writer.writeByte(' ');
                try print(it, writer);
            }
            try writer.writeAll(")");
        } else try writer.writeAll("()"),
        .key => |key| try writer.print("{s}", .{key.lit}),
        .@"var" => |v| try writer.print("{s}", .{v}),
        .pattern => |pat| try pat.print(writer),
    }
}

const testing = std.testing;
const expectEqualStrings = testing.expectEqualStrings;
const meta = std.meta;
const fs = std.fs;
const io = std.io;
const Lexer = @import("Lexer.zig");

// for debugging with zig test --test-filter, comment this import
const verbose_tests = @import("build_options").verbose_tests;
// const stderr = if (false)
const stderr = if (verbose_tests)
    std.io.getStdErr().writer()
else
    std.io.null_writer;

test "simple val" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var fbs = io.fixedBufferStream("Asdf");
    var lexer = Lexer.init(arena.allocator());
    const ast = try parse(arena.allocator(), &lexer, fbs.reader());
    try testing.expectEqualStrings(ast.?.apps[0].key.lit, "Asdf");
}

fn testStrParse(str: []const u8, expecteds: []const Ast) !void {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var lexer = Lexer.init(allocator);
    var fbs = io.fixedBufferStream(str);
    const reader = fbs.reader();
    for (expecteds) |expected| {
        const actual = try parse(allocator, &lexer, reader);
        try expectEqualApps(expected, actual.?);
    }
}

fn expectEqualApps(expected: Ast, actual: Ast) !void {
    try stderr.writeByte('\n');
    try stderr.writeAll("expected: ");
    try print(expected, stderr);
    try stderr.writeByte('\n');

    try stderr.writeAll("actual: ");
    try print(actual, stderr);
    try stderr.writeByte('\n');

    try testing.expect(.apps == expected);
    try testing.expect(.apps == actual);
    try testing.expectEqual(expected.apps.len, actual.apps.len);

    // This is redundant, but it makes any failures easier to trace
    for (expected.apps, actual.apps) |expected_elem, actual_elem| {
        if (@intFromEnum(expected_elem) == @intFromEnum(actual_elem)) {
            switch (expected_elem) {
                .key => |key| {
                    try testing.expectEqual(
                        @as(Order, .eq),
                        key.order(actual_elem.key),
                    );
                    try testing.expectEqualDeep(
                        key.lit,
                        actual_elem.key.lit,
                    );
                },
                .@"var" => |v| try expectEqualStrings(v, actual_elem.@"var"),
                .apps => try expectEqualApps(expected_elem, actual_elem),
                .pattern => |pat| try testing.expectEqual(
                    pat,
                    actual_elem.pattern,
                ),
            }
        } else {
            try stderr.writeAll("Asts of different types not equal");
            try testing.expectEqual(expected_elem, actual_elem);
            // above line should always fail
            debug.panic(
                "Asserted asts were equal despite different types",
                .{},
            );
        }
    }
    // Variants of this seem to cause the compiler to error with GenericPoison
    // try testing.expectEqual(@as(Order, .eq), expected.order(actual));
    // try testing.expect(.eq == expected.order(actual));
}

test "All Asts" {
    const input =
        \\Val1,5;
        \\var1.
        \\Infix -->
        \\5 < 10.V
        \\1 + 2.0
        \\$strat
        \\
        \\10 == 10
        \\10 != 9
        \\"foo".len
        \\[1, 2]
        \\{"key":1}
        \\// a comment
        \\||
        \\()
    ;
    const expecteds = &[_]Ast{
        Ast{ .apps = &.{
            .{ .key = .{
                .type = .Val,
                .lit = "Val1",
                .context = 0,
            } },
            .{ .key = .{
                .type = .Val,
                .lit = ",",
                .context = 4,
            } },
            .{ .key = .{
                .type = .I,
                .lit = "5",
                .context = 5,
            } },
            .{ .key = .{
                .type = .Val,
                .lit = ";",
                .context = 6,
            } },
        } },
    };
    try testStrParse(input[0..7], expecteds);
    // try expectEqualApps(expected, expected); // test the test function
}

test "App: simple vals" {
    const expecteds = &[_]Ast{
        Ast{ .apps = &.{
            Ast{ .key = .{
                .type = .Val,
                .lit = "Aa",
                .context = 0,
            } },
            Ast{ .key = .{
                .type = .Val,
                .lit = "Bb",
                .context = 3,
            } },
            Ast{ .key = .{
                .type = .Val,
                .lit = "Cc",
                .context = 6,
            } },
        } },
    };
    try testStrParse("Aa Bb Cc", expecteds);
}

test "App: simple op" {
    const expecteds = &[_]Ast{
        Ast{ .apps = &.{
            Ast{
                .key = .{
                    .type = .Infix,
                    .lit = "+",
                    .context = 2,
                },
            },
            Ast{ .apps = &.{
                Ast{
                    .key = .{
                        .type = .I,
                        .lit = "1",
                        .context = 0,
                    },
                },
            } },
            Ast{
                .key = .{
                    .type = .I,
                    .lit = "2",
                    .context = 4,
                },
            },
        } },
    };
    try testStrParse("1 + 2", expecteds);
}

test "App: simple ops" {
    const expecteds = &[_]Ast{
        Ast{ .apps = &.{
            Ast{ .key = .{
                .type = .Infix,
                .lit = "+",
                .context = 6,
            } },
            Ast{ .apps = &.{
                Ast{ .key = .{
                    .type = .Infix,
                    .lit = "+",
                    .context = 2,
                } },
                Ast{ .apps = &.{
                    Ast{ .key = .{
                        .type = .I,
                        .lit = "1",
                        .context = 0,
                    } },
                } },
                Ast{ .key = .{
                    .type = .I,
                    .lit = "2",
                    .context = 4,
                } },
            } },
            Ast{ .key = .{
                .type = .I,
                .lit = "3",
                .context = 8,
            } },
        } },
    };
    try testStrParse("1 + 2 + 3", expecteds);
}

test "App: simple op, no first arg" {
    const expecteds = &[_]Ast{
        Ast{ .apps = &.{
            Ast{
                .key = .{
                    .type = .Infix,
                    .lit = "+",
                    .context = 2,
                },
            },
            Ast{ .apps = &.{} },
            Ast{
                .key = .{
                    .type = .I,
                    .lit = "2",
                    .context = 4,
                },
            },
        } },
    };
    try testStrParse("+ 2", expecteds);
}

test "App: simple op, no second arg" {
    const expecteds = &[_]Ast{
        Ast{ .apps = &.{
            Ast{
                .key = .{
                    .type = .Infix,
                    .lit = "+",
                    .context = 2,
                },
            },
            Ast{ .apps = &.{
                Ast{ .key = .{
                    .type = .I,
                    .lit = "1",
                    .context = 0,
                } },
            } },
        } },
    };
    try testStrParse("1 +", expecteds);
}

test "App: simple parens" {
    const expected = Ast{ .apps = &.{
        Ast{ .apps = &.{} },
        Ast{ .apps = &.{} },
        Ast{ .apps = &.{
            Ast{ .apps = &.{} },
        } },
    } };
    try testStrParse("()() (())", &.{expected});
}

test "App: empty" {
    try testStrParse("   \n\n \n  \n\n\n", &.{});
}

test "App: nested parens 1" {
    const expecteds = &[_]Ast{
        Ast{ .apps = &.{
            Ast{ .apps = &.{} },
        } },
        Ast{ .apps = &.{
            Ast{ .apps = &.{} },
            Ast{ .apps = &.{} },
            Ast{ .apps = &.{
                Ast{ .apps = &.{} },
            } },
        } },
        // Ast{ .apps = &.{
        //     Ast{ .apps = &.{
        //         Ast{ .apps = &.{
        //             Ast{ .apps = &.{} },
        //             Ast{ .apps = &.{} },
        //         } },
        //         Ast{ .apps = &.{} },
        //     } },
        // } },
        // Ast{ .apps = &.{
        //     Ast{ .apps = &.{
        //         Ast{ .apps = &.{} },
        //         Ast{ .apps = &.{
        //             Ast{ .apps = &.{} },
        //         } },
        //     } },
        //     Ast{ .apps = &.{} },
        // } },
    };
    try testStrParse(
        \\ ()
        \\ () () ( () )
        // \\(
        // \\  (
        // \\    () ()
        // \\  )
        // \\  ()
        // \\)
        // \\ ( () ( ()) )( )
    , expecteds);
}

test "App: simple newlines" {
    const expecteds = &[_]Ast{
        Ast{ .apps = &.{
            Ast{ .key = .{
                .type = .Val,
                .lit = "Foo",
                .context = 0,
            } },
        } },
        Ast{ .apps = &.{
            Ast{ .key = .{
                .type = .Val,
                .lit = "Bar",
                .context = 0,
            } },
        } },
    };
    try testStrParse(
        \\ Foo
        \\ Bar
    , expecteds);
}

test "Apps: pattern" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var lexer = Lexer.init(allocator);
    var fbs = io.fixedBufferStream("{1,2,3}");

    const ast = try parse(allocator, &lexer, fbs.reader());
    _ = ast;
    // try testing.expectEqualStrings(ast.?.apps[0].pattern, "Asdf");
}

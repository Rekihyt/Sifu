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
const Ast = @import("ast.zig").Ast(Token);
const syntax = @import("syntax.zig");
const Token = syntax.Token(Location);
const Location = syntax.Location;
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
const Lexer = @import("lexer.zig");

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

fn consumeNewLines(allocator: Allocator, lexer: *Lexer) !bool {
    var consumed: bool = false;
    // Parse all newlines
    while (try lexer.peek(allocator)) |next_token|
        if (next_token.type == .NewLine) {
            _ = try lexer.next(allocator);
            consumed = true;
        } else break;

    return consumed;
}

/// Parse a nonempty App if possible, returning null otherwise.
pub fn parse(allocator: Allocator, lexer: *Lexer) !?Ast {
    var result = ArrayListUnmanaged(Ast){};
    _ = try parseUntil(allocator, lexer, &result, null) orelse
        return null;

    assert(result.items.len != 0); // returned null if so

    return Ast{ .apps = try result.toOwnedSlice(allocator) };
}

// TODO: convert this file to parse directly into patterns, not Asts

/// Parse until sep is encountered, or a double newline.
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
    result: *ArrayListUnmanaged(Ast),
    sep: ?u8, // must be a greedily parsed, single char sep
) !?bool {
    _ = try lexer.peek(allocator) orelse
        return null;

    const len = result.*.items.len;
    return while (try lexer.next(allocator)) |token| {
        const lit = token.lit;
        switch (token.type) {
            .NewLine => if (try consumeNewLines(allocator, lexer))
                // Double (or more) line break, stop parsing, and check if
                // anything was parsed by comparing lengths
                break if (result.*.items.len == len)
                    null
                else
                    sep == null,

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
                        try parseUntil(allocator, lexer, &nested, ')');

                    try stderr.print("Matched: {?}\n", .{matched});
                    // if (!matched) // copy and free nested to result
                    // else
                    try result.append(
                        allocator,
                        Ast{ .apps = try nested.toOwnedSlice(allocator) },
                    );
                },
                else => try result.append(allocator, Ast.of(token)),
            },
            // The current list becomes the first argument to the infix, then we
            // add any following asts to that
            .Infix => {
                var infix_apps = ArrayListUnmanaged(Ast){};
                try infix_apps.append(allocator, Ast.of(token));
                try infix_apps.append(allocator, Ast{
                    .apps = try result.toOwnedSlice(allocator),
                });
                result.* = infix_apps;
            },
            else => try result.append(allocator, Ast.of(token)),
        }
    } else false;
}

// This function is the responsibility of the Parser, because it is the dual
// to parsing.
pub fn print(self: anytype, writer: anytype) !void {
    switch (self) {
        .apps => |asts| if (asts.len > 0 and asts[0] == .token and
            asts[0].token.type == .Infix)
        {
            const token = asts[0].token;
            // An infix always forms an App with at least 2
            // nodes, the second of which must be an App (which
            // may be empty)
            assert(asts.len >= 2);
            assert(asts[1] == .apps);
            try writer.writeAll("(");
            try print(asts[1], writer);
            try writer.writeByte(' ');
            try writer.writeAll(token.lit);
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
        .token => |token| try writer.print("{s}", .{token.lit}),
        .@"var" => |v| try writer.print("{s}", .{v}),
        .pattern => |pat| try writer.print("{?}", .{pat}),
    }
}

const testing = std.testing;
const expectEqualStrings = testing.expectEqualStrings;
const meta = std.meta;

// for debugging with zig test --test-filter, comment this import
const verbose_tests = @import("build_options").verbose_tests;
const stderr = if (false)
    // const stderr = if (verbose_tests)
    std.io.getStdErr().writer()
else
    std.io.null_writer;

test "simple val" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lexer = Lexer.init("Asdf");
    const ast = try parse(arena.allocator(), &lexer);
    try testing.expectEqualStrings(ast.?.apps[0].token.lit, "Asdf");
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
                .token => |token| {
                    try testing.expectEqual(
                        @as(Order, .eq),
                        token.order(actual_elem.token),
                    );
                    try testing.expectEqualDeep(
                        token.lit,
                        actual_elem.token.lit,
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
            .{ .token = .{
                .type = .Val,
                .lit = "Val1",
                .context = .{ .pos = 0, .uri = null },
            } },
            .{ .token = .{
                .type = .Val,
                .lit = ",",
                .context = .{ .pos = 4, .uri = null },
            } },
            .{ .token = .{
                .type = .I,
                .lit = "5",
                .context = .{ .pos = 5, .uri = null },
            } },
            .{ .token = .{
                .type = .Val,
                .lit = ";",
                .context = .{ .pos = 6, .uri = null },
            } },
        } },
    };
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // TODO: test full input string
    var lexer = Lexer.init(input[0..7]);

    // try expectEqualApps(expected, expected); // test the test function
    for (expecteds) |expected| {
        const actual = try parse(arena.allocator(), &lexer);
        try expectEqualApps(expected, actual.?);
    }
}

test "App: simple vals" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("Aa Bb Cc");
    const expecteds = &[_]Ast{
        Ast{ .apps = &.{
            Ast{ .token = .{
                .type = .Val,
                .lit = "Aa",
                .context = .{ .pos = 0, .uri = null },
            } },
            Ast{ .token = .{
                .type = .Val,
                .lit = "Bb",
                .context = .{ .pos = 3, .uri = null },
            } },
            Ast{ .token = .{
                .type = .Val,
                .lit = "Cc",
                .context = .{ .pos = 6, .uri = null },
            } },
        } },
    };
    for (expecteds) |expected| {
        const actual = try parse(arena.allocator(), &lexer);
        try expectEqualApps(expected, actual.?);
    }
}

test "App: simple op" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("1 + 2");
    const expecteds = &[_]Ast{
        Ast{ .apps = &.{
            Ast{
                .token = .{
                    .type = .Infix,
                    .lit = "+",
                    .context = .{ .pos = 2, .uri = null },
                },
            },
            Ast{ .apps = &.{
                Ast{
                    .token = .{
                        .type = .I,
                        .lit = "1",
                        .context = .{ .pos = 0, .uri = null },
                    },
                },
            } },
            Ast{
                .token = .{
                    .type = .I,
                    .lit = "2",
                    .context = .{ .pos = 4, .uri = null },
                },
            },
        } },
    };
    for (expecteds) |expected| {
        const actual = try parse(arena.allocator(), &lexer);
        try expectEqualApps(expected, actual.?);
    }
}

test "App: simple ops" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("1 + 2 + 3");
    const expecteds = &[_]Ast{
        Ast{ .apps = &.{
            Ast{ .token = .{
                .type = .Infix,
                .lit = "+",
                .context = .{ .pos = 6, .uri = null },
            } },
            Ast{ .apps = &.{
                Ast{ .token = .{
                    .type = .Infix,
                    .lit = "+",
                    .context = .{ .pos = 2, .uri = null },
                } },
                Ast{ .apps = &.{
                    Ast{ .token = .{
                        .type = .I,
                        .lit = "1",
                        .context = .{ .pos = 0, .uri = null },
                    } },
                } },
                Ast{ .token = .{
                    .type = .I,
                    .lit = "2",
                    .context = .{ .pos = 4, .uri = null },
                } },
            } },
            Ast{ .token = .{
                .type = .I,
                .lit = "3",
                .context = .{ .pos = 8, .uri = null },
            } },
        } },
    };
    for (expecteds) |expected| {
        const actual = try parse(arena.allocator(), &lexer);
        try expectEqualApps(expected, actual.?);
    }
}

test "App: simple op, no first arg" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lexer = Lexer.init("+ 2");
    const expecteds = &[_]Ast{
        Ast{ .apps = &.{
            Ast{
                .token = .{
                    .type = .Infix,
                    .lit = "+",
                    .context = .{ .pos = 2, .uri = null },
                },
            },
            Ast{ .apps = &.{} },
            Ast{
                .token = .{
                    .type = .I,
                    .lit = "2",
                    .context = .{ .pos = 4, .uri = null },
                },
            },
        } },
    };
    for (expecteds) |expected| {
        const actual = try parse(arena.allocator(), &lexer);
        try expectEqualApps(expected, actual.?);
    }
}

test "App: simple op, no second arg" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lexer = Lexer.init("1 +");
    const expecteds = &[_]Ast{
        Ast{ .apps = &.{
            Ast{
                .token = .{
                    .type = .Infix,
                    .lit = "+",
                    .context = .{ .pos = 2, .uri = null },
                },
            },
            Ast{ .apps = &.{
                Ast{ .token = .{
                    .type = .I,
                    .lit = "1",
                    .context = .{ .pos = 0, .uri = null },
                } },
            } },
        } },
    };
    for (expecteds) |expected| {
        const actual = try parse(arena.allocator(), &lexer);
        try expectEqualApps(expected, actual.?);
    }
}

test "App: simple parens" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lexer = Lexer.init("()() (())");
    const expected = Ast{ .apps = &.{
        Ast{ .apps = &.{} },
        Ast{ .apps = &.{} },
        Ast{ .apps = &.{
            Ast{ .apps = &.{} },
        } },
    } };
    const actual = try parse(arena.allocator(), &lexer);
    try expectEqualApps(expected, actual.?);
}

test "App: empty" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lexer = Lexer.init("   \n\n \n  \n\n\n");
    const actual = try parse(arena.allocator(), &lexer);
    try testing.expectEqual(@as(?Ast, null), actual);
}

test "App: nested parens 1" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lexer = Lexer.init(
        \\ ()
        \\
        \\ () () ( () )
        \\
        \\(
        \\  (
        \\    () ()
        \\  )
        \\  ()
        \\)
        \\
        \\ ( () ( ()) )( )
    );
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
        Ast{ .apps = &.{
            Ast{ .apps = &.{
                Ast{ .apps = &.{
                    Ast{ .apps = &.{} },
                    Ast{ .apps = &.{} },
                } },
                Ast{ .apps = &.{} },
            } },
        } },
        Ast{ .apps = &.{
            Ast{ .apps = &.{
                Ast{ .apps = &.{} },
                Ast{ .apps = &.{
                    Ast{ .apps = &.{} },
                } },
            } },
            Ast{ .apps = &.{} },
        } },
    };
    for (expecteds) |expected| {
        const actual = try parse(arena.allocator(), &lexer);
        try expectEqualApps(expected, actual.?);
    }
}

test "App: simple newlines" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lexer = Lexer.init(
        \\ Foo
        \\
        \\ Bar
    );
    const expecteds = &[_]Ast{
        Ast{ .apps = &.{
            Ast{ .token = .{
                .type = .Val,
                .lit = "Foo",
                .context = .{ .pos = 0, .uri = null },
            } },
        } },
        Ast{ .apps = &.{
            Ast{ .token = .{
                .type = .Val,
                .lit = "Bar",
                .context = .{ .pos = 0, .uri = null },
            } },
        } },
    };
    for (expecteds) |expected| {
        const actual = try parse(arena.allocator(), &lexer);
        try expectEqualApps(expected, actual.?);
    }
}

test "Apps: pattern" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lexer = Lexer.init("{1,2,3}");
    const ast = try parse(arena.allocator(), &lexer);
    _ = ast;
    // try testing.expectEqualStrings(ast.?.apps[0].pattern, "Asdf");
}

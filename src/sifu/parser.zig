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
const Pat = @import("ast.zig").Pat;
const Ast = Pat.Node;
const Pattern = @import("../pattern.zig").Pattern;
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
pub fn parse(allocator: Allocator, lexer: anytype) !?[]Ast {
    var found_sep: bool = undefined;
    var result = try parseUntil(
        allocator,
        lexer,
        &found_sep,
        null,
    );

    // try stderr.print("New app ptr: {*}, len: {}\n", .{ apps.ptr, apps.len });
    return result;
}

/// Parse until terminal is encountered, or a newline. A null terminal will
/// parse until eof.
///
/// Memory can be freed by using an arena allocator, or walking the tree and
/// freeing each app. Does not allocate on errors or empty parses.
/// Returns:
/// - true if terminal was found
/// - false if terminal wasn't found, but something was parsed
/// - null if no tokens were parsed
fn parseUntil(
    allocator: Allocator,
    lexer: anytype,
    found_sep: *bool,
    terminal: ?u8, // must be a greedily parsed, single char terminal
) ![]Ast {
    _ = try lexer.peek() orelse
        return &.{};

    // Track the last comma, kind of like an open bracket
    var comma_index: usize = 0;
    // Many patterns will be leaves, so it makes sense to assume an app
    // of size 1. ArrayList's `append` function will allocate space for
    // an extra 10, which this avoids
    var result = try ArrayListUnmanaged(Ast).initCapacity(allocator, 1);
    found_sep.* = while (try lexer.next()) |token| {
        const lit = token.lit;
        switch (token.type) {
            .NewLine => break '\n' == terminal,
            // Vals always have at least one char
            .Val => if (lit[0] == terminal)
                break true, // ignore terminal
            else => {},
        }
        switch (token.type) {
            .Val => switch (lit[0]) {
                // Terminals are parsed greedily, so its impossible to
                // encounter any with more than one char (like "{}")
                '(' => {
                    var matched: bool = undefined;
                    // Try to parse a nested app
                    var nested =
                        try parseUntil(allocator, lexer, &matched, ')');

                    try stderr.print("Nested App: {?}\n", .{matched});
                    // if (!matched) // TODO: copy and free nested to result
                    // else
                    try result.append(
                        allocator,
                        if (matched)
                            Ast.ofApps(nested)
                        else
                            // If null, no matching paren was found so parse '('
                            // as a literal
                            Ast.ofLit(token),
                    );
                },
                '{' => {
                    var pat = Pat{};
                    var matched: bool = undefined;
                    // Try to parse a nested app
                    var nested =
                        try parseUntil(allocator, lexer, &matched, '}');

                    // if (!matched) // TODO: check if matched brace was found

                    // TODO: fix parsing nested patterns with comma seperators
                    // TODO: optimize by removing the delete
                    defer {
                        for (nested) |*app| app.deleteChildren(allocator);
                        allocator.free(nested);
                    }
                    try stderr.print("Nested Pat: {?}\n", .{matched});
                    // _ = if (nested.len > 0 and nested[0] == .key) {
                    // Parse match expr
                    // if (mem.eql(u8, nested[0].key.lit, ":"))
                    //     try pat.insert(
                    //         allocator,
                    //         // Infix ops always have an apps appended
                    //         nested[1].apps,
                    //         // Preserve semantic difference between a
                    //         // non-match and a match with an empty app as
                    //         // value.
                    //         if (nested.len >= 2)
                    //             Ast{ .apps = nested[2..] }
                    //         else
                    //             null,
                    //     )
                    // else // Parse rewrite expr
                    // if (mem.eql(u8, nested[0].key.lit, "->"))
                    //     try pat.insert(
                    //         allocator,
                    //         // Infix ops always have an apps appended
                    //         nested[1].apps,
                    //         // Preserve semantic difference between a
                    //         // non-match and a match with an empty app as
                    //         // value.
                    //         if (nested.len >= 2)
                    //             Ast{ .apps = nested[2..] }
                    //         else
                    //             null,
                    //     );
                    _ = try pat.insert(allocator, nested, null);
                    try result.append(allocator, try Ast.ofPattern(allocator, pat));
                },
                ',' => {
                    var left_args = ArrayListUnmanaged(Ast){};
                    // Copy the previous apps starting from the last comma until
                    // this one and add them as a single app to result.
                    for (result.items[comma_index..]) |app| {
                        try left_args.append(allocator, app);
                    }
                    result.shrinkRetainingCapacity(comma_index);
                    comma_index += 1;
                    try result.append(allocator, Ast{
                        .apps = try left_args.toOwnedSlice(allocator),
                    });
                },
                else => try result.append(allocator, Ast.ofLit(token)),
            },
            // The current list becomes the first argument to the infix, then we
            // add any following asts to that
            // TODO: special case commas for lists to use arrays under the hood
            .Infix => {
                var left_args = ArrayListUnmanaged(Ast){};
                for (result.items[comma_index..]) |app| {
                    try left_args.append(allocator, app);
                }
                result.shrinkRetainingCapacity(comma_index);
                const left_args_slice = try left_args.toOwnedSlice(allocator);
                if (mem.eql(u8, lit, ":")) {
                    try result.append(allocator, Ast{
                        .match = left_args_slice,
                    });
                } else if (mem.eql(u8, lit, "->")) {
                    try result.append(allocator, Ast{
                        .arrow = left_args_slice,
                    });
                } else {
                    try result.appendSlice(allocator, &.{
                        Ast.ofLit(token),
                        Ast{ .apps = left_args_slice },
                    });
                }
            },
            .Var => try result.append(allocator, Ast.ofVar(token)),
            .Str, .I, .F, .U => try result.append(allocator, Ast.ofLit(token)),
            .Comment, .NewLine => try result.append(allocator, Ast.ofLit(token)),
        }
    } else false;
    return try result.toOwnedSlice(allocator);
}

// This function is the responsibility of the Parser, because it is the dual
// to parsing.
// pub fn print(ast: anytype, writer: anytype) !void {
//     switch (ast) {
//         .apps => |asts| if (asts.len > 0 and asts[0] == .key and
//             asts[0].key.type == .Infix)
//         {
//             const key = asts[0].key;
//             // An infix always forms an App with at least 2
//             // nodes, the second of which must be an App (which
//             // may be empty)
//             assert(asts.len >= 2);
//             assert(asts[1] == .apps);
//             try writer.writeAll("(");
//             try print(asts[1], writer);
//             try writer.writeByte(' ');
//             try writer.writeAll(key.lit);
//             if (asts.len >= 2)
//                 for (asts[2..]) |arg| {
//                     try writer.writeByte(' ');
//                     try print(arg, writer);
//                 };
//             try writer.writeAll(")");
//         } else if (asts.len > 0) {
//             try writer.writeAll("(");
//             try print(asts[0], writer);
//             for (asts[1..]) |it| {
//                 try writer.writeByte(' ');
//                 try print(it, writer);
//             }
//             try writer.writeAll(")");
//         } else try writer.writeAll("()"),
//         .key => |key| try writer.print("{s}", .{key.lit}),
//         .variable => |v| try writer.print("{s}", .{v}),
//         .pat => |pat| try pat.print(writer),
//     }
// }

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
    try stderr.writeAll("Expected: ");
    try expected.write(stderr);
    try stderr.writeByte('\n');

    try stderr.writeAll("Actual: ");
    try actual.write(stderr);
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
                .variable => |v| try testing.expect(v.eql(actual_elem.variable)),
                .apps => try expectEqualApps(expected_elem, actual_elem),
                .pat => |pat| try testing.expect(pat.eql(actual_elem.pat.*)),
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

test "Apps: pattern eql hash" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var lexer1 = Lexer.init(allocator);
    var lexer2 = Lexer.init(allocator);
    var lexer3 = Lexer.init(allocator);
    var fbs1 = io.fixedBufferStream("{1,{2},3  -> A}");
    var fbs2 = io.fixedBufferStream("{1, {2}, 3 -> A}");
    var fbs3 = io.fixedBufferStream("{1, {2}, 3 -> B}");

    const ast1 = (try parse(allocator, &lexer1, fbs1.reader())).?;
    const ast2 = (try parse(allocator, &lexer2, fbs2.reader())).?;
    const ast3 = (try parse(allocator, &lexer3, fbs3.reader())).?;
    // try testing.expectEqualStrings(ast.?.apps[0].pat, "Asdf");
    try testing.expect(ast1.eql(ast2));
    try testing.expectEqual(ast1.hash(), ast2.hash());
    try testing.expect(!ast1.eql(ast3));
    try testing.expect(!ast2.eql(ast3));
    try testing.expect(ast1.hash() != ast3.hash());
    try testing.expect(ast2.hash() != ast3.hash());
}

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
const meta = std.meta;
const last = util.last;

// TODO: add indentation tracking, and separate based on newlines+indent

/// Convert this token to a term by parsing its literal value.
pub fn parseTerm(term: Token) Oom!Term {
    return switch (term.type) {
        .Name, .Str, .Var, .Comment => term.lit,
        .Infix => term.lit,
        .I => if (std.fmt.parseInt(usize, term.lit, 10)) |i|
            i
        else |err| switch (err) {
            // token should only have consumed digits
            error.InvalidCharacter => unreachable,
            // TODO: arbitrary ints here
            error.Overflow => unreachable,
        },

        .U => if (std.fmt.parseUnsigned(usize, term.lit, 10)) |i|
            i
        else |err| switch (err) {
            error.InvalidCharacter => unreachable,
            // TODO: arbitrary ints here
            error.Overflow => unreachable,
        },
        .F => std.fmt.parseFloat(fsize, term.lit) catch
            unreachable,
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

const ParseError = error{
    NoLeftBrace,
    NoRightBrace,
    NoLeftParen,
    NoRightParen,
};

pub fn parsePattern(
    allocator: Allocator,
    lexer: anytype,
) (ParseError || @TypeOf(lexer).Error || Allocator.Error)!Ast {
    _ = allocator;
}

pub fn parseNestedApps(
    allocator: Allocator,
    lexer: anytype,
) (ParseError || @TypeOf(lexer.*).Error || Allocator.Error)!Ast {
    if (try lexer.next()) |l_brace|
        if (l_brace.type == .Name and l_brace.lit[0] == '(')
            return error.NoLeftBrace;

    var result = try parseAst(allocator, lexer);
    errdefer result.delete(allocator);
    if (try lexer.next()) |r_brace|
        if (r_brace.type == .Name and r_brace.lit[0] == ')')
            return error.NoRightBrace;

    return result;
}

pub fn parseNestedPattern(
    allocator: Allocator,
    lexer: anytype,
) (ParseError || @TypeOf(lexer.*).Error || Allocator.Error)!Ast {
    if (try lexer.next()) |l_brace|
        if (l_brace.type == .Name and l_brace.lit[0] == '{')
            return error.NoLeftBrace;

    var result = try parseAst(allocator, lexer);
    // TODO: insert / eval
    errdefer result.delete(allocator);
    if (try lexer.next()) |r_brace|
        if (r_brace.type == .Name and r_brace.lit[0] == '}')
            return error.NoRightBrace;

    return result;
}

/// Parse until terminal is encountered, or a newline. A null terminal will
/// parse until eof.
///
/// Memory can be freed by using an arena allocator, or walking the tree and
/// freeing each app. Does not allocate on errors or empty parses.
/// Returns: an Ast, which may be anything but a Term.
// Parse algorithm tracks 4 levels of precedence. Everything is an array, so
// lower precedence can be expressed as the prefix of the apps that isn't added
// as an argument to the higher precedence operator. For example, in `1 -> 2 +
// 3`, when `+` is parsed `Arrow (1) 2` is on the stack. The prefix of length 1
// (`Arrow (1)`) has lower precedence than infix, so only anything after it (in
// this case `2`) is added as the first argument to `+`, resulting in `Arrow (1)
// + () 3`.
// Precedence: long arrow < long match < commas < infix < arrow < match
// - TODO: [] should be a flat Apps instead of as an infix
pub fn parseAst(
    allocator: Allocator,
    lexer: anytype,
) (ParseError || @TypeOf(lexer.*).Error)!Ast {
    var result: Ast = undefined;
    var current = ArrayListUnmanaged(Ast){};
    // This pointer tracks where to put `current` after converting it to an
    // owned slice.
    // Undefined because we cannot point to result's apps until it has been
    // allocated for the final time
    var current_dest: *Ast = &result;
    errdefer { // TODO: add test coverage
        // Check if result was written to, and therefore would need freeing
        if (&result != current_dest)
            result.deleteChildren(allocator);

        for (current.items) |*ast|
            ast.deleteChildren(allocator);

        current.deinit(allocator);
    }
    while (try lexer.peek()) |token| {
        const lit = token.lit;
        // Names always have at least one char
        // Terminals are parsed greedily, so its impossible to encounter any
        // with more than one char (like "{}")
        switch (token.lit[0]) {
            '(' => try current.append(
                allocator,
                try parseNestedApps(allocator, lexer),
            ),
            '{' => try current.append(
                allocator,
                try parseNestedPattern(allocator, lexer),
            ),
            else => {},
        }
        switch (token.lit[0]) {
            '(', '{' => continue, // Move to next token
            ')', '}' => break, // ignore terminals
            else => {},
        }
        // Newlines separate unless preceded by an op
        // .NewLine => switch (current) {
        //     .infix, .arrow, .match => break,
        //     else => {},
        // },
        try current.append(allocator, switch (token.type) {
            .Name => Ast.ofLit(token),
            .Infix => {
                if (mem.eql(u8, lit, ":") or mem.eql(u8, lit, "::")) {
                    @panic("unimplemented");
                    // TODO: parse right args and lookup their
                    // match_op.* = Ast.Match{ .query = args };
                } else if (mem.eql(u8, lit, "-->") or mem.eql(u8, lit, "==>")) {
                    @panic("unimplemented");
                } else if (mem.eql(u8, lit, "->") or mem.eql(u8, lit, "=>")) {
                    @panic("unimplemented");
                } else {
                    // Add the operator, the right args as and app, and
                    // finally the left args.
                    try current.appendSlice(allocator, &.{
                        Ast.ofLit(token),
                        Ast.ofApps(undefined),
                    });
                    // Store the old current
                    current_dest.* = Ast{
                        .infix = try current.toOwnedSlice(allocator),
                    };
                    // We can track this pointer because the previous arraylist
                    // (op and left args) will no longer be resized
                    current_dest = @constCast(&last(current_dest.apps));
                }
                current = ArrayListUnmanaged(Ast){};
                continue; // No need to append anything
            },
            .Var => Ast.ofVar(token.lit),
            .Str, .I, .F, .U => Ast.ofLit(token),
            .Comment, .NewLine => Ast.ofLit(token),
        });
    }
    current_dest.* = Ast.ofApps(try current.toOwnedSlice(allocator));
    return result;
}
// This function is the responsibility of the Parser, because it is the dual
// to parsing.
// pub fn print(ast: anytype, writer: anytype) !void {
//     switch (ast) {
//         .apps => |asts| if (asts.len > 0 and asts[0] == .key and
//             asts[0].key.type == .Infix)
//         {
//             const key = asts[0].key;
//             // An infix always forms an App with at least
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
const fs = std.fs;
const io = std.io;
const Lexer = @import("Lexer.zig")
    .Lexer(io.FixedBufferStream([]const u8).Reader);
const List = ArrayListUnmanaged(Ast);

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
    var lexer = Lexer.init(arena.allocator(), fbs.reader());
    const ast = try parseAst(arena.allocator(), &lexer);
    try testing.expect(ast == .apps and ast.apps.len == 1);
    try testing.expectEqualStrings(ast.apps[0].key.lit, "Asdf");
}

fn testStrParse(str: []const u8, expecteds: []const Ast) !void {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fbs = io.fixedBufferStream(str);
    var lexer = Lexer.init(allocator, fbs.reader());
    const actuals = try parseAst(allocator, &lexer);
    for (expecteds, actuals.apps) |expected, actual| {
        try expectEqualApps(expected, actual);
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
                .variable => |v| try testing.expect(mem.eql(u8, v, actual_elem.variable)),
                .apps => try expectEqualApps(expected_elem, actual_elem),
                .match => |_| @panic("unimplemented"),
                .arrow => |_| @panic("unimplemented"),
                .pattern => |pattern| try testing.expect(
                    pattern.eql(actual_elem.pattern.*),
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
        \\Name1,5;
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
    const expecteds = &[_]Ast{Ast{
        .apps = &.{
            .{ .key = .{
                .type = .Name,
                .lit = "Name1",
                .context = 0,
            } },
            .{ .key = .{
                .type = .Name,
                .lit = ",",
                .context = 4,
            } },
            .{ .key = .{
                .type = .I,
                .lit = "5",
                .context = 5,
            } },
            .{ .key = .{
                .type = .Name,
                .lit = ";",
                .context = 6,
            } },
        },
    }};
    try testStrParse(input[0..7], expecteds);
    // try expectEqualApps(expected, expected); // test the test function
}

test "App: simple vals" {
    const expecteds = &[_]Ast{Ast{
        .apps = &.{
            Ast{ .key = .{
                .type = .Name,
                .lit = "Aa",
                .context = 0,
            } },
            Ast{ .key = .{
                .type = .Name,
                .lit = "Bb",
                .context = 3,
            } },
            Ast{ .key = .{
                .type = .Name,
                .lit = "Cc",
                .context = 6,
            } },
        },
    }};
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
            Ast{
                .apps = &.{Ast{
                    .key = .{
                        .type = .I,
                        .lit = "1",
                        .context = 0,
                    },
                }},
            },
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
    const expecteds = &[_]Ast{Ast{
        .apps = &.{
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
        },
    }};
    try testStrParse("1 + 2 + 3", expecteds);
}

test "App: simple op, no first arg" {
    const expecteds = &[_]Ast{Ast{
        .apps = &.{
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
        },
    }};
    try testStrParse("+ 2", expecteds);
}

test "App: simple op, no second arg" {
    const expecteds = &[_]Ast{Ast{
        .apps = &.{
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
        },
    }};
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
        // Ast{.apps = &.{ )
        //     Ast{ .apps = &.{ )
        //         Ast{ .apps = &.{ )
        //             Ast{ .apps = &.{} },
        //             Ast{ .apps = &.{} },
        //         } },
        //         Ast{ .apps = &.{} },
        //     } },
        // } },
        // Ast{.apps = &.{ )
        //     Ast{ .apps = &.{ )
        //         Ast{ .apps = &.{} },
        //         Ast{ .apps = &.{ )
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
                .type = .Name,
                .lit = "Foo",
                .context = 0,
            } },
        } },
        Ast{ .apps = &.{
            Ast{ .key = .{
                .type = .Name,
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
    var fbs1 = io.fixedBufferStream("{1,{2},3  -> A}");
    var fbs2 = io.fixedBufferStream("{1, {2}, 3 -> A}");
    var fbs3 = io.fixedBufferStream("{1, {2}, 3 -> B}");
    var lexer1 = Lexer.init(allocator, fbs1.reader());
    var lexer2 = Lexer.init(allocator, fbs2.reader());
    var lexer3 = Lexer.init(allocator, fbs3.reader());

    const ast1 = try parseAst(allocator, &lexer1);
    const ast2 = try parseAst(allocator, &lexer2);
    const ast3 = try parseAst(allocator, &lexer3);
    // try testing.expectEqualStrings(ast.?.apps[0].pat, "Asdf");
    try testing.expect(ast1.eql(ast2));
    try testing.expectEqual(ast1.hash(), ast2.hash());
    try testing.expect(!ast1.eql(ast3));
    try testing.expect(!ast2.eql(ast3));
    try testing.expect(ast1.hash() != ast3.hash());
    try testing.expect(ast2.hash() != ast3.hash());
}

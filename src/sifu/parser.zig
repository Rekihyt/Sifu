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
const print = util.print;

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

pub fn parseAst(
    allocator: Allocator,
    lexer: anytype,
) !Ast {
    print("parseAst\n", .{});
    // (ParseError || @TypeOf(lexer).Error || Allocator.Error)
    // No need to delete asts, they will all be returned or cleaned up
    var levels = ArrayListUnmanaged(Level){};
    defer levels.deinit(allocator);
    try levels.append(allocator, Level{});
    errdefer { // TODO: add test coverage
        for (levels.items) |*level| {
            for (level.current.items) |*ast|
                ast.deleteChildren(allocator);
            level.current.deinit(allocator);
            for (level.next.items) |*ast|
                ast.deleteChildren(allocator);
            level.next.deinit(allocator);
        }
        levels.deinit(allocator);
    }
    while (try lexer.nextLine()) |line| {
        defer lexer.allocator.free(line);
        if (try parseAppend(allocator, &levels, line)) |ast|
            return ast
        else
            continue;
    }
    return Ast.ofApps(&.{});
}

/// This encodes the values needed to parse a specific level of nesting. These
/// fields would be the parameters in a recursive algorithm.
const Level = struct {
    // This contains previously parsed, as well as Asts in progress.
    current: ArrayListUnmanaged(Ast) = ArrayListUnmanaged(Ast){},
    // This is temporary storage for an op's rhs so that they don't need to be
    // removed from the current list when done
    next: ArrayListUnmanaged(Ast) = ArrayListUnmanaged(Ast){},
    // This points to the last op parsed for a level of nesting. This tracks
    // infixes for each level of nesting, in congruence with the parse stack.
    // These are nullable because each level of nesting gets a new relative
    // tail, which is null until an op is found, and can only be written to once
    // the entire level of nesting is parsed (apart from another infix). Like
    // the parse stack, indices here correspond to a level of nesting, while
    // infixes mutate the element at their index as they are parsed.
    maybe_op_tail: ?*Ast = null,
    is_pattern: bool = false,
};

/// Does not allocate on errors or empty parses. Parses the line of tokens,
/// returning a partial Ast on trailing operators or unfinished nesting. In such
/// a case, null is returned and the same parser_stack must be reused to finish
/// parsing. Otherwise, an Ast is returned from an ownded slice of parser_stack.
// Precedence: long arrow < long match < commas < infix < arrow < match
// - TODO: [] should be a flat Apps instead of as an infix
pub fn parseAppend(
    allocator: Allocator,
    levels: *ArrayListUnmanaged(Level),
    line: []const Token,
) !?Ast {
    // These variables are relative to the current level of nesting being parsed
    var level = levels.pop();
    for (line) |token| {
        const next_ast = switch (token.type) {
            .Name => Ast.ofLit(token),
            .Infix, .Match, .Arrow => {
                if (level.maybe_op_tail) |tail|
                    if (level.current.getLastOrNull()) |op| {
                        if (@intFromEnum(op) < @intFromEnum(Ast.infix)) {
                            print("Parsing lower precedence\n", .{});
                        }
                        print("Op: ", .{});
                        op.write(stderr) catch unreachable;
                        print("\n", .{});
                        _ = tail;
                    };
                if (token.type == .Infix)
                    try level.next.append(allocator, Ast.ofLit(token));
                try level.next.append(allocator, Ast{ .apps = &.{} });
                // Right hand args for previous op with higher precedence
                print("Rhs Len: {}\nOp: ", .{level.next.items.len});
                // Add an apps for the trailing args
                const op = Ast{ .infix = try level.next.toOwnedSlice(allocator) };
                op.write(stderr) catch unreachable;
                print("\n", .{});
                defer level.maybe_op_tail = getLastPtr(op);
                if (level.maybe_op_tail) |tail| {
                    // Add an apps for the trailing args
                    tail.* = op;
                    continue;
                } else try level.current.append(allocator, op);
                continue;
            },
            .LeftParen => {
                // Save index of the nested app to write to later
                try levels.append(allocator, level);
                // Reset vars for new nesting level
                level = Level{};
                continue;
            },
            .RightParen => blk: {
                var nested = level.current;
                level = levels.pop();
                const apps = Ast.ofApps(try nested.toOwnedSlice(allocator));
                break :blk apps;
            },
            .Comma => {
                try level.current.append(allocator, Ast.ofLit(token));
                continue;
            },
            .Var => Ast.ofVar(token.lit),
            .Str, .I, .F, .U => Ast.ofLit(token),
            .Comment, .NewLine => Ast.ofLit(token),
            else => @panic("unimplemented"),
        };
        try level.next.append(allocator, next_ast);
    }
    const next_ast = Ast{ .apps = try level.next.toOwnedSlice(allocator) };
    if (level.maybe_op_tail) |tail| {
        // Add an apps for the trailing args
        tail.* = next_ast;
    } else try level.current.append(allocator, next_ast);
    // TODO: return optional void and move to caller
    const result = Ast.ofApps(try level.current.toOwnedSlice(allocator));
    print("Levels Len: {}\n", .{levels.items.len});
    print("Result: {s}\n", .{@tagName(result)});
    return result;
}

// Convert a list of nodes into a single node, depending on its type
pub fn intoNode(
    allocator: Allocator,
    kind: Ast,
    nodes: *ArrayListUnmanaged(Ast),
) !Ast {
    return switch (kind) {
        .apps => Ast.ofApps(try nodes.toOwnedSlice(allocator)),
        .pattern => blk: {
            print("pat\n", .{});
            var pattern = Pat{};
            for (nodes.items) |ast|
                _ = try pattern.insertNode(allocator, ast);
            break :blk Ast.ofPattern(pattern);
        },
        else => @panic("unimplemented"),
    };
}

fn getLastPtr(ast: Ast) *Ast {
    return @constCast(switch (ast) {
        .apps, .infix, .arrow, .match => |apps| &apps[apps.len - 1],
        else => @panic("not a list type of Ast"),
    });
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

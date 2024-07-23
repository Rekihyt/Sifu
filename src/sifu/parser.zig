/// The parser for Sifu tries to make as few decisions as possible. Mostly, it
/// greedily lexes seperators like commas into their own ast nodes, separates
/// vars and vals based on the first character's case, and lazily lexes non-
/// strings. There are no errors, any utf-8 text is parsable.
///
const Parser = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
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
const meta = std.meta;
const print = util.print;
const panic = util.panic;
const streams = @import("../streams.zig").streams;

// TODO add indentation tracking, and separate based on newlines+indent
// TODO revert parsing to assume apps at all levels, with ops as appended,
// single terms to apps (add a new branch for the current way of parsing)

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
) ![]const Ast {
    // TODO (ParseError || @TypeOf(lexer).Error || Allocator.Error)
    // No need to destroy asts, they will all be returned or cleaned up
    var levels = ArrayListUnmanaged(Level){};
    defer levels.deinit(allocator);
    errdefer {
        // TODO: add test coverage
        for (levels.items) |*level| {
            for (level.apps_stack.items) |*apps| {
                Ast.ofApps(apps.items).deinit(allocator);
                apps.deinit(allocator);
            }
        }
        levels.deinit(allocator);
    }
    while (try lexer.nextLine()) |line| {
        defer {
            lexer.allocator.free(line);
            lexer.clearRetainingCapacity();
        }
        if (try parse(allocator, &levels, line)) |ast|
            return ast
        else
            continue;
    }
    return &.{};
}

/// This tracks the values needed to parse a specific layer of nesting,
/// including each level of precendence. These fields would be function
/// parameters in the recursive parsing algorithm.
const Level = struct {
    // var apps_stack_buff: [3]ArrayListUnmanaged(Ast) = undefined;
    // This points to the last op parsed for a level of nesting. This tracks
    // infixes for each level of nesting, in congruence with the parse stack.
    // These are nullable because each level of nesting gets a new relative
    // tail, which is null until an op is found, and can only be written to once
    // the entire level of nesting is parsed (apart from another infix). Like
    // the parse stack, indices here correspond to a level of nesting, while
    // infixes mutate the element at their index as they are parsed.
    // The current level of apps (containing the lowest level precedence)
    // being parsed
    apps_stack: ArrayListUnmanaged(ArrayListUnmanaged(Ast)) =
        ArrayListUnmanaged(ArrayListUnmanaged(Ast)){},
    // Tracks the first link in the operator list, if any
    root: Ast = Ast.ofApps(&.{}), // root starts as an apps by default
    tail: *Ast = undefined,

    /// This function should be used on a new, stack allocated level
    pub fn init(self: *Level, allocator: Allocator) !void {
        self.tail = &self.root;
        assert(self.apps_stack.items.len == 0);
        // print("New tail {*}\n", .{self.tail});
        // Add the initial level of apps
        try self.apps_stack.append(allocator, ArrayListUnmanaged(Ast){});
    }

    // The pointer is safe until the current list is resized.
    fn current(self: Level) *ArrayListUnmanaged(Ast) {
        const len = self.apps_stack.items.len;
        assert(len != 0); // Check Level.init was called
        return &self.apps_stack.items[len - 1];
    }

    /// True if the given op has precedence over the current one. True if an op
    /// hasn't been parsed yet, or if the ops share precedence levels.
    fn isPrecedent(self: Level, op: Ast) bool {
        const prev = self.current().getLastOrNull() orelse
            return false;
        if (!prev.isOp())
            return false;
        const op_precedence: usize = switch (op) {
            .arrow, .match => 1,
            .infix => 2,
            .long_arrow, .long_match => 3,
            else => unreachable,
        };
        return self.apps_stack.items.len > op_precedence;
    }

    fn writeTail(self: *Level, slice: []Ast) void {
        self.tail.* = switch (self.tail.*) {
            inline .apps,
            .arrow,
            .match,
            .infix,
            .list,
            .long_arrow,
            .long_match,
            => |_, tag| @unionInit(Ast, @tagName(tag), slice),
            else => panic(
                "Non-op tail {}\n",
                .{meta.activeTag(self.tail.*)},
            ),
        };
        self.tail = &slice[slice.len - 1];
    }

    /// Returns a pointer to the op.
    fn appendOp(self: *Level, op: Ast, allocator: Allocator) !void {
        if (self.isPrecedent(op)) {
            print(
                "Appending precedent to {s} tail with {s} op\n",
                .{ @tagName(self.tail.*), @tagName(meta.activeTag(op)) },
            );
            // Add an apps for the trailing args
            try self.current().append(allocator, op);
            self.writeTail(try self.current().toOwnedSlice(allocator));
            // Check if the previous op was higher precedence
            // if (@intFromEnum(prev_op) > @intFromEnum(op)) {} else {
        } else {
            print(
                "Appending non-precedent to {s} tail with {s} op\n",
                .{ @tagName(self.tail.*), @tagName(meta.activeTag(op)) },
            );
            try self.current().append(allocator, op);
            self.writeTail(try self.current().toOwnedSlice(allocator));

            // self.root = Ast.ofApps(slice);
            // Descend one level of precedence
            // const slice = try self.apps_stack.pop().toOwnedSlice(allocator);
            // self.current().append(slice);
        }
        // };
        // if (apps.len > 0 and apps[apps.len - 1].isOp()) |tail|
    }

    // Convert a list of nodes into a single node, depending on its type
    pub fn intoNode(
        allocator: Allocator,
        kind: Ast,
        nodes: []const Ast,
    ) !Ast {
        return switch (kind) {
            .apps => Ast.ofApps(nodes),
            .pattern => blk: {
                print("pat\n", .{});
                var pattern = Pat{};
                // TODO: split nodes by commas/newlines and add individually
                try pattern.put(allocator, nodes, null);
                Ast.ofApps(nodes).deinit(allocator);
                break :blk Ast.ofPattern(pattern);
            },
            else => unreachable,
        };
    }

    /// Allocate the current apps to slices. There should be at least one apps
    ///on the apps_stack.
    pub fn finalize(
        level: *Level,
        allocator: Allocator,
    ) !Ast {
        var slice: []Ast = undefined;
        var tail = level.tail;
        while (level.apps_stack.popOrNull()) |*apps| {
            slice = try @constCast(apps).toOwnedSlice(allocator);
            print("Finalizing slice of len {}\n", .{slice.len});
            // const next = if (level.apps_stack.getLastOrNull()) |parent|
            //     parent
            // else {
            //     // TODO: check w
            //     break;
            // };
            //
            // Set new tail pointer to this op's rhs
            // Overwrite the empty op tail, if necessary
            if (level.apps_stack.getLastOrNull()) |_| {
                if (!tail.isOp()) panic(
                    "Level of precedence pop without op ({s} instead)\n",
                    .{@tagName(meta.activeTag(tail.*))},
                );
                switch (tail.*) {
                    inline .apps, .arrow, .match, .infix, .list => |_, tag| {
                        tail.* = @unionInit(Ast, @tagName(tag), slice);
                    },
                    else => unreachable,
                }
            } else {
                level.writeTail(slice);
                print("Writing final apps to tail {*}: ", .{tail});
                tail.writeSExp(streams.err, null) catch unreachable;
                print("\n", .{});
                break;
            }
            tail = &slice[slice.len - 1];
        }
        print("Root apps {*}: ", .{&level.root});
        level.root.writeIndent(streams.err, null) catch unreachable;
        print("\n", .{});
        level.apps_stack.deinit(allocator);
        return level.root;
    }
};

/// Does not allocate on errors or empty parses. Parses the line of tokens,
/// returning a partial Ast on trailing operators or unfinished nesting. In such
/// a case, null is returned and the same parser_stack must be reused to finish
/// parsing. Otherwise, an Ast is returned from an ownded slice of parser_stack.
// Precedence: semis < long arrow, long match < commas < infix < arrow, match
// - TODO: [] should be a flat Apps instead of as an infix
pub fn parse(
    allocator: Allocator,
    levels: *ArrayListUnmanaged(Level),
    line: []const Token,
) !?[]const Ast {
    // These variables are relative to the current level of nesting being parsed
    var level = Level{};
    try level.init(allocator);
    for (line) |token| {
        const current_ast = switch (token.type) {
            .Name => Ast.ofKey(token.lit),
            inline .Infix,
            .Match,
            .Arrow,
            .Comma,
            .LongMatch,
            .LongArrow,
            => |tag| {
                const op_tag = switch (tag) {
                    .Infix => .infix,
                    .Match => .match,
                    .Arrow => .arrow,
                    .Comma => .list,
                    .LongMatch => .long_match,
                    .LongArrow => .long_arrow,
                    else => unreachable,
                };
                const op = @unionInit(Ast, @tagName(op_tag), &.{});
                if (tag == .Infix)
                    try level.current().append(allocator, Ast.ofKey(token.lit));
                // Right hand args for previous op with higher precedence
                try level.appendOp(op, allocator);
                continue;
            },
            inline .LeftParen, .LeftBrace => |tag| {
                // Push the current level for later
                try levels.append(allocator, level);
                // Start a new nesting level
                level = Level{};
                try level.init(allocator);
                print("Init\n", .{});
                if (tag == .LeftBrace)
                    level.root = Ast.ofPattern(Pat{});
                continue;
            },
            .RightParen, .RightBrace => blk: {
                defer level = levels.pop();
                break :blk try level.finalize(allocator);

                // blk: {
                //     // This intermediate allocation could be removed for patterns
                //     defer allocator.free(current_slice);
                //     break :blk pattern.fromList(current_slice);
                // }

            },
            .Var => Ast.ofVar(token.lit),
            .VarApps => Ast.ofVarApps(token.lit),
            .Str, .I, .F, .U => Ast.ofKey(token.lit),
            .Comment, .NewLine => Ast.ofKey(token.lit),
        };
        try level.current().append(allocator, current_ast);
        print("Current slice ptr {*}, len {}\n", .{
            level.current().items.ptr,
            level.current().items.len,
        });
    }
    const result = try level.finalize(allocator);
    // TODO: return optional void and move to caller
    return result.apps;
}

// Assumes apps are Infix encoded (they have at least one element).
fn getOpTailOrNull(ast: Ast) ?*Ast {
    return switch (ast) {
        .apps,
        .arrow,
        .match,
        .list,
        .infix,
        .long_match,
        .long_arrow,
        => |apps| @constCast(&apps[apps.len - 1]),
        else => null,
    };
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
const io = std.io;
const Lexer = @import("Lexer.zig")
    .Lexer(io.FixedBufferStream([]const u8).Reader);
const List = ArrayListUnmanaged(Ast);

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
    try streams.err.writeByte('\n');
    try streams.err.writeAll("Expected: ");
    try expected.write(streams.err);
    try streams.err.writeByte('\n');

    try streams.err.writeAll("Actual: ");
    try actual.write(streams.err);
    try streams.err.writeByte('\n');

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
                .match => |_| panic("unimplemented", .{}),
                .arrow => |_| panic("unimplemented", .{}),
                .pattern => |pattern| try testing.expect(
                    pattern.eql(actual_elem.pattern.*),
                ),
            }
        } else {
            try streams.err.writeAll("Asts of different types not equal");
            try testing.expectEqual(expected_elem, actual_elem);
            // above line should always fail
            panic(
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

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
const Apps = Pat.Apps;
const Pattern = @import("../pattern.zig").Pattern;
const syntax = @import("syntax.zig");
const Token = syntax.Token(usize);
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
const fs = std.fs;
const Lexer = @import("Lexer.zig").Lexer;
const debug_mode = @import("builtin").mode == .Debug;
const detect_leaks = @import("build_options").detect_leaks;

// TODO add indentation tracking, and separate based on newlines+indent

/// Convert this token to a term by parsing its literal value. This is done
/// manually on a case by case basis by the user because by default everything
/// is a string
pub fn parseTerm(term: Token) Oom!union { str: []const u8, usize: usize, fsize: fsize, isize: isize } {
    return switch (term.type) {
        .Name, .Str, .Var, .Comment => term.lit,
        .Infix => term.lit,
        .I => std.fmt.parseInt(usize, term.lit, 0),
        .U => std.fmt.parseUnsigned(usize, term.lit, 0),
        .F => std.fmt.parseFloat(fsize, term.lit),
    } catch |err| switch (err) {
        // token should only have consumed digits
        error.InvalidCharacter => unreachable,
        // TODO: arbitrary ints here
        error.Overflow => unreachable,
    };
}

const ParseError = error{
    NoLeftBrace,
    NoRightBrace,
    NoLeftParen,
    NoRightParen,
};

/// This tracks the values needed to parse a specific layer of nesting,
/// including each level of precendence. These fields would be function
/// parameters in the recursive parsing algorithm.
const Level = struct {
    /// This tracks operators for a given level of precedence, with a tail for
    /// their destination and a stack for their arguments.
    const Precedence = struct {
        tail: *Ast,
        apps: ArrayListUnmanaged(Ast) = .{},

        pub fn writeTail(
            self: *Precedence,
            allocator: Allocator,
            height: usize,
        ) !void {
            if (self.apps.items.len == 0)
                return;
            var slice = try self.apps.toOwnedSlice(allocator);
            self.tail.* = switch (self.tail.*) {
                inline .apps,
                .arrow,
                .match,
                .infix,
                .list,
                .long_arrow,
                .long_match,
                => |_, tag| @unionInit(
                    Ast,
                    @tagName(tag),
                    Apps{ .root = slice, .height = height },
                ),
                else => panic(
                    "Non-op tail {}\n",
                    .{meta.activeTag(self.tail.*)},
                ),
            };
            self.tail = &slice[slice.len - 1];
        }

        pub fn append(self: *Precedence, allocator: Allocator, ast: Ast) !void {
            return self.apps.append(allocator, ast);
        }

        /// True if the given op has precedence over the current one. True if an op
        /// hasn't been parsed yet, or if the ops share precedence levels.
        // Precedence: semis, long arrow, long match < infix < commas, arrow, match
        fn order(self: Precedence, op: Ast) Order {
            if (!self.tail.isOp())
                return .gt;
            const op_precedence = precedenceLevel(op);
            const tail_precedence = precedenceLevel(self.tail.*);
            return math.order(op_precedence, tail_precedence);
        }
    };

    // This points to the last op parsed for a level of nesting. This tracks
    // infixes for each level of nesting, in congruence with the parse stack.
    // These are nullable because each level of nesting gets a new relative
    // tail, which is null until an op is found, and can only be written to once
    // the entire level of nesting is parsed (apart from another infix). Like
    // the parse stack, indices here correspond to a level of nesting, while
    // infixes mutate the element at their index as they are parsed.
    // The current level of apps (containing the lowest level precedence)
    // being parsed
    precedences: ArrayListUnmanaged(Precedence) =
        ArrayListUnmanaged(Precedence){},
    // Tracks the first link in the operator list, if any
    root: Ast = Ast.ofApps(.{}), // root starts as an apps by default

    /// This function should be used on a new, stack allocated level
    pub fn init(self: *Level, allocator: Allocator) !void {
        assert(self.precedences.items.len == 0);
        // print("New tail {*}\n", .{self.tail});
        // Add the initial level of apps
        const precedence = Precedence{ .tail = &self.root };
        try self.precedences.append(allocator, precedence);
    }

    // The pointer is safe until the current list is resized.
    inline fn current(self: Level) *Precedence {
        const len = self.precedences.items.len;
        assert(len != 0); // Check Level.init was called
        return &self.precedences.items[len - 1];
    }

    inline fn precedenceLevel(op: Ast) usize {
        return switch (op) {
            .arrow, .match, .list => 3,
            .infix => 2,
            .long_arrow, .long_match, .long_list => 1,
            else => unreachable,
        };
    }

    /// Returns a pointer to the op.
    fn appendOp(
        self: *Level,
        allocator: Allocator,
        op: Ast,
        infix: ?Ast,
        height: usize,
    ) !void {
        var precedence = self.current();
        // Descend as many levels of precedence as necessary
        while (precedence.order(op) == .lt) : (precedence = self.current()) {
            try precedence.writeTail(allocator, height);
            _ = self.precedences.pop();
        }
        if (infix) |infix_lit|
            try precedence.append(allocator, infix_lit);
        // Add an apps for the trailing args
        try precedence.append(allocator, op);
        switch (precedence.order(op)) {
            // Ascend one level of precedence
            .gt => {
                const slice = precedence.apps.items;
                try self.precedences.append(
                    allocator,
                    Precedence{ .tail = &slice[slice.len - 1] },
                );
            },
            .lt => unreachable,
            .eq => try precedence.writeTail(allocator, height),
        }
    }

    // Convert a list of nodes into a single node, depending on its type
    inline fn intoNode(
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
    /// on the precedences.
    fn finalize(
        level: *Level,
        allocator: Allocator,
        height: usize,
    ) !Apps {
        while (level.precedences.popOrNull()) |*precedence|
            try @constCast(precedence).writeTail(allocator, height);

        // All arraylists have been written to slices, so don't need freeing
        level.precedences.deinit(allocator);
        return level.root.apps;
    }
};

/// Read from a Lexer until its stream is empty, and convert tokens into Asts.
/// Caller owns the returned Asts (including the underlying token), which should
/// be freed with `deinit`. This frees the underlying tokens as needed based on
/// the memory manager, as tokens are copied into the returned Ast. Apps are
/// assumed at all levels, with ops as appended, single terms to apps (add a new
/// branch for the current way of parsing)
/// Returns null if the reader ended before an Ast could be parsed
/// Returns an arena containing all string allocations (from lexing)
// - TODO: [] should be a flat Apps instead of as an infix / nesting ops (the
// behavior of commas and semis is no longer list-like, but array-like)
pub fn parse(
    allocator: Allocator,
    reader: anytype,
) !?struct { Apps, ArenaAllocator } {
    var str_arena = ArenaAllocator.init(allocator);
    errdefer str_arena.deinit();
    // Read strings into an arena so that the caller can do what they want with
    // them
    var lexer = Lexer(@TypeOf(reader)).init(str_arena.allocator(), reader);
    defer lexer.deinit();
    var line = try ArrayList(Token).initCapacity(allocator, 16);
    defer line.deinit();
    // No need to destroy asts, they will all be returned or cleaned up
    var levels = ArrayList(Level).init(allocator);
    defer levels.deinit();
    defer {
        assert(lexer.buff.items.len == 0);
        assert(line.items.len == 0);
        assert(levels.items.len == 0);
    }
    return while (try lexer.nextLine(&line)) |_| {
        defer line.clearRetainingCapacity();
        if (comptime detect_leaks) try streams.err.print(
            "String Arena Allocated: {} bytes\n",
            .{str_arena.queryCapacity()},
        );
        if (try parseLine(allocator, &levels, line.items)) |apps|
            break .{ apps, str_arena };
    } else null;
}

/// Does not allocate on errors or empty parses. Parses the line of tokens,
/// returning a partial Ast on trailing operators or unfinished nesting. In such
/// a case, null is returned and the same parser_stack must be reused to finish
/// parsing. Otherwise, an Ast is returned from an owned slice of parser_stack.
// The parsing algorithm pushes a list whenever an operator with lower precedence
// is parsed. Operators with same or higher precedence than their previous
// adjacent operator are simply added to the tail of the current list. To parse
// nesting apps or patterns, a new level is pushed on or popped off the level
// stack.
// All tokens in Sifu do not affect the semantics of previously parsed ones.
// This makes the precedence of the links in an operators chain monotonically
// decreasing once the highest level hast been found. Once a lower precedence
// operator is seen, it will either become the root or something lower will.
// If its the lowest precedence (or the end of line) is reached it is written
// to the root. The tail is then set to the root's op slice, and future low
// precedent ops will be linked there.
// TODO: return null if unfinished apps/pattern left to parse
pub fn parseLine(
    allocator: Allocator,
    levels: *ArrayList(Level),
    line: []const Token,
) !?Apps {
    // These variables are relative to the current level of nesting being parsed
    var level = Level{};
    try level.init(allocator);
    var height: usize = 0;
    for (line) |token| {
        const current_ast = switch (token.type) {
            .Name => Ast.ofKey(token.lit),
            inline .LeftParen, .LeftBrace => |tag| {
                if (height > 0)
                    height -= 1;
                // Push the current level for later
                try levels.append(level);
                // Start a new nesting level
                level = Level{};
                try level.init(allocator);
                if (tag == .LeftBrace)
                    level.root = Ast.ofPattern(Pat{});
                continue;
            },
            .RightParen, .RightBrace => blk: {
                height += 1;
                defer level = levels.pop();
                break :blk Ast.ofApps(try level.finalize(allocator, height));
            },
            .Var => Ast.ofVar(token.lit),
            .VarApps => Ast.ofVarApps(token.lit),
            .Str, .I, .F, .U => Ast.ofKey(token.lit),
            .Comment, .NewLine => Ast.ofKey(token.lit),
            inline else => |tag| {
                const op_tag = switch (tag) {
                    .Infix => .infix,
                    .Match => .match,
                    .Arrow => .arrow,
                    .Comma => .list,
                    .Semicolon => .long_list,
                    .LongMatch => .long_match,
                    .LongArrow => .long_arrow,
                    else => unreachable,
                };
                // Right hand args for previous op with higher precedence
                try level.appendOp(
                    allocator,
                    @unionInit(Ast, @tagName(op_tag), .{}),
                    if (tag == .Infix) Ast.ofKey(token.lit) else null,
                    height,
                );
                continue;
            },
        };
        try level.current().append(allocator, current_ast);
    }
    return try level.finalize(allocator, height);
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
const TestLexer = @import("Lexer.zig")
    .Lexer(io.FixedBufferStream([]const u8).Reader);
const List = ArrayListUnmanaged(Ast);

test "simple val" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var fbs = io.fixedBufferStream("Asdf");
    var lexer = TestLexer.init(arena.allocator(), fbs.reader());
    const ast = try parse(arena.allocator(), &lexer);
    try testing.expect(ast == .apps and ast.apps.len == 1);
    try testing.expectEqualStrings(ast.apps[0].key.lit, "Asdf");
}

fn testStrParse(str: []const u8, expecteds: []const Ast) !void {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fbs = io.fixedBufferStream(str);
    var lexer = TestLexer.init(allocator, fbs.reader());
    const actuals = try parse(allocator, &lexer);
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
    var lexer1 = TestLexer.init(allocator, fbs1.reader());
    var lexer2 = TestLexer.init(allocator, fbs2.reader());
    var lexer3 = TestLexer.init(allocator, fbs3.reader());

    const ast1 = try parse(allocator, &lexer1);
    const ast2 = try parse(allocator, &lexer2);
    const ast3 = try parse(allocator, &lexer3);
    // try testing.expectEqualStrings(ast.?.apps[0].pat, "Asdf");
    try testing.expect(ast1.eql(ast2));
    try testing.expectEqual(ast1.hash(), ast2.hash());
    try testing.expect(!ast1.eql(ast3));
    try testing.expect(!ast2.eql(ast3));
    try testing.expect(ast1.hash() != ast3.hash());
    try testing.expect(ast2.hash() != ast3.hash());
}

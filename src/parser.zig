const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;
const testing = std.testing;
const Lexer = @import("lexer.zig");
const Token = @import("token.zig");
const ast = @import("ast.zig");
const Node = ast.Node;
const Ast = ast.Ast;
const Errors = @import("error.zig").Errors;

/// Parses source code into an AST tree
pub fn parse(allocator: Allocator, source: []const u8, err: Errors) Parser.Error!Ast {
    var lexer = Lexer.init(source);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var parser = Parser{
        .current = lexer.next(),
        .allocator = allocator,
        .lexer = lexer,
        .source = source,
        .err = err,
        .depth = 0,
    };

    var nodes = ArrayList(Node).init(parser.allocator);
    errdefer nodes.deinit();

    while (parser.next()) |next| {
        _ = next;
        try nodes.append(try parser.parseExpression());
    }

    return Ast{
        .nodes = nodes.toOwnedSlice(),
        .arena = arena.state,
        .allocator = allocator,
    };
}

/// Parser retrieves tokens from our Lexer and turns them into
/// nodes to create an AST.
pub const Parser = struct {
    /// Current token that has been parsed
    current: ?Token,
    allocator: Allocator,
    /// Lexer that tokenized all tokens and is used to retrieve the next token
    lexer: Lexer,
    /// Original source code. Memory is not owned by the parser.
    source: []const u8,
    /// List of errors that can be filled with Parser errors
    err: Errors,

    pub const Error = error{
        ParserError,
        OutOfMemory,
        Overflow,
        InvalidCharacter,
    };

    /// Returns `Error.ParserError` and appends an error message to the `errors` list.
    fn fail(self: *Parser, comptime msg: []const u8, index: usize, args: anytype) Error {
        try self.err.add(msg, index, .err, args);
        return Error.ParserError;
    }

    /// Parses the current token as an Identifier
    fn parseVal(self: *Parser) Error!Node {
        const val = try self.allocator.create(Node.Val);
        const name = try self.allocator.dupe(u8, self.next());
        val.* = .{ .token = self.current, .name = name };
        return Node{ .node_type = val };
    }

    /// Parses the current token into an integer literal node
    fn parseIntLit(self: *Parser) Error!Node {
        const literal = try self.allocator.create(Node.IntLit);
        const string_number = self.source[self.current.start..self.current.end];
        const value = try std.fmt.parseInt(usize, string_number, 10);

        literal.* = .{ .token = self.current, .value = value };
        return Node{ .int_lit = literal };
    }

    /// Parses the current token into a string literal
    fn parseStrLit(self: *Parser) Error!Node {
        const literal = try self.allocator.create(Node.StrLit);
        const token = self.current;
        literal.* = .{ .token = token, .value = try self.allocator.dupe(u8, self.source[token.start..token.end]) };
        return Node{ .string_lit = literal };
    }

    /// Parses a comment token into a `Comment` node
    fn parseComment(self: *Parser) Error!Node {
        const comment = try self.allocator.create(Node.Comment);
        const token = self.current;
        comment.* = .{
            .token = self.current,
            .value = self.source[token.start..token.end],
        };

        return Node{ .comment = comment };
    }
};

test "Parse Declaration" {
    var allocator = testing.allocator;
    const test_cases = .{
        .{ .input = "const x = 5", .id = "x", .expected = 5, .mutable = false, .is_pub = false },
        .{ .input = "mut y = 50", .id = "y", .expected = 50, .mutable = true, .is_pub = false },
        .{ .input = "mut x = 2 const y = 5", .id = "y", .expected = 5, .mutable = false, .is_pub = false },
        .{ .input = "pub const x = 2 pub const y = 5", .id = "y", .expected = 5, .mutable = false, .is_pub = true },
    };

    inline for (test_cases) |case| {
        var errors = Errors.init(allocator);
        defer errors.deinit();
        const tree = try parse(allocator, case.input, &errors);
        defer tree.deinit();
        const node = tree.nodes[tree.nodes.len - 1].declaration;
        try testing.expectEqualSlices(u8, case.id, node.name.identifier.value);
        try testing.expect(case.expected == node.value.int_lit.value);
        try testing.expect(case.mutable == node.mutable);
        try testing.expect(case.is_pub == node.is_pub);
    }
}

test "Parse public declaration outside global scope" {
    var allocator = testing.allocator;
    const input = "if(1<2){ pub const x = 2 }";

    var errors = Errors.init(allocator);
    defer errors.deinit();
    try testing.expectError(Parser.Error.ParserError, parse(allocator, input, &errors));
    try testing.expectEqual(@as(usize, 1), errors.list.items.len);
}

test "Parse Return statment" {
    const test_cases = .{
        .{ .input = "return 5", .expected = 5 },
        .{ .input = "return foo", .expected = "foo" },
        .{ .input = "return true", .expected = true },
    };

    var allocator = testing.allocator;
    inline for (test_cases) |case| {
        var errors = Errors.init(allocator);
        defer errors.deinit();
        const tree = try parse(allocator, case.input, &errors);
        defer tree.deinit();

        try testing.expect(tree.nodes.len == 1);

        const node = tree.nodes[0].@"return".value;

        switch (@typeInfo(@TypeOf(case.expected))) {
            .ComptimeInt => try testing.expectEqual(@intCast(usize, case.expected), node.int_lit.value),
            .Pointer => try testing.expectEqualSlices(u8, case.expected, node.identifier.value),
            .Bool => try testing.expectEqual(case.expected, node.boolean.value),
            else => @panic("Unexpected type"),
        }
    }
}

test "Parse identifier expression" {
    const input = "foobar";

    var allocator = testing.allocator;
    var errors = Errors.init(allocator);
    defer errors.deinit();
    const tree = try parse(allocator, input, &errors);
    defer tree.deinit();

    try testing.expect(tree.nodes.len == 1);

    const identifier = tree.nodes[0].expression.value.identifier;
    try testing.expect(identifier.token.token_type == .identifier);
    try testing.expectEqualSlices(u8, identifier.value, input);
}

test "Parse integer literal" {
    const input = "124";
    var allocator = testing.allocator;
    var errors = Errors.init(allocator);
    defer errors.deinit();
    const tree = try parse(allocator, input, &errors);
    defer tree.deinit();

    try testing.expect(tree.nodes.len == 1);
    const literal = tree.nodes[0].expression.value.int_lit;
    try testing.expect(literal.token.token_type == .integer);
    try testing.expect(literal.value == 124);
}

test "Parse prefix expressions" {
    const VarValue = union {
        int: usize,
        string: []const u8,
        boolean: bool,
    };
    const TestCase = struct {
        input: []const u8,
        operator: Node.Prefix.Op,
        expected: VarValue,
    };
    const test_cases = &[_]TestCase{
        .{ .input = "-5", .operator = .minus, .expected = VarValue{ .int = 5 } },
        .{ .input = "!25", .operator = .bang, .expected = VarValue{ .int = 25 } },
        .{ .input = "!foobar", .operator = .bang, .expected = VarValue{ .string = "foobar" } },
        .{ .input = "-foobar", .operator = .minus, .expected = VarValue{ .string = "foobar" } },
        .{ .input = "!true", .operator = .bang, .expected = VarValue{ .boolean = true } },
        .{ .input = "!false", .operator = .bang, .expected = VarValue{ .boolean = false } },
    };

    const allocator = testing.allocator;
    for (test_cases) |case| {
        var errors = Errors.init(allocator);
        defer errors.deinit();
        const tree = try parse(allocator, case.input, &errors);
        defer tree.deinit();

        try testing.expect(tree.nodes.len == 1);

        const prefix = tree.nodes[0].expression.value.prefix;
        switch (prefix.right) {
            .int_lit => |int| try testing.expect(case.expected.int == int.value),
            .identifier => |id| try testing.expectEqualSlices(u8, case.expected.string, id.value),
            .boolean => |boolean| try testing.expect(case.expected.boolean == boolean.value),
            else => @panic("Unexpected Node"),
        }

        try testing.expectEqual(case.operator, prefix.operator);
    }
}

test "Parse infix expressions - integer" {
    const TestCase = struct {
        input: []const u8,
        left: usize,
        operator: Node.Infix.Op,
        right: usize,
    };

    const test_cases = &[_]TestCase{
        .{ .input = "10 + 10", .left = 10, .operator = .add, .right = 10 },
        .{ .input = "10 - 10", .left = 10, .operator = .sub, .right = 10 },
        .{ .input = "10 * 10", .left = 10, .operator = .multiply, .right = 10 },
        .{ .input = "10 / 10", .left = 10, .operator = .divide, .right = 10 },
        .{ .input = "10 > 10", .left = 10, .operator = .greater_than, .right = 10 },
        .{ .input = "10 < 10", .left = 10, .operator = .less_than, .right = 10 },
        .{ .input = "10 == 10", .left = 10, .operator = .equal, .right = 10 },
        .{ .input = "10 != 10", .left = 10, .operator = .not_equal, .right = 10 },
    };

    const allocator = testing.allocator;
    for (test_cases) |case| {
        var errors = Errors.init(allocator);
        defer errors.deinit();
        const tree = try parse(allocator, case.input, &errors);
        defer tree.deinit();

        try testing.expect(tree.nodes.len == 1);
        const node: Node = tree.nodes[0];
        const infix: *Node.Infix = node.expression.value.infix;
        try testing.expectEqual(case.operator, infix.operator);
        try testing.expectEqual(case.left, infix.left.int_lit.value);
        try testing.expectEqual(case.right, infix.right.int_lit.value);
    }
}

test "Parse infix expressions - identifier" {
    const allocator = testing.allocator;
    const input = "foobar + foobarz";
    var errors = Errors.init(allocator);
    defer errors.deinit();
    const tree = try parse(allocator, input, &errors);
    defer tree.deinit();

    try testing.expect(tree.nodes.len == 1);
    const node: Node = tree.nodes[0];
    const infix: *Node.Infix = node.expression.value.infix;
    try testing.expectEqualSlices(u8, "foobar", infix.left.identifier.value);
    try testing.expectEqualSlices(u8, "foobarz", infix.right.identifier.value);
    try testing.expect(infix.operator == .add);
}

test "Parse infix expressions - boolean" {
    const allocator = testing.allocator;
    const input = "true == true";
    var errors = Errors.init(allocator);
    defer errors.deinit();
    const tree = try parse(allocator, input, &errors);
    defer tree.deinit();

    try testing.expect(tree.nodes.len == 1);
    const node: Node = tree.nodes[0];
    const infix: *Node.Infix = node.expression.value.infix;
    try testing.expectEqual(true, infix.left.boolean.value);
    try testing.expectEqual(true, infix.right.boolean.value);
    try testing.expect(infix.operator == .equal);
}

test "Boolean expression" {
    const allocator = testing.allocator;
    const input = "true";
    var errors = Errors.init(allocator);
    defer errors.deinit();
    const tree = try parse(allocator, input, &errors);
    defer tree.deinit();

    try testing.expect(tree.nodes.len == 1);
    try testing.expect(tree.nodes[0].expression.value == .boolean);
}

test "If expression" {
    const allocator = testing.allocator;
    const input = "if x < y { x }";
    var errors = Errors.init(allocator);
    defer errors.deinit();
    const tree = try parse(allocator, input, &errors);
    defer tree.deinit();

    try testing.expect(tree.nodes.len == 1);
    const if_exp = tree.nodes[0].expression.value.if_expression;
    try testing.expect(if_exp.true_pong.block_statement.nodes[0] == .expression);
    try testing.expectEqualSlices(
        u8,
        if_exp.true_pong.block_statement.nodes[0].expression.value.identifier.value,
        "x",
    );
}

test "If else expression" {
    const allocator = testing.allocator;
    const input = "if x < y { x } else { y }";
    var errors = Errors.init(allocator);
    defer errors.deinit();
    const tree = try parse(allocator, input, &errors);
    defer tree.deinit();

    try testing.expect(tree.nodes.len == 1);
    const if_exp = tree.nodes[0].expression.value.if_expression;
    try testing.expect(if_exp.true_pong.block_statement.nodes[0] == .expression);
    try testing.expectEqualSlices(
        u8,
        if_exp.true_pong.block_statement.nodes[0].expression.value.identifier.value,
        "x",
    );
    try testing.expect(if_exp.false_pong != null);
    try testing.expect(if_exp.false_pong.?.block_statement.nodes[0] == .expression);
    try testing.expectEqualSlices(
        u8,
        if_exp.false_pong.?.block_statement.nodes[0].expression.value.identifier.value,
        "y",
    );
}

test "If else-if expression" {
    const allocator = testing.allocator;
    const input = "if x < y { x } else if x == 0 { y } else { z }";
    var errors = Errors.init(allocator);
    defer errors.deinit();
    const tree = try parse(allocator, input, &errors);
    defer tree.deinit();

    try testing.expect(tree.nodes.len == 1);
    const if_exp = tree.nodes[0].expression.value.if_expression;
    try testing.expect(if_exp.true_pong.block_statement.nodes[0] == .expression);
    try testing.expectEqualSlices(
        u8,
        if_exp.true_pong.block_statement.nodes[0].expression.value.identifier.value,
        "x",
    );
    try testing.expect(if_exp.false_pong != null);
    try testing.expect(if_exp.false_pong.?.expression.value.if_expression.false_pong != null);
}

test "Function literal" {
    const input = "fn(x: int, y: int) fn(x: int) int { x + y }";
    const allocator = testing.allocator;
    var errors = Errors.init(allocator);
    defer errors.deinit();
    const tree = parse(allocator, input, &errors) catch |err| {
        try errors.write(input, std.io.getStdErr().writer());
        return err;
    };
    defer tree.deinit();

    try testing.expect(tree.nodes.len == 1);

    const func = tree.nodes[0].expression.value.func_lit;
    try testing.expect(func.params.len == 2);

    try testing.expectEqualSlices(u8, func.params[0].func_arg.value, "x");
    try testing.expectEqualSlices(u8, func.params[1].func_arg.value, "y");

    const body = func.body.?.block_statement.nodes[0];
    const infix = body.expression.value.infix;
    try testing.expectEqual(infix.operator, .add);
    try testing.expectEqualSlices(u8, infix.left.identifier.value, "x");
    try testing.expectEqualSlices(u8, infix.right.identifier.value, "y");
}

test "Function parameters" {
    const test_cases = .{
        .{ .input = "fn() void {}", .expected = &[_][]const u8{} },
        .{ .input = "fn(x: int) void {}", .expected = &[_][]const u8{"x"} },
        .{ .input = "fn(x: int, y: int, z: int) void {}", .expected = &[_][]const u8{ "x", "y", "z" } },
    };
    const allocator = testing.allocator;
    inline for (test_cases) |case| {
        var errors = Errors.init(allocator);
        defer errors.deinit();
        const tree = try parse(allocator, case.input, &errors);
        defer tree.deinit();

        try testing.expect(tree.nodes.len == 1);

        const func = tree.nodes[0].expression.value.func_lit;
        try testing.expect(func.params.len == case.expected.len);

        inline for (case.expected) |exp, i| {
            try testing.expectEqualSlices(u8, exp, func.params[i].func_arg.value);
        }
    }
}

test "Call expression" {
    const input = "add(1, 2 * 3, 4 + 5)";
    const allocator = testing.allocator;

    var errors = Errors.init(allocator);
    defer errors.deinit();
    const tree = try parse(allocator, input, &errors);
    defer tree.deinit();

    try testing.expect(tree.nodes.len == 1);

    const call = tree.nodes[0].expression.value.call_expression;
    try testing.expectEqualSlices(u8, call.function.identifier.value, "add");
    try testing.expect(call.arguments.len == 3);

    try testing.expect(call.arguments[0].int_lit.value == 1);
    try testing.expectEqual(call.arguments[1].infix.operator, .multiply);
    try testing.expect(call.arguments[2].infix.right.int_lit.value == 5);
}

test "String expression" {
    const input = "\"Hello, world\"";
    const allocator = testing.allocator;

    var errors = Errors.init(allocator);
    defer errors.deinit();
    const tree = try parse(allocator, input, &errors);
    defer tree.deinit();

    try testing.expect(tree.nodes.len == 1);

    const string = tree.nodes[0].expression.value.string_lit;
    try testing.expectEqualSlices(u8, "Hello, world", string.value);
}

test "Member expression" {
    const input = "foo.bar";
    const allocator = testing.allocator;

    var errors = Errors.init(allocator);
    defer errors.deinit();
    const tree = try parse(allocator, input, &errors);
    defer tree.deinit();

    try testing.expect(tree.nodes.len == 1);

    const index = tree.nodes[0].expression.value.index;
    try testing.expectEqualSlices(u8, "bar", index.index.string_lit.value);
    try testing.expectEqualSlices(u8, "foo", index.left.identifier.value);
    try testing.expect(index.token.token_type == .period);
}

test "Array literal" {
    const input = "[]int{1, 2 * 2, 3 + 3}";
    const allocator = testing.allocator;

    var errors = Errors.init(allocator);
    defer errors.deinit();
    const tree = try parse(allocator, input, &errors);
    defer tree.deinit();

    try testing.expect(tree.nodes.len == 1);

    const array = tree.nodes[0].expression.value.data_structure;
    try testing.expect(array.value.?.len == 3);
    try testing.expect(array.value.?[0].int_lit.value == 1);
    try testing.expect(array.value.?[1].infix.operator == .multiply);
}

test "Array index" {
    const input = "array[1]";
    const allocator = testing.allocator;

    var errors = Errors.init(allocator);
    defer errors.deinit();
    const tree = try parse(allocator, input, &errors);
    defer tree.deinit();

    try testing.expect(tree.nodes.len == 1);

    const index = tree.nodes[0].expression.value.index;
    try testing.expect(index.left == .identifier);
    try testing.expect(index.index.int_lit.value == 1);
}

test "Map Literal" {
    const input = "[]string:int{\"foo\": 1, \"bar\": 5}";
    const allocator = testing.allocator;

    var errors = Errors.init(allocator);
    defer errors.deinit();
    const tree = try parse(allocator, input, &errors);
    defer tree.deinit();

    try testing.expect(tree.nodes.len == 1);

    const map = tree.nodes[0].expression.value.data_structure;
    try testing.expect(map.value.?.len == 2);

    const expected = .{
        .{ .key = "foo", .value = 1 },
        .{ .key = "bar", .value = 5 },
    };

    inline for (expected) |case, i| {
        const pair: *Node.MapPair = map.value.?[i].map_pair;
        try testing.expectEqualSlices(u8, case.key, pair.key.string_lit.value);
        try testing.expect(case.value == pair.value.int_lit.value);
    }

    try testing.expectEqual(Node.map, tree.nodes[0].getType().?);
    try testing.expectEqual(Node.string, tree.nodes[0].getInnerType().?);
    try testing.expectEqual(Node.integer, map.type_def_value.?.getInnerType().?);
}

test "While loop" {
    const input = "while x < y { x }";
    const allocator = testing.allocator;

    var errors = Errors.init(allocator);
    defer errors.deinit();
    const tree = try parse(allocator, input, &errors);
    defer tree.deinit();

    try testing.expect(tree.nodes.len == 1);

    const loop = tree.nodes[0].while_loop;

    try testing.expect(loop.condition.infix.operator == .less_than);
    try testing.expect(loop.block.block_statement.nodes.len == 1);
    try testing.expectEqualStrings("x", loop.block.block_statement.nodes[0].expression.value.identifier.value);
}

test "Assignment" {
    var allocator = testing.allocator;
    const test_cases = .{
        .{ .input = "x = 5", .id = "x", .expected = 5 },
        .{ .input = "y = 50", .id = "y", .expected = 50 },
        .{ .input = "x = 2 y = 5", .id = "y", .expected = 5 },
    };

    inline for (test_cases) |case| {
        var errors = Errors.init(allocator);
        defer errors.deinit();
        const tree = try parse(allocator, case.input, &errors);
        defer tree.deinit();
        const node = tree.nodes[tree.nodes.len - 1].expression.value.assignment;
        try testing.expectEqualSlices(u8, case.id, node.left.identifier.value);
        try testing.expect(case.expected == node.right.int_lit.value);
    }
}

test "Comment expression" {
    const input = "//This is a comment";
    const allocator = testing.allocator;

    var errors = Errors.init(allocator);
    defer errors.deinit();
    const tree = try parse(allocator, input, &errors);
    defer tree.deinit();

    try testing.expect(tree.nodes.len == 1);

    const comment = tree.nodes[0].comment;
    try testing.expectEqualStrings("This is a comment", comment.value);
}

test "For loop" {
    const input = "for id, i: x { id }";
    const allocator = testing.allocator;

    var errors = Errors.init(allocator);
    defer errors.deinit();
    const tree = try parse(allocator, input, &errors);
    defer tree.deinit();

    try testing.expect(tree.nodes.len == 1);

    const loop = tree.nodes[0].for_loop;

    try testing.expect(loop.index != null);
    try testing.expectEqualStrings("x", loop.iter.identifier.value);
    try testing.expectEqualStrings("id", loop.capture.identifier.value);
    try testing.expectEqualStrings("i", loop.index.?.identifier.value);
    try testing.expect(loop.block.block_statement.nodes.len == 1);
    try testing.expectEqualStrings("id", loop.block.block_statement.nodes[0].expression.value.identifier.value);
}

test "Enum" {
    const input = "enum{value, another_value, third_value }";
    const allocator = testing.allocator;

    var errors = Errors.init(allocator);
    defer errors.deinit();
    const tree = try parse(allocator, input, &errors);
    defer tree.deinit();

    try testing.expect(tree.nodes.len == 1);

    const enum_val = tree.nodes[0].expression.value.@"enum";
    try testing.expect(enum_val.nodes.len == 3);
    try testing.expectEqualStrings("value", enum_val.nodes[0].identifier.value);
    try testing.expectEqualStrings("another_value", enum_val.nodes[1].identifier.value);
    try testing.expectEqualStrings("third_value", enum_val.nodes[2].identifier.value);
}

test "Enum" {
    const input =
        \\switch(5){
        \\  1: 1 + 1,
        \\  2: {
        \\          if (true) {
        \\              1 + 2
        \\          } 
        \\      },
        \\  3: 2 + 2
        \\}
    ;
    const allocator = testing.allocator;
    var errors = Errors.init(allocator);
    defer errors.deinit();
    const tree = try parse(allocator, input, &errors);
    defer tree.deinit();

    try testing.expect(tree.nodes.len == 1);

    const switch_stmt = tree.nodes[0].switch_statement;
    try testing.expect(switch_stmt.capture == .int_lit);
    try testing.expect(switch_stmt.prongs.len == 3);
    for (switch_stmt.prongs) |p, i| {
        try testing.expectEqual(@as(u64, i + 1), p.switch_prong.left.int_lit.value);
    }
    try testing.expect(switch_stmt.prongs[1].switch_prong.right == .block_statement);
}

test "Node definitions" {
    const cases = [_][]const u8{
        "fn(x: int, y: int)void{}",
        "const x: int = 10",
        "fn(x: []int)fn()string{}",
        "mut y: ?int = nil",
    };

    const allocator = testing.allocator;
    var errors = Errors.init(allocator);
    defer errors.deinit();

    const function = try parse(allocator, cases[0], &errors);
    defer function.deinit();

    const func_type = function.nodes[0].getInnerType();
    const arg_type = function.nodes[0].expression.value.func_lit.params[0].getType();
    try testing.expectEqual(Node._void, func_type.?);
    try testing.expectEqual(Node.integer, arg_type.?);

    const declaration = try parse(allocator, cases[1], &errors);
    defer declaration.deinit();

    const decl_type = declaration.nodes[0].getType();
    try testing.expectEqual(Node.integer, decl_type.?);

    const array = try parse(allocator, cases[2], &errors);
    defer array.deinit();

    const array_type = array.nodes[0].expression.value.func_lit.params[0].getType();
    const scalar_type = array.nodes[0].expression.value.func_lit.params[0].getInnerType();
    const ret_type = array.nodes[0].getInnerType();
    try testing.expectEqual(Node.list, array_type.?);
    try testing.expectEqual(Node.integer, scalar_type.?);
    try testing.expectEqual(Node.string, ret_type.?);

    const optional = try parse(allocator, cases[3], &errors);
    defer optional.deinit();

    const optional_type = optional.nodes[0].getType();
    const optional_child_type = optional.nodes[0].getInnerType();

    try testing.expectEqual(Node.optional, optional_type.?);
    try testing.expectEqual(Node.integer, optional_child_type.?);
}

test "Parse slice expression" {
    const cases = .{
        .{ .input = "const list = []int{1,2,3} const slice = list[1:2]", .expected = .{ 1, 2 } },
        .{ .input = "const list = []int{1,2,3} const slice = list[0:]", .expected = .{ 0, null } },
        .{ .input = "const list = []int{1,2,3} const slice = list[:1]", .expected = .{ null, 1 } },
    };

    inline for (cases) |case| {
        var errors = Errors.init(testing.allocator);
        defer errors.deinit();

        const parsed = try parse(testing.allocator, case.input, &errors);
        defer parsed.deinit();

        const node = parsed.nodes[1].declaration.value.slice;
        try testing.expectEqual(@as(?u64, case.expected[0]), if (node.start) |n| n.int_lit.value else null);
        try testing.expectEqual(@as(?u64, case.expected[1]), if (node.end) |n| n.int_lit.value else null);
    }
}

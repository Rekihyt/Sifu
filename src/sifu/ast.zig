const std = @import("std");
const testing = std.testing;
const syntax = @import("syntax.zig");
const util = @import("../util.zig");
// Store the position of the token in the source as a usize
const Token = syntax.Token(usize);
const Term = syntax.Term;
const Type = syntax.Type;
const Wyhash = std.hash.Wyhash;
const mem = std.mem;
const StringContext = std.array_hash_map.StringContext;
const Allocator = std.mem.Allocator;
const print = util.print;
const err_stream = util.err_stream;

/// The Sifu-specific interpreter Ast, using Tokens as keys and strings as
/// values. Tokens aren't used because the interpreter doesn't need to track
/// meta-info about syntax
pub const Ast = Pat.Node;
pub const Pat = @import("../pattern.zig").StringPattern();
pub const Tree = @import("../tree.zig").Tree(Ast);

test "simple ast to pattern" {
    const term = Token{
        .type = .Name,
        .lit = "My-Token",
        .context = 0,
    };
    _ = term;
    const ast = Ast{
        .key = .{
            .type = .Name,
            .lit = "Some-Other-Token",
            .context = 20,
        },
    };
    _ = ast;
    // _ = Pattern.ofTokenType(term, ast);
}

test "Token equality" {
    const t1 = Token{
        .type = .Name,
        .lit = "Asdf",
        .context = 0,
    };
    const t2 = Token{
        .type = .Name,
        .lit = "Asdf",
        .context = 1,
    };

    try testing.expect(t1.eql(t2));
    try testing.expectEqual(t1.hash(), t2.hash());
}

test "var hashing" {
    var pat = Pat{};
    defer pat.deinit(testing.allocator);
    try pat.map.put(testing.allocator, Ast.ofVar("x"), try Pat.ofKey(
        testing.allocator,
        .{ .lit = "1", .type = .I, .context = undefined },
    ));
    try pat.map.put(testing.allocator, Ast.ofVar("y"), try Pat.ofKey(
        testing.allocator,
        .{ .lit = "2", .type = .I, .context = undefined },
    ));
    try pat.pretty(err_stream);
    if (pat.get(Ast.ofVar(""))) |got| {
        print("Got: ", .{});
        try got.write(err_stream);
        print("\n", .{});
    } else print("Got null\n", .{});
    if (pat.get(Ast.ofVar("x"))) |got| {
        print("Got: ", .{});
        try got.write(err_stream);
        print("\n", .{});
    } else print("Got null\n", .{});
}

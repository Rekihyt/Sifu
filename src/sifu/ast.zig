const std = @import("std");
const testing = std.testing;
const syntax = @import("syntax.zig");
const util = @import("../util.zig");
const Location = syntax.Location;
const Token = syntax.Token(Location);
const Term = syntax.Term;
const Type = syntax.Type;
const Wyhash = std.hash.Wyhash;

pub const Ast = @import("../ast.zig").Ast(
    Token,
    []const u8,
    struct {
        pub fn Map(comptime Val: type) type {
            return std.ArrayHashMapUnmanaged(
                Token,
                Val,
                struct {
                    pub fn hash(self: @This(), key: Token) u32 {
                        _ = self;
                        var hasher = Wyhash.init(0);
                        std.hash.autoHashStrat(&hasher, key, .DeepRecursive);
                        return @truncate(hasher.final());
                    }

                    pub fn eql(
                        self: @This(),
                        k1: Token,
                        k2: Token,
                        b_index: usize,
                    ) bool {
                        _ = b_index;
                        _ = k2;
                        _ = k1;
                        _ = self;
                        return false;
                    }
                },
                true,
            );
        }
    }.Map,
    std.StringArrayHashMapUnmanaged,
    null,
);

test "simple ast to pattern" {
    const term = Token{
        .type = .Val,
        .lit = "My-Token",
        .context = .{ .uri = null, .pos = 0 },
    };
    _ = term;
    const ast = Ast{
        .key = .{
            .type = .Val,
            .lit = "Some-Other-Token",
            .context = .{ .uri = null, .pos = 20 },
        },
    };
    _ = ast;
    // _ = Pattern.ofTokenType(term, ast);
}

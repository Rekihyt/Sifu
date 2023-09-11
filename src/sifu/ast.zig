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

/// The Sifu-specific interpreter Ast, using Tokens as keys and strings as
/// values.
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
                        _ = self;
                        return k1.eql(k2);
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
        .context = 0,
    };
    _ = term;
    const ast = Ast{
        .key = .{
            .type = .Val,
            .lit = "Some-Other-Token",
            .context = 20,
        },
    };
    _ = ast;
    // _ = Pattern.ofTokenType(term, ast);
}

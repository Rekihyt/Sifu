pub const Errors = @import("sifu/errors.zig").Errors;

test "Submodules" {
    _ = @import("sifu/errors.zig");
    _ = @import("sifu/parser.zig");
    _ = @import("sifu/lexer.zig");
    _ = @import("sifu/ast.zig");
    _ = @import("sifu/interpreter.zig");
}

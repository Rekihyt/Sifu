pub const compiler = @import("sifu/compiler.zig");
pub const Errors = @import("sifu/errors.zig").Errors;

test "Submodules" {
    _ = @import("sifu/compiler.zig");
    _ = @import("sifu/errors.zig");
    _ = @import("sifu/parser.zig");
    _ = @import("sifu/Term.zig");
}

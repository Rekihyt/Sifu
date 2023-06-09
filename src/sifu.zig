pub const Errors = @import("sifu/errors.zig").Errors;

test "Submodules" {
    _ = @import("sifu/errors.zig");
    _ = @import("sifu/parser.zig");
    _ = @import("sifu/tokens.zig");
}

pub const compiler = @import("Sifu/compiler.zig");
pub const Errors = @import("Sifu/errors.zig").Errors;

test "Submodules" {
    _ = @import("Sifu/compiler.zig");
    _ = @import("Sifu/errors.zig");
}

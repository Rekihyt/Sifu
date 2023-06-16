const std = @import("std");

test "Submodules" {
    _ = @import("sifu.zig");
    _ = @import("util.zig");
    _ = @import("pattern.zig");
}

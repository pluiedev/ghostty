pub usingnamespace @import("foundation/string.zig");
pub usingnamespace @import("foundation/type.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

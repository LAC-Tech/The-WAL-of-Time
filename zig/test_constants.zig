const std = @import("std");

pub fn main() void {
    // Check what's available in different namespaces
    std.debug.print("=== std.os.linux ===\n");
    // std.debug.print("EBADF: {}\n", .{std.os.linux.EBADF}); // This will fail if not available

    std.debug.print("=== std.c ===\n");
    std.debug.print("E.BADFD: {}\n", .{std.c.E.BADFD});

    std.debug.print("=== std.posix ===\n");
    std.debug.print("EBADF: {}\n", .{std.posix.EBADF});
}

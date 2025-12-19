const std = @import("std");
const mem = std.mem;

const config = @import("config.zig");

pub const State = struct {
    buffers: [][config.buf_size]u8,

    pub fn init(allocator: mem.Allocator) !State {
        return .{
            .buffers = try allocator.alloc(
                [config.buf_size]u8,
                config.buf_count,
            ),
        };
    }

    pub fn deinit(self: State, allocator: mem.Allocator) void {
        allocator.free(self.buffers);
    }
};

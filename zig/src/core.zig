const std = @import("std");
const mem = std.mem;

const config = @import("config.zig");
const io = @import("io.zig");

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

    pub fn transition(self: *State, res: io.Response, server_fd: i32) io.Requests {
        var reqs = io.Requests.init();
        const user_data = res.user_data;

        switch (user_data.syscall) {
            .accept => {
                const client_fd = res.syscall_result;
                if (client_fd >= 0) reqs.append(.{ .recv = .{ .client_fd = client_fd } });
                if (res.restart_needed) reqs.append(.{ .re_arm_accept = .{ .server_fd = server_fd } });
            },
            .recv => {
                const client_fd = user_data.msg.recv.client_fd;
                if (res.syscall_result > 0) {
                    reqs.append(.{ .send = .{
                        .client_fd = client_fd,
                        .buf_id = res.buf_id,
                        .data = self.buffers[res.buf_id][0..@intCast(res.syscall_result)],
                    } });
                    if (res.restart_needed) reqs.append(.{ .recv = .{ .client_fd = client_fd } });
                } else {
                    reqs.append(.{ .release_buf = .{ .buf_id = res.buf_id } });
                    if (res.restart_needed) reqs.append(.{ .close = .{ .client_fd = client_fd } });
                }
            },
            .send => reqs.append(.{ .release_buf = .{ .buf_id = user_data.msg.send.buf_id } }),
            .close => {},
        }
        return reqs;
    }
};

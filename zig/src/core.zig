const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const config = @import("config.zig");
const io = @import("io.zig");

pub const State = struct {
    buffers: [][config.buf_size]u8,
    req_buf: [2]io.Request,
    reqs: std.ArrayListUnmanaged(io.Request),

    pub fn init(allocator: mem.Allocator) !State {
        var req_buf: [2]io.Request = undefined;
        const reqs = std.ArrayListUnmanaged(io.Request).initBuffer(&req_buf);

        return .{
            .buffers = try allocator.alloc(
                [config.buf_size]u8,
                config.buf_count,
            ),
            .req_buf = req_buf,
            .reqs = reqs,
        };
    }

    pub fn deinit(self: *State, allocator: mem.Allocator) void {
        allocator.free(self.buffers);
    }

    pub fn transition(
        self: *State,
        res: io.Response,
        server_fd: i32,
    ) []const io.Request {
        self.reqs.clearRetainingCapacity();

        const user_data = res.user_data;

        switch (user_data.syscall) {
            .accept => {
                const client_fd = res.syscall_result;
                if (client_fd >= 0) {
                    self.reqs.appendAssumeCapacity(.{
                        .recv = .{ .client_fd = client_fd },
                    });
                }
                if (res.restart_needed) {
                    self.reqs.appendAssumeCapacity(.{
                        .re_arm_accept = .{ .server_fd = server_fd },
                    });
                }
            },
            .recv => {
                const client_fd = user_data.msg.recv.client_fd;
                if (res.syscall_result > 0) {
                    const len: usize = @intCast(res.syscall_result);
                    self.reqs.appendAssumeCapacity(.{
                        .send = .{
                            .client_fd = client_fd,
                            .buf_id = res.buf_id,
                            .data = self.buffers[res.buf_id][0..len],
                        },
                    });
                    if (res.restart_needed) {
                        self.reqs.appendAssumeCapacity(.{
                            .recv = .{ .client_fd = client_fd },
                        });
                    }
                } else {
                    self.reqs.appendAssumeCapacity(.{
                        .release_buf = .{ .buf_id = res.buf_id },
                    });
                    if (res.restart_needed) {
                        self.reqs.appendAssumeCapacity(.{
                            .close = .{ .client_fd = client_fd },
                        });
                    }
                }
            },
            .send => self.reqs.appendAssumeCapacity(.{
                .release_buf = .{ .buf_id = user_data.msg.send.buf_id },
            }),
            .close => {},
        }

        return self.reqs.items;
    }
};

test "no memory leak with state" {
    var state = try State.init(testing.allocator);
    defer state.deinit(testing.allocator);
}

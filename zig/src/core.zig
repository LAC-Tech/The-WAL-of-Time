const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const testing = std.testing;

const config = @import("config.zig");
const io = @import("io.zig");

pub const StateMachine = struct {
    server_fd: i32,

    pub fn init(server_fd: i32) StateMachine {
        return .{ .server_fd = server_fd };
    }

    pub fn transition(
        self: *StateMachine,
        res: io.Res,
    ) io.Req {
        const user_data = res.user_data;

        switch (user_data.syscall) {
            .accept => {
                const client_fd = res.syscall_result;
                if (client_fd >= 0) {
                    self.pushReq(.{
                        .recv = .{ .client_fd = client_fd },
                    });
                }
                if (res.restart_needed) {
                    self.pushReq(.{
                        .accept = .{ .server_fd = self.server_fd },
                    });
                }
            },
            .recv => {
                const client_fd = user_data.msg.recv.client_fd;
                // Recv has completed successfully
                if (res.syscall_result > 0) {
                    self.pushReq(.{
                        .send = .{
                            .client_fd = client_fd,
                            .buf_id = res.buf_id,
                            .len = @intCast(res.syscall_result),
                        },
                    });
                    if (res.restart_needed) {
                        self.pushReq(.{
                            .recv = .{ .client_fd = client_fd },
                        });
                    }
                }
                // No messages available OR peer has performed orderly shutdown
                else {
                    self.pushReq(.{
                        .release_buf = .{ .buf_id = res.buf_id },
                    });
                    if (res.restart_needed) {
                        self.pushReq(.{
                            .close = .{ .client_fd = client_fd },
                        });
                    }
                }
            },
            .send => return .{
                .release_buf = .{ .buf_id = user_data.msg.send.buf_id },
            },
            .close => return .no_op,
        }
    }
};

// In linux, BufRing is tightly coupled to the OS
// But that won't be the case for other implementations, ie sim
pub fn execute(
    async_io: anytype,
    buf_ring: anytype,
    req: io.Req,
) !void {
    switch (req) {
        .no_op => {},
        .recv => |r| {
            try async_io.recv(io.UserData.recv(r.client_fd));
            _ = try async_io.submit();
        },
        .send => |s| {
            const ud = io.UserData.send(s.buf_id);
            const data = buf_ring.get_buf(s.buf_id)[0..s.len];
            try async_io.send(s.client_fd, data, ud);
            _ = try async_io.submit();
        },
        .close => |c| {
            try async_io.close(c.client_fd, io.UserData.close());
            _ = try async_io.submit();
        },
        .accept => |a| {
            try async_io.accept(a.server_fd, io.UserData.accept());
            _ = try async_io.submit();
        },
        .release_buf => |b| {
            buf_ring.release(b.buf_id);
        },
    }
}

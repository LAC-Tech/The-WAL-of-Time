const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const testing = std.testing;

const config = @import("config.zig");
const io = @import("io.zig");

pub const StateMachine = struct {
    server_fd: i32,
    req_buf: [2]io.Req,

    fn fill(self: *StateMachine, reqs: []const io.Req) []const io.Req {
        @memcpy(self.req_buf[0..reqs.len], reqs);
        return self.req_buf[0..reqs.len];
    }

    pub fn init(server_fd: i32) StateMachine {
        return .{ .server_fd = server_fd, .req_buf = undefined };
    }

    pub fn transition(
        self: *StateMachine,
        res: io.Res,
    ) []const io.Req {
        const user_data = res.user_data;

        switch (user_data.syscall) {
            .accept => {
                if (res.result >= 0) {
                    const client_fd = res.result;
                    if (res.more) {
                        return self.fill(&.{io.Req.init_recv(client_fd)});
                    } else {
                        return self.fill(&.{
                            io.Req.init_recv(client_fd),
                            .{ .accept = .{ .server_fd = self.server_fd } },
                        });
                    }
                } else {
                    // Scenario 3: Error
                    return self.fill(&.{
                        .{ .accept = .{ .server_fd = self.server_fd } },
                    });
                }
            },
            .recv => {
                const client_fd = user_data.msg.recv.client_fd;
                if (res.result > 0) {
                    const send_req = io.Req{
                        .send = .{
                            .client_fd = client_fd,
                            .buf_id = res.buf_id,
                            .len = @intCast(res.result),
                        },
                    };
                    if (res.more) {
                        return self.fill(&.{send_req});
                    } else {
                        return self.fill(&.{
                            send_req,
                            .{ .recv = .{ .client_fd = client_fd } },
                        });
                    }
                } else {
                    // result <= 0: EOF or error
                    const release_req = io.Req{
                        .release_buf = .{ .buf_id = res.buf_id },
                    };
                    const close_req = io.Req{
                        .close = .{ .client_fd = client_fd },
                    };

                    if (res.more) {
                        return self.fill(&.{ release_req, close_req });
                    } else {
                        // Case is unlikely nless recv failed immediately
                        return self.fill(&.{ release_req, close_req });
                    }
                }
            },
            .send => return self.fill(&.{
                .{ .release_buf = .{ .buf_id = user_data.msg.send.buf_id } },
            }),
            .close => return &.{},
        }
    }
};

pub fn execute(
    async_io: anytype,
    buf_ring: anytype,
    reqs: []const io.Req,
) !void {
    for (reqs) |req| {
        switch (req) {
            .no_op => {},
            .recv => |r| {
                try async_io.recv(io.UserData.recv(r.client_fd));
            },
            .send => |s| {
                const ud = io.UserData.send(s.buf_id);
                const data = buf_ring.get_buf(s.buf_id)[0..s.len];
                try async_io.send(s.client_fd, data, ud);
            },
            .close => |c| {
                try async_io.close(c.client_fd, io.UserData.close());
            },
            .accept => |a| {
                try async_io.accept(a.server_fd, io.UserData.accept());
            },
            .release_buf => |b| {
                buf_ring.release(b.buf_id);
            },
        }
    }
    _ = try async_io.submit();
}

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
        const result = res.result;
        const user_data = res.user_data;
        const syscall = user_data.syscall;

        switch (syscall) {
            .accept => {
                if (result >= 0) {
                    return if (res.more)
                        self.fill(&.{
                            .{ .recv = .{ .client_fd = result } },
                        })
                    else
                        self.fill(&.{
                            .{ .recv = .{ .client_fd = result } },
                            .{ .accept = .{ .server_fd = self.server_fd } },
                        });
                } else {
                    // Error; resubmit
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

test "StateMachine transition returns multiple requests" {
    var state_machine = StateMachine.init(3);

    // Scenario 1: Accept success, more coming
    const accept_res = io.Res{
        .user_data = io.fromU64(io.UserData.accept().toU64()),
        .more = true,
        .buf_id = 0,
        .result = 4, // client_fd
    };

    const reqs1 = state_machine.transition(accept_res);
    try testing.expectEqual(@as(usize, 1), reqs1.len);
    try testing.expect(reqs1[0] == .recv);
    try testing.expectEqual(@as(i32, 4), reqs1[0].recv.client_fd);

    // Scenario 2: Recv success, no more coming (needs re-arm)
    const recv_res = io.Res{
        .user_data = io.fromU64(io.UserData.recv(4).toU64()),
        .more = false,
        .buf_id = 1,
        .result = 10, // bytes received
    };

    const reqs2 = state_machine.transition(recv_res);
    try testing.expectEqual(@as(usize, 2), reqs2.len);
    try testing.expect(reqs2[0] == .send);
    try testing.expect(reqs2[1] == .recv);
    try testing.expectEqual(@as(i32, 4), reqs2[1].recv.client_fd);

    // Test send completion
    const send_res = io.Res{
        .user_data = io.fromU64(io.UserData.send(1).toU64()),
        .more = false,
        .buf_id = 0,
        .result = 10, // bytes sent
    };

    const reqs3 = state_machine.transition(send_res);
    try testing.expectEqual(@as(usize, 1), reqs3.len);
    try testing.expect(reqs3[0] == .release_buf);
    try testing.expectEqual(@as(u16, 1), reqs3[0].release_buf.buf_id);
}

test "StateMachine recv failure handling" {
    var state_machine = StateMachine.init(3);

    // Test recv failure (peer shutdown)
    const recv_res = io.Res{
        .user_data = io.fromU64(io.UserData.recv(4).toU64()),
        .more = true,
        .buf_id = 2,
        .result = 0, // connection closed
    };

    const reqs1 = state_machine.transition(recv_res);
    try testing.expectEqual(@as(usize, 2), reqs1.len);
    try testing.expect(reqs1[0] == .release_buf);
    try testing.expect(reqs1[1] == .close);
}

const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const testing = std.testing;

const config = @import("config.zig");
const io = @import("io.zig");

pub const State = struct {
    buffers: [][config.buf_size]u8,
    req_buf: [2]io.Req,
    reqs: std.ArrayListUnmanaged(io.Req),

    pub fn init(allocator: mem.Allocator) !State {
        var req_buf: [2]io.Req = undefined;
        // TODO: there are two of these.. do we need all this?
        const reqs = std.ArrayListUnmanaged(io.Req).initBuffer(&req_buf);

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

    // Stupid function because zig hasAbsurdlyLongMethodNames
    fn pushReq(self: *State, req: io.Req) void {
        self.reqs.appendAssumeCapacity(req);
    }

    pub fn transition(
        self: *State,
        res: io.Res,
        server_fd: i32,
    ) []const io.Req {
        self.reqs.clearRetainingCapacity();

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
                        .accept = .{ .server_fd = server_fd },
                    });
                }
            },
            .recv => {
                const client_fd = user_data.msg.recv.client_fd;
                // Recv has completed successfully
                if (res.syscall_result > 0) {
                    const buf = self.buffers[res.buf_id];
                    const len: usize = @intCast(res.syscall_result);
                    self.pushReq(.{
                        .send = .{
                            .client_fd = client_fd,
                            .buf_id = res.buf_id,
                            .data = buf[0..len],
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
            .send => self.pushReq(.{
                .release_buf = .{ .buf_id = user_data.msg.send.buf_id },
            }),
            .close => {},
        }

        return self.reqs.items;
    }

    pub fn execute(self: State, req: io.Req, aio: anytype) !void {
        switch (req) {
            .recv => |r| {
                try aio.recv(io.UserData.recv(r.client_fd));
            },
            .send => |s| {
                const ud = io.UserData.send(s.buf_id);
                try aio.send(s.client_fd, s.data, ud);
            },
            .close => |c| {
                try aio.close(c.client_fd, io.UserData.close());
            },
            .accept => |a| {
                try aio.accept(a.server_fd, io.UserData.accept());
            },
            .release_buf => |b| {
                aio.buf_ring.release(b.buf_id, self.buffers);
            },
        }
    }
};

test "no memory leak with state" {
    var state = try State.init(testing.allocator);
    defer state.deinit(testing.allocator);
}

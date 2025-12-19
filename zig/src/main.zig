const std = @import("std");
const debug = std.debug;
const heap = std.heap;
const math = std.math;
const mem = std.mem;
const meta = std.meta;
const Random = std.Random;
const testing = std.testing;

const config = @import("./config.zig");

const core = @import("core.zig");
const io = @import("io.zig");
const linux = @import("linux.zig");

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var state = try core.State.init(allocator);
    defer state.deinit(allocator);

    var aio = try linux.AsyncIO.init(state.buffers);
    defer aio.deinit();

    const server = try linux.Server.init();
    defer server.deinit();
    debug.print("Listening on port {d}\n", .{config.port});

    try aio.accept(server.fd, io.Accept.init());

    while (true) {
        _ = try aio.submit();
        const res = try aio.waitForRes();

        const requests = state.transition(res, server.fd);

        for (requests.items[0..requests.len]) |req| {
            switch (req) {
                .none => {},
                .recv => |r| {
                    aio.recv(io.Recv.init(r.client_fd)) catch |err| {
                        debug.print(
                            "failed to queue recv for fd {d}: {}\n",
                            .{ r.client_fd, err },
                        );
                        aio.close(r.client_fd, io.Close.init()) catch {};
                    };
                },
                .send => |s| {
                    const msg = io.Send.init(s.buf_id);
                    aio.send(s.client_fd, s.data, msg) catch |err| {
                        debug.print(
                            "failed to queue send for fd {d}: {}\n",
                            .{ s.client_fd, err },
                        );
                        aio.release_buf(s.buf_id, state.buffers);
                    };
                },
                .close => |c| {
                    aio.close(c.client_fd, io.Close.init()) catch |err| {
                        debug.print(
                            "failed to queue close for fd {d}: {}\n",
                            .{ c.client_fd, err },
                        );
                    };
                },
                .re_arm_accept => |a| {
                    aio.accept(a.server_fd, io.Accept.init()) catch |err| {
                        debug.print("failed to re-arm accept: {}\n", .{err});
                    };
                },
                .release_buf => |b| {
                    aio.release_buf(b.buf_id, state.buffers);
                },
            }
        }
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}

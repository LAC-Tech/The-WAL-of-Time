const std = @import("std");

const net = std.net;
const debug = std.debug;
const mem = std.mem;

const core = @import("./core.zig");
const limits = @import("limits.zig");

pub fn initial_reqs(comptime InMem: type, aio: anytype) !void {
    const aio_req = InMem.initial_aio_req();
    _ = try aio.accept_multishot(aio_req);
    debug.assert(try aio.flush() == 1);
}

pub fn step(
    comptime FD: type,
    res: core.Res(FD),
    aio: anytype,
) !void {
    switch (res) {
        .accept => |ctx| {
            // Let client know they can connect.
            _ = try aio.send(ctx.reqs.send);

            debug.assert(1 == try aio.flush());
        },
        .send => |ctx| {
            // so we can receive a message
            _ = try aio.recv(ctx.reqs.recv);

            debug.assert(1 == try aio.flush());
        },
        .recv => |ctx| {
            debug.print("received: {s}", .{ctx.msg});

            // So we can receive more messages
            _ = try aio.recv(ctx.reqs.recv);

            debug.assert(1 == try aio.flush());
        },
    }
}

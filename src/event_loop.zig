const std = @import("std");

const net = std.net;
const debug = std.debug;
const mem = std.mem;

const core = @import("./core.zig");
const limits = @import("limits.zig");

pub fn initial_reqs(comptime InMem: type, aio: anytype) !void {

    // TODO: multishot accept?
    const aio_reqs = InMem.initial_aio_reqs();
    //for (aio_reqs) |aio_req| {
    //    _ = try aio.accept(aio_req);
    //}

    //debug.assert(try aio.flush() == limits.max_clients);

    _ = try aio.accept_multishot(aio_reqs[0]);
    debug.assert(try aio.flush() == 1);
}

pub fn step(
    comptime FD: type,
    res: core.Res(FD),
    aio: anytype,
) !void {
    switch (res) {
        .client_connected => |ctx| {
            // Replace itself on the queue, so other clients can connect
            _ = try aio.accept(ctx.reqs.accept);
            // Let client know they can connect.
            _ = try aio.send(ctx.reqs.send);

            debug.assert(2 == try aio.flush());
        },
        .client_ready => |ctx| {
            // so we can receive a message
            _ = try aio.recv(ctx.reqs.recv);

            debug.assert(1 == try aio.flush());
        },
        .client_msg => |ctx| {
            debug.print("received: {s}", .{ctx.msg});

            // So we can receive more messages
            _ = try aio.recv(ctx.reqs.recv);

            debug.assert(1 == try aio.flush());
        },
    }
}

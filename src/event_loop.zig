const std = @import("std");

const net = std.net;
const debug = std.debug;
const mem = std.mem;

const core = @import("./core.zig");
const limits = @import("limits.zig");

pub fn run(
    allocator: mem.Allocator,
    comptime FD: type,
    comptime fd_eql: fn (FD, FD) bool,
    aio: anytype,
) !void {
    const InMem = core.InMem(FD, fd_eql);
    var in_mem = try InMem.init(allocator);
    defer in_mem.deinit(allocator);

    // TODO: multishot accept?
    for (InMem.initial_aio_reqs()) |aio_req| {
        _ = try aio.accept(aio_req);
    }

    debug.assert(try aio.flush() == limits.max_clients);

    debug.print("The WAL weaves as the WAL wills\n", .{});

    while (true) {
        const aio_res = try aio.wait_for_res();
        const res = try in_mem.res_with_ctx(aio_res);

        try step(FD, res, aio);
    }
}

fn step(
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

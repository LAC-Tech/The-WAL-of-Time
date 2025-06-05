const std = @import("std");

const net = std.net;
const debug = std.debug;
const mem = std.mem;

const core = @import("./core.zig");
const limits = @import("limits.zig");

pub fn run(
    allocator: mem.Allocator,
    comptime fd: type,
    comptime fd_eql: fn (fd, fd) bool,
    aio: anytype,
) !void {
    const RunTime = core.RunTime(fd, fd_eql);
    var rt = try RunTime.init(allocator);
    defer rt.deinit(allocator);

    // TODO: multishot accept?
    for (RunTime.initial_aio_reqs()) |aio_req| {
        _ = try aio.accept(aio_req);
    }

    debug.assert(try aio.flush() == limits.max_clients);

    debug.print("The WAL weaves as the WAL wills\n", .{});

    while (true) {
        const aio_res = try aio.wait_for_res();

        // TODO: give aio_res directly to core and return tagged enum annotated
        // with data needed to do further dispatches on the aio
        const usr_data: core.UsrData = @bitCast(aio_res.usr_data);

        switch (usr_data.tag) {
            .client_connected => {
                const client_fd: fd = aio_res.rc;
                const send_req = try rt.register_client(client_fd);

                // Replace itself on the queue, so other clients can connect
                _ = try aio.accept(core.UsrData.client_connected);

                // Let client know they can connect.
                _ = try aio.send(send_req);

                debug.assert(2 == try aio.flush());
            },
            .client_ready => {
                const client_slot = usr_data.payload.client_slot;
                const rt_res = rt.prepare_client(client_slot);

                // so we can receive a message
                _ = try aio.recv(rt_res);

                debug.assert(1 == try aio.flush());
            },
            .client_msg => {
                const client_slot = usr_data.payload.client_slot;

                debug.print("received: {s}", .{rt.recv_buf});

                const rt_res = rt.prepare_client(client_slot);

                // So we can receive more messages
                _ = try aio.recv(rt_res);

                debug.assert(1 == try aio.flush());
            },
        }
    }
}

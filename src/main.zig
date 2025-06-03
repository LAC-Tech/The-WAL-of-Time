const std = @import("std");

const net = std.net;
const debug = std.debug;
const mem = std.mem;

const core = @import("./core.zig");
const limits = @import("limits.zig");
const linux = @import("./linux.zig");

pub fn main() !void {
    var aio = try linux.AsyncIO.init();
    defer aio.deinit();
    try event_loop(&aio);
}

fn event_loop(aio: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var rt = try core.RunTime(linux.fd_t, linux.fd_eql).init(allocator);
    defer rt.deinit(allocator);

    for (0..limits.max_clients) |_| {
        _ = try aio.accept(core.UsrData.client_connected);
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
                const client_fd: linux.fd_t = aio_res.rc;
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

const std = @import("std");

const net = std.net;
const debug = std.debug;
const mem = std.mem;

const core = @import("./core.zig");
const limits = @import("./limits.zig");
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

        switch (try rt.process_aio_res(aio_res)) {
            .client_connected => |aio_reqs| {
                // Replace itself on the queue, so other clients can connect
                _ = try aio.accept(aio_reqs.accept);
                // Let client know they can connect.
                _ = try aio.send(aio_reqs.send);

                debug.assert(2 == try aio.flush());
            },
            .client_ready => |recv| {
                // so we can receive more a message
                _ = try aio.recv(recv);
                debug.assert(1 == try aio.flush());
            },
            .client_msg => |recv| {
                // So we can receive more messages
                _ = try aio.recv(recv);
                debug.assert(1 == try aio.flush());
            },
        }
    }
}

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

const RunTime = core.RunTime(linux.fd_t, linux.fd_eql);

fn event_loop(aio: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var rt = try RunTime.init(allocator);
    defer rt.deinit(allocator);

    for (RunTime.initial_aio_reqs()) |aio_req| {
        _ = try aio.accept(aio_req);
    }

    debug.assert(try aio.flush() == limits.max_clients);

    debug.print("The WAL weaves as the WAL wills\n", .{});

    while (true) {
        const aio_res = try aio.wait_for_res();

        switch (try rt.process_aio_res(aio_res)) {
            .connection_accepted => |rt_res| {
                const accept, const send = rt_res.reqs;

                // Replace itself on the queue, so other clients can connect
                _ = try aio.accept(accept);
                // Let client know they can connect.
                _ = try aio.send(send);

                debug.assert(2 == try aio.flush());
            },
            .ready_to_recv => |rt_res| {
                // so we can receive more a message
                _ = try aio.recv(rt_res.req);
                debug.assert(1 == try aio.flush());
            },
            .msg_available => |rt_res| {
                // TODO: log this or something?
                debug.print("received: {s}", .{rt_res.msg});

                // So we can receive more messages
                _ = try aio.recv(rt_res.req);
                debug.assert(1 == try aio.flush());
            },
        }
    }
}

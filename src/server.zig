const std = @import("std");
const builtin = @import("builtin");

const net = std.net;
const debug = std.debug;
const mem = std.mem;

const core = @import("./core.zig");
const linux = @import("./linux.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    switch (builtin.os.tag) {
        .linux => {
            var aio = try linux.AsyncIO.init();
            defer aio.deinit();

            var sm = try core.StateMachine(
                linux.FD,
                linux.Req,
                .{ .max_clients = 2, .write_buf_size = 64 },
            ).init(allocator);
            defer sm.deinit(allocator);

            const initiaReqs = try sm.initial_aio_req(aio.server_fd);
            debug.assert(try aio.send(initiaReqs) == initiaReqs.len);

            debug.print("The WAL weaves as the WAL wills\n", .{});

            while (true) {
                const res = try aio.await_res();
                const reqs = try sm.transition(res);
                debug.assert(try aio.send(reqs) == reqs.len);
            }
        },
        else => @panic("No async io for this OS"),
    }
}

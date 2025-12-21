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

    var state = try core.State.init();

    var aio = try linux.AsyncIO.init();
    defer aio.deinit();

    var buf_ring = try linux.BufRing.init(allocator, aio.io_uring_fd());
    defer buf_ring.deinit(allocator);

    const server = try linux.Server.init();
    defer server.deinit();
    debug.print("Listening on port {d}\n", .{config.port});

    try aio.accept(server.fd, io.UserData.accept());
    _ = try aio.submit();

    while (true) {
        const res = try aio.waitForRes();
        const reqs = state.transition(res, server.fd);

        for (reqs) |req| {
            try core.execute(&aio, &buf_ring, req);
        }
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}

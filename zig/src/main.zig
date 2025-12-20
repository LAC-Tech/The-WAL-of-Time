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

    try aio.accept(server.fd, io.UserData.accept());

    while (true) {
        _ = try aio.submit();
        const res = try aio.waitForRes();
        const reqs = state.transition(res, server.fd);

        for (reqs) |req| {
            try aio.execute(req, state.buffers);
        }
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}

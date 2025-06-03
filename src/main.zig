const std = @import("std");

const net = std.net;
const debug = std.debug;
const mem = std.mem;

const event_loop = @import("./event_loop.zig");
const linux = @import("./linux.zig");

pub fn main() !void {
    var aio = try linux.AsyncIO.init();
    defer aio.deinit();
    try event_loop.run(linux.fd_t, linux.fd_eql, &aio);
}

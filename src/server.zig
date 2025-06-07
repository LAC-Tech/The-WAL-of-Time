const std = @import("std");

const net = std.net;
const debug = std.debug;
const mem = std.mem;

const event_loop = @import("./event_loop.zig");
const sim = @import("./sim.zig");
const linux = @import("./linux.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var aio = try linux.AsyncIO.init();
    defer aio.deinit();
    try event_loop.run(allocator, linux.FD, linux.fd_eql, &aio);
}

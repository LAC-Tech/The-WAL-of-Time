const std = @import("std");

const net = std.net;
const debug = std.debug;
const mem = std.mem;

const event_loop = @import("./event_loop.zig");
const dst = @import("./sim.zig");
const linux = @import("./linux.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.process.args();
    _ = args.skip(); // first arg

    if (args.next()) |arg| {
        const seed: u64 = std.fmt.parseInt(u64, arg, 10) catch {
            @panic("arg must be an unsigned integer");
        };
        var aio = try dst.AsyncIO.init(allocator, seed);
        defer aio.deinit(allocator);
        try event_loop.run(allocator, dst.FD, dst.fd_eql, &aio);
    } else {
        var aio = try linux.AsyncIO.init();
        defer aio.deinit();
        try event_loop.run(allocator, linux.FD, linux.fd_eql, &aio);
    }
}

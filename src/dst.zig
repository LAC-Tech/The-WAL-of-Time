const std = @import("std");

const sim = @import("./sim.zig");
const event_loop = @import("./event_loop.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.process.args();
    _ = args.skip();

    const seed: u64 = if (args.next()) |arg|
        std.fmt.parseInt(u64, arg, 10) catch {
            @panic("arg must be an unsigned integer");
        }
    else
        @intCast(std.time.nanoTimestamp());

    var aio = try sim.AsyncIO.init(allocator, seed);
    defer aio.deinit(allocator);
    try event_loop.run(allocator, sim.FD, sim.fd_eql, &aio);
}

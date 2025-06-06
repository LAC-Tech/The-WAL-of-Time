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
        std.fmt.parseInt(u64, arg, 16) catch {
            @panic("arg must be an unsigned integer");
        }
    else
        std.crypto.random.int(u64);

    std.debug.print("Seed = {x}\n", .{seed});

    var time = sim.Time.init();
    var aio = try sim.AsyncIO.init(allocator, seed, &time);
    defer aio.deinit(allocator);
    try event_loop.run(allocator, sim.FD, sim.fd_eql, &aio);
}

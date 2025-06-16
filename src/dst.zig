const std = @import("std");
const debug = std.debug;

const core = @import("./core.zig");
const sim = @import("./sim.zig");

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

    var rng = std.Random.DefaultPrng.init(seed);

    var aio = sim.AsyncIO.init(allocator, &rng);
    defer aio.deinit();

    const InMem = core.InMem(sim.FD, sim.fd_eql, sim.Req);
    var in_mem = try InMem.init(allocator);
    defer in_mem.deinit(allocator);

    const initiaReqs = try in_mem.initial_aio_req(aio.socket_fd);
    debug.assert(try aio.send(initiaReqs) == initiaReqs.len);
}

test {
    std.testing.refAllDecls(@This());
}

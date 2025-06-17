const std = @import("std");
const debug = std.debug;

const core = @import("./core.zig");
const sim = @import("./sim.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const seed = get_seed();
    std.debug.print("Seed = {x}\n", .{seed});

    var rng = std.Random.DefaultPrng.init(seed);
    var ticks: u64 = 0;

    var aio = try sim.AsyncIO.init(&rng, &ticks);
    //defer aio.deinit();

    const InMem = core.InMem(sim.FD, sim.Req);
    var in_mem = try InMem.init(allocator);
    defer in_mem.deinit(allocator);

    const initiaReqs = try in_mem.initial_aio_req(aio.socket_fd);
    debug.assert(try aio.send(initiaReqs) == initiaReqs.len);

    while (ticks < 1000) : (ticks += 1) {
        _ = try aio.tick();
    }
}

fn get_seed() u64 {
    var args = std.process.args();
    _ = args.skip();

    return if (args.next()) |arg|
        std.fmt.parseInt(u64, arg, 16) catch {
            @panic("arg must be an unsigned integer");
        }
    else
        std.crypto.random.int(u64);
}

test {
    std.testing.refAllDecls(@This());
}

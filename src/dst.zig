const std = @import("std");
const crypto = std.crypto;
const debug = std.debug;
const fmt = std.fmt;
const heap = std.heap;
const process = std.process;
const Random = std.Random;
const testing = std.testing;

const core = @import("./core.zig");
const sim = @import("./sim.zig");

pub fn main() !void {
    //var arena = heap.ArenaAllocator.init(heap.page_allocator);
    //defer arena.deinit();
    //const allocator = arena.allocator();

    //const seed = get_seed();
    //debug.print("Seed = {x}\n", .{seed});

    //var rng = Random.DefaultPrng.init(seed);
    //var ticks: u64 = 0;

    //var aio = try sim.AsyncIO.init(&rng, &ticks);

    //var sm = try core.StateMachine(
    //    sim.FD,
    //    sim.Req,
    //    .{ .max_clients = 2, .write_buf_size = 64 },
    //).init(allocator);
    //defer sm.deinit(allocator);

    //const initiaReqs = try sm.initial_transition(aio.server_fd);
    //debug.assert(try aio.send(initiaReqs) == initiaReqs.len);

    //while (ticks < 1000) : (ticks += 1) {
    //    const res = try aio.tick() orelse continue;
    //    const reqs = try sm.transition(res);
    //    debug.assert(try aio.send(reqs) == reqs.len);
    //}

    const limits: core.Limits = .{ .max_client_conns = 2 };

    debug.print("{any}", .{limits});
}

fn get_seed() u64 {
    var args = process.args();
    _ = args.skip();

    const seed = args.next() orelse return crypto.random.int(u64);

    return fmt.parseInt(u64, seed, 16) catch {
        @panic("arg must be an unsigned integer");
    };
}

test {
    testing.refAllDecls(@This());
}

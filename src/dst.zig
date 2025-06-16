const std = @import("std");

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

    var aio = sim.AsyncIO.init();
    defer aio.deinit();

    const InMem = core.InMem(sim.FD, sim.fd_eql, sim.Req);
    var in_mem = try InMem.init(allocator);
    defer in_mem.deinit(allocator);

    //const initiaReqs = try in_mem.initial_aio_req(aio.socket_fd);
    //debug.assert(try aio.flush(initiaReqs) == initiaReqs.len);

    //debug.print("The WAL weaves as the WAL wills\n", .{});

    //while (true) {
    //    const aio_res = try aio.wait_for_res();
    //    const reqs = try in_mem.res_with_ctx(aio_res);
    //    debug.assert(try aio.flush(reqs) == reqs.len);
    //}

    @panic("TODO");
}

test {
    std.testing.refAllDecls(@This());
}

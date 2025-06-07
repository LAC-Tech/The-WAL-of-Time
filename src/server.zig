const std = @import("std");
const builtin = @import("builtin");

const net = std.net;
const debug = std.debug;
const mem = std.mem;

const core = @import("./core.zig");
const event_loop = @import("./event_loop.zig");
const sim = @import("./sim.zig");
const linux = @import("./linux.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    switch (builtin.os.tag) {
        .linux => {
            var aio = try linux.AsyncIO.init();
            defer aio.deinit();

            const InMem = core.InMem(linux.FD, linux.fd_eql);
            var in_mem = try InMem.init(allocator);
            defer in_mem.deinit(allocator);

            try event_loop.initial_reqs(InMem, &aio);

            debug.print("The WAL weaves as the WAL wills\n", .{});

            while (true) {
                const aio_res = try aio.wait_for_res();
                const res = try in_mem.res_with_ctx(aio_res);

                try event_loop.step(linux.FD, res, &aio);
            }
        },
        else => @panic("No async io for this OS"),
    }
}

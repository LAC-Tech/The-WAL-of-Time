const std = @import("std");
const builtin = @import("builtin");

const net = std.net;
const debug = std.debug;
const mem = std.mem;

const core = @import("./core.zig");
const linux = @import("./linux.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    switch (builtin.os.tag) {
        .linux => {
            var aio = try linux.AsyncIO.init();
            defer aio.deinit();

            const InMem = core.InMem(linux.FD, linux.fd_eql, linux.Req);
            var in_mem = try InMem.init(allocator);
            defer in_mem.deinit(allocator);

            const initiaReqs = try in_mem.initial_aio_req(aio.socket_fd);
            debug.assert(try aio.flush(initiaReqs) == initiaReqs.len);

            debug.print("The WAL weaves as the WAL wills\n", .{});

            while (true) {
                const aio_res = try aio.wait_for_res();
                const reqs = try in_mem.res_with_ctx(aio_res);
                debug.assert(try aio.flush(reqs) == reqs.len);
            }
        },
        else => @panic("No async io for this OS"),
    }
}

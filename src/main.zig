const std = @import("std");

const net = std.net;
const debug = std.debug;
const mem = std.mem;

const event_loop = @import("./event_loop.zig");
const dst = @import("./dst.zig");
const linux = @import("./linux.zig");

pub fn main() !void {
    var args = std.process.args();
    _ = args.skip(); // first arg

    if (args.next()) |arg| {
        if (mem.eql(u8, arg, "test")) {
            var aio = try dst.AsyncIO.init();
            defer aio.deinit();
            try event_loop.run(dst.fd, dst.fd_eql, &aio);
        } else {
            @panic("unknown arg");
        }
    } else {
        var aio = try linux.AsyncIO.init();
        defer aio.deinit();
        try event_loop.run(linux.fd, linux.fd_eql, &aio);
    }
}

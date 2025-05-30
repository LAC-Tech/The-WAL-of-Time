const std = @import("std");
const net = std.net;
const posix = std.posix;
const linux = std.os.linux;
const debug = std.debug;

pub fn main() !void {
    var ring = try linux.IoUring.init(32, 0);
    defer ring.deinit();

    const socket_fd = try posix.socket(
        posix.AF.INET,
        posix.SOCK.STREAM,
        posix.IPPROTO.TCP,
    );
    defer posix.close(socket_fd);

    const port = 12345;
    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    var addr_len: posix.socklen_t = addr.getOsSockLen();

    try posix.setsockopt(
        socket_fd,
        posix.SOL.SOCKET,
        posix.SO.REUSEADDR,
        // TODO wtf is this again? looks like a magic number
        &std.mem.toBytes(@as(c_int, 1)),
    );
    try posix.bind(socket_fd, &addr.any, addr_len);
    const backlog = 128;
    try posix.listen(socket_fd, backlog);

    _ = try ring.accept(
        @intFromEnum(core.UsrData.connect),
        socket_fd,
        &addr.any,
        &addr_len,
        0,
    );

    debug.assert(try ring.submit() == 1);

    debug.print("The WAL weaves as the WAL wills\n", .{});

    while (true) {
        const cqe = try ring.copy_cqe();

        const err = cqe.err();
        if (err != .SUCCESS) {
            debug.print("CQE Err: {}\n", .{err});
        }

        const usr_data: core.UsrData = @enumFromInt(cqe.user_data);

        switch (usr_data) {
            .connect => {
                debug.print("accept received \n", .{});
                //const client_fd = cqe.res;
                //posix.close(client_fd);

                _ = try ring.accept(
                    @intFromEnum(core.UsrData.connect),
                    socket_fd,
                    &addr.any,
                    &addr_len,
                    0,
                );

                _ = try ring.submit();
            },
        }
    }
}

// TODO:
// - Pre-populate queue with N accept requests. As each is used, add another
// - 64 bit UserData that tells the type of the request
// - SlotMap so we can have client ids pointing to socket fds
// - Zig client, which is a repl
// - inner loop that batch processes all ready CQE events, like TB blog

const core = struct {
    const UsrData = enum(u64) { connect };
};

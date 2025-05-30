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

    try posix.setsockopt(
        socket_fd,
        posix.SOL.SOCKET,
        posix.SO.REUSEADDR,
        // Man page: "For Boolean options, 0 indicates that the option is
        // disabled and 1 indicates that the option is enabled."
        &std.mem.toBytes(@as(c_int, 1)),
    );

    const port = 12345;
    var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    var addr_len: posix.socklen_t = addr.getOsSockLen();
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
                const client_fd = cqe.res;
                //posix.close(client_fd);

                _ = try ring.accept(
                    @intFromEnum(core.UsrData.connect),
                    socket_fd,
                    &addr.any,
                    &addr_len,
                    0,
                );

                // TODO: wait until the recv has come through to do this
                _ = try ring.send(
                    @intFromEnum(core.UsrData.todo),
                    client_fd,
                    "connection acknowledged\n",
                    0,
                );

                // TODO: "recv" here, so that this client can send us data

                _ = try ring.submit();
            },
            .todo => {
                debug.print("todo\n", .{});
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
    const UsrData = enum(u64) { connect, todo };
};

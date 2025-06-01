const std = @import("std");
const net = std.net;
const posix = std.posix;

pub fn fd_eql(a: posix.fd_t, b: posix.fd_t) bool {
    return a == b;
}

pub const fd_t = posix.fd_t;

pub const Server = struct {
    socket_fd: posix.socket_t,
    addr: net.Address,
    addr_len: posix.socklen_t,

    pub fn init() !@This() {
        const socket_fd = try posix.socket(
            posix.AF.INET,
            posix.SOCK.STREAM,
            posix.IPPROTO.TCP,
        );

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
        const addr_len = addr.getOsSockLen();

        try posix.bind(socket_fd, &addr.any, addr_len);

        const backlog = 128;
        try posix.listen(socket_fd, backlog);

        return .{ .socket_fd = socket_fd, .addr = addr, .addr_len = addr_len };
    }

    pub fn deinit(self: *@This()) void {
        posix.close(self.socket_fd);
    }
};

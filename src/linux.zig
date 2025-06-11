const std = @import("std");
//const posix = @import("./posix.zig");
const linux = std.os.linux;
const net = std.net;
const posix = std.posix;

const aio = @import("./async_io.zig");

pub const FD = posix.fd_t;

pub fn fd_eql(a: FD, b: FD) bool {
    return a == b;
}

const aio_msg = aio.msg(FD);
const aio_req = aio_msg.req;
const AioRes = aio_msg.Res;

// Almost pointlessly thin wrapper: the point is to be replaceable with a
// deterministic version
pub const AsyncIO = struct {
    ring: linux.IoUring,
    socket_fd: posix.socket_t,

    pub fn init() !@This() {
        // "The number of SQ or CQ entries determines the amount of shared
        // memory locked by the process. Setting this too high risks overflowing
        // non-root process limits." - Joran
        const entries = 128;
        const ring = try linux.IoUring.init(entries, 0);

        const fd = try posix.socket(
            posix.AF.INET,
            posix.SOCK.STREAM,
            posix.IPPROTO.TCP,
        );

        // Man page: "For Boolean options, 0 indicates that the option is
        // disabled and 1 indicates that the option is enabled."
        const opt = &std.mem.toBytes(@as(c_int, 1));
        try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, opt);

        const port = 12345;
        var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
        const addr_len = addr.getOsSockLen();

        try posix.bind(fd, &addr.any, addr_len);

        const backlog = 128;
        try posix.listen(fd, backlog);

        return .{
            .ring = ring,
            .socket_fd = fd,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.ring.deinit();
        posix.close(self.socket_fd);
    }

    pub fn accept(self: *@This(), req: aio_req.Accept) !*linux.io_uring_sqe {
        return self.ring.accept(req, self.socket_fd, null, null, 0);
    }

    pub fn accept_multishot(
        self: *@This(),
        req: aio_req.Accept,
    ) !*linux.io_uring_sqe {
        return self.ring.accept_multishot(req, self.socket_fd, null, null, 0);
    }

    pub fn recv(self: *@This(), req: aio_req.Recv) !*linux.io_uring_sqe {
        return self.ring.recv(
            req.usr_data,
            req.client_fd,
            .{ .buffer = req.buf },
            0,
        );
    }

    pub fn send(self: *@This(), req: aio_req.Send) !*linux.io_uring_sqe {
        return self.ring.send(req.usr_data, req.client_fd, req.buf, 0);
    }

    /// Number of entries submitted
    pub fn flush(self: *@This()) !u32 {
        return self.ring.submit();
    }

    pub fn wait_for_res(self: *@This()) !AioRes {
        const cqe = try self.ring.copy_cqe();

        const err = cqe.err();
        if (err != .SUCCESS) {
            @panic(@tagName(err));
        }

        return .{ .rc = cqe.res, .usr_data = cqe.user_data };
    }
};

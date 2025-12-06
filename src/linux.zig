const std = @import("std");
const linux = std.os.linux;
const mem = std.mem;
const net = std.net;
const posix = std.posix;

pub const FD = posix.fd_t;
const core = @import("./core.zig");
const Sock = core.Socket(FD);
const Res = core.OSResponse(FD);

// Almost pointlessly thin wrapper: the point is to be replaceable with a
// deterministic version
pub const AsyncIO = struct {
    ring: linux.IoUring,
    server_fd: core.Socket(FD).Server,

    pub fn init() !@This() {
        // "The number of SQ or CQ entries determines the amount of shared
        // memory locked by the process. Setting this too high risks overflowing
        // non-root process limits." - Joran
        const entries = 128;
        const ring = try linux.IoUring.init(entries, 0);

        const fd: FD = try posix.socket(
            posix.AF.INET,
            posix.SOCK.STREAM,
            posix.IPPROTO.TCP,
        );

        // Man page: "For Boolean options, 0 indicates that the option is
        // disabled and 1 indicates that the option is enabled."
        const opt = &mem.toBytes(@as(c_int, 1));
        try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, opt);

        const port = 12345;
        var addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
        const addr_len = addr.getOsSockLen();

        try posix.bind(fd, &addr.any, addr_len);

        const backlog = 128;
        try posix.listen(fd, backlog);



            // Unlimited accepts!
            {
                const req = Req.multishot.accept(
                    @bitCast(UsrData{ .op = .accept_client_conn }),
                    server_fd,
                );
                try self.os_req_buf.append(req);
            }
            // Unlimited receives!
            {
                try self.os_req_buf.append(
                    OSRequest.oneshot.provide_buffers(self.recv_buf),
                );
            }

        return .{ .ring = ring, .server_fd = @enumFromInt(fd) };
    }

    pub fn deinit(self: *@This()) void {
        self.ring.deinit();
        posix.close(@intFromEnum(self.server_fd));
    }

    /// Number of entries submitted
    pub fn send(self: *@This(), reqs: []const Req.T) !u32 {
        for (reqs) |sqe| {
            const vacant_sqe = try self.ring.get_sqe();
            vacant_sqe.* = sqe;
        }

        return self.ring.submit();
    }

    pub fn await_res(self: *@This()) !Res {
        const cqe = try self.ring.copy_cqe();

        const err = cqe.err();
        if (err != .SUCCESS) {
            @panic(@tagName(err));
        }

        return .{ .rc = cqe.res, .usr_data = cqe.user_data };
    }
};

pub const Req = struct {
    pub const T = linux.io_uring_sqe;

    pub const oneshot = struct {
        pub fn send(usr_data: u64, fd: Sock.Client, buf: []const u8) T {
            var sqe = mem.zeroes(T);
            sqe.prep_send(@intFromEnum(fd), buf, 0);
            sqe.user_data = usr_data;
            return sqe;
        }

        pub fn provide_buffers(recv_buf: []u8) T {
            var sqe = mem.zeroes(T);
            sqe.prep_provide_buffers(recv_buf.ptr, recv_buf.len, 1, 0, 0);
            return sqe;
        }
    };

    pub const multishot = struct {
        pub fn accept(usr_data: u64, fd: Sock.Server) T {
            var sqe = mem.zeroes(T);
            sqe.prep_multishot_accept(@intFromEnum(fd), null, null, 0);
            sqe.user_data = usr_data;
            return sqe;
        }

        pub fn recv(usr_data: u64, fd: Sock.Client, buf: []u8) T {
            var sqe = mem.zeroes(T);
            sqe.prep_recv_multishot(@intFromEnum(fd), buf, 0);
            sqe.ioprio |= linux.IORING_RECV_MULTISHOT;
            sqe.flags |= linux.IOSQE_BUFFER_SELECT;
            sqe.buf_index = 0; // group id
            sqe.user_data = usr_data;
            return sqe;
        }
    };
};

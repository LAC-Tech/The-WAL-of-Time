const std = @import("std");
const linux = std.os.linux;

// Almost pointlessly thin wrapper: the point is to be replaceable with a
// deterministic version
pub const AsyncIO = struct {
    ring: linux.IoUring,

    pub fn init() !@This() {
        // "The number of SQ or CQ entries determines the amount of shared
        // memory locked by the process. Setting this too high risks overflowing
        // non-root process limits." - Joran
        const entries = 128;
        return .{ .ring = try linux.IoUring.init(entries, 0) };
    }

    pub fn deinit(self: *@This()) void {
        self.ring.deinit();
    }

    pub fn accept(self: *@This(), usr_data: u64, server: anytype) !void {
        _ = try self.ring.accept(
            @bitCast(usr_data),
            server.socket_fd,
            &server.addr.any,
            &server.addr_len,
            0,
        );
    }

    pub fn recv(
        self: *@This(),
        usr_data: u64,
        client_fd: std.posix.fd_t,
        buf: []u8,
    ) !*linux.io_uring_sqe {
        return self.ring.recv(usr_data, client_fd, .{ .buffer = buf }, 0);
    }

    pub fn send(
        self: *@This(),
        usr_data: u64,
        client_fd: std.posix.fd_t,
        buf: []const u8,
    ) !*linux.io_uring_sqe {
        return self.ring.send(usr_data, client_fd, buf, 0);
    }

    /// Number of entries submitted
    pub fn flush(self: *@This()) !u32 {
        return self.ring.submit();
    }

    pub fn wait_for_res(self: *@This()) !linux.io_uring_cqe {
        const cqe = try self.ring.copy_cqe();

        const err = cqe.err();
        if (err != .SUCCESS) {
            @panic(@tagName(err));
        }

        return cqe;
    }
};

const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const linux = std.os.linux;
const posix = std.posix;

const config = @import("config.zig");
const os = @import("os.zig");

pub const AsyncIO = struct {
    _ring: linux.IoUring,
    _buf_ring: *linux.io_uring_buf_ring,
    _buffers: [][config.buf_size]u8,

    pub fn init(allocator: mem.Allocator) !AsyncIO {
        const ring = try linux.IoUring.init(config.ring_entries, 0);
        const buffers = try allocator.alloc(
            [config.buf_size]u8,
            config.buf_count,
        );
        const buf_ring = try initIoUringBufRing(ring.fd, buffers);

        return .{
            ._ring = ring,
            ._buf_ring = buf_ring,
            ._buffers = buffers,
        };
    }

    pub fn deinit(self: *AsyncIO, allocator: mem.Allocator) void {
        self._ring.deinit();
        allocator.free(self._buffers);
    }

    pub fn submit(self: *AsyncIO) !u32 {
        return self._ring.submit();
    }

    pub fn waitForReq(self: *AsyncIO) !linux.io_uring_cqe {
        return self._ring.copy_cqe();
    }

    pub fn accept(self: *AsyncIO, server_fd: i32, msg: os.Accept) !void {
        var sqe = try self._ring.get_sqe();
        sqe.prep_multishot_accept(server_fd, null, null, 0);
        sqe.user_data = msg.toU64();
    }

    pub fn recv(self: *AsyncIO, msg: os.Recv) !void {
        var sqe = try self._ring.get_sqe();
        const empty_buf = &[_]u8{};
        sqe.prep_recv_multishot(msg.client_fd, empty_buf, 0);
        sqe.buf_index = config.bg_id;
        sqe.flags |= linux.IOSQE_BUFFER_SELECT;
        sqe.user_data = msg.toU64();
    }

    pub fn send(
        self: *AsyncIO,
        client_fd: i32,
        len: usize,
        msg: os.Send,
    ) !void {
        var sqe = try self._ring.get_sqe();
        const buf = &self._buffers[msg.buf_id];
        sqe.prep_send(client_fd, buf[0..len], 0);
        sqe.user_data = msg.toU64();
    }

    pub fn release_buf(self: *AsyncIO, buf_id: u16) void {
        debug.assert(config.buf_count > buf_id);
        linux.IoUring.buf_ring_add(
            self._buf_ring,
            &self._buffers[buf_id],
            buf_id,
            linux.IoUring.buf_ring_mask(config.buf_count),
            0,
        );
        linux.IoUring.buf_ring_advance(self._buf_ring, 1);
    }
};

pub fn resFromCqe(cqe: linux.io_uring_cqe) os.Response {
    const user_data = os.fromUserData(cqe.user_data);
    const more = cqe.flags & linux.IORING_CQE_F_MORE != 0;
    const restart_needed = !more;

    return switch (user_data.syscall) {
        .accept => .{
            .accept_data = .{
                .client_fd = cqe.res,
                .restart_needed = restart_needed,
            },
        },
        .recv => {
            const buf_id: u16 =
                @intCast(cqe.flags >> linux.IORING_CQE_BUFFER_SHIFT);

            if (cqe.res > 0) {
                return .{
                    .recv = .{
                        .client_fd = user_data.msg.recv.client_fd,
                        .buf_id = buf_id,
                        .restart_needed = restart_needed,
                        .result = .{ .data = @intCast(cqe.res) },
                    },
                };
            }
            if (cqe.res == 0) {
                return .{
                    .recv = .{
                        .client_fd = user_data.msg.recv.client_fd,
                        .buf_id = buf_id,
                        .restart_needed = restart_needed,
                        .result = .{ .disconnect = {} },
                    },
                };
            }
            return .{
                .recv = .{
                    .client_fd = user_data.msg.recv.client_fd,
                    .buf_id = buf_id,
                    .restart_needed = restart_needed,
                    .result = .{ .error_code = -cqe.res },
                },
            };
        },
        .send => .{
            .send_complete = .{
                .buf_id = user_data.msg.send.buf_id,
            },
        },
    };
}

fn initIoUringBufRing(
    io_uring_fd: i32,
    buffers: [][config.buf_size]u8,
) !*linux.io_uring_buf_ring {
    const br = try linux.IoUring.setup_buf_ring(
        io_uring_fd,
        config.buf_count,
        config.bg_id,
        mem.zeroes(linux.io_uring_buf_reg.Flags),
    );

    linux.IoUring.buf_ring_init(br);

    for (0..config.buf_count) |i| {
        const mask = linux.IoUring.buf_ring_mask(config.buf_count);
        const buf_id: u16 = @intCast(i);
        const buf_offset: u16 = @intCast(i);

        linux.IoUring.buf_ring_add(br, &buffers[i], buf_id, mask, buf_offset);
    }

    linux.IoUring.buf_ring_advance(br, config.buf_count);
    return br;
}

pub fn initServerFd() !i32 {
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    const opt: c_int = 1;

    try posix.setsockopt(
        fd,
        posix.SOL.SOCKET,
        posix.SO.REUSEADDR,
        mem.asBytes(&opt),
    );

    const addr = linux.sockaddr.in{
        .family = linux.AF.INET,
        .port = mem.nativeToBig(u16, config.port),
        .addr = 0,
    };

    try posix.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
    try posix.listen(fd, config.backlog);
    return fd;
}

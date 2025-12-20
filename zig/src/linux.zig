const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const posix = std.posix;

const linux = std.os.linux;
const IoUring = linux.IoUring;
const IORING_CQE_F_MORE = linux.IORING_CQE_F_MORE;
const IORING_CQE_BUFFER_SHIFT = linux.IORING_CQE_BUFFER_SHIFT;
const IOSQE_BUFFER_SELECT = linux.IOSQE_BUFFER_SELECT;
const io_uring_buf_ring = linux.io_uring_buf_ring;
const fd_t = linux.fd_t;
const io_uring_buf_reg = linux.io_uring_buf_reg;

const config = @import("config.zig");
const io = @import("io.zig");

const bg_id = 0;

const Buffers = [][config.buf_size]u8;

/// We have two purposes here:
/// - hiding linux specific OS details
/// - having as little logic as possible, as it's hard to test
pub const AsyncIO = struct {
    _io_uring: IoUring,
    buf_ring: BufRing,

    pub fn init(buffers: Buffers) !AsyncIO {
        const ring = try IoUring.init(config.ring_entries, 0);
        const buf_ring = try BufRing.init(ring.fd, buffers);

        return .{
            ._io_uring = ring,
            .buf_ring = buf_ring,
        };
    }

    pub fn deinit(self: *AsyncIO) void {
        self.buf_ring.deinit();
        self._io_uring.deinit();
    }

    pub fn submit(self: *AsyncIO) !u32 {
        return self._io_uring.submit();
    }

    pub fn waitForRes(self: *AsyncIO) !io.Res {
        const cqe = try self._io_uring.copy_cqe();

        return .{
            .restart_needed = cqe.flags & IORING_CQE_F_MORE == 0,
            .user_data = io.fromU64(cqe.user_data),
            .buf_id = @intCast(cqe.flags >> IORING_CQE_BUFFER_SHIFT),
            .syscall_result = cqe.res,
        };
    }

    pub fn accept(self: *AsyncIO, server_fd: i32, user_data: io.Accept) !void {
        var sqe = try self._io_uring.get_sqe();
        sqe.prep_multishot_accept(server_fd, null, null, 0);
        sqe.user_data = user_data.toU64();
    }

    pub fn recv(self: *AsyncIO, user_data: io.Recv) !void {
        var sqe = try self._io_uring.get_sqe();
        const empty_buf = &[_]u8{};
        sqe.prep_recv_multishot(user_data.client_fd, empty_buf, 0);
        sqe.buf_index = bg_id;
        sqe.flags |= IOSQE_BUFFER_SELECT;
        sqe.user_data = user_data.toU64();
    }

    pub fn send(
        self: *AsyncIO,
        client_fd: i32,
        buf: []const u8,
        user_data: io.Send,
    ) !void {
        var sqe = try self._io_uring.get_sqe();
        sqe.prep_send(client_fd, buf, 0);
        sqe.user_data = user_data.toU64();
    }

    pub fn close(self: *AsyncIO, fd: i32, user_data: io.Close) !void {
        var sqe = try self._io_uring.get_sqe();
        sqe.prep_close(fd);
        sqe.user_data = user_data.toU64();
    }
};

const BufRing = struct {
    const Ptr = *align(std.heap.page_size_min) io_uring_buf_ring;
    _io_uring_fd: linux.fd_t,
    _ptr: Ptr,

    fn add_buf(
        buf_ring_ptr: Ptr,
        buf_id: u16,
        buffers: Buffers,
        buffer_offset: u16,
    ) void {
        const mask = IoUring.buf_ring_mask(config.buf_count);

        IoUring.buf_ring_add(
            buf_ring_ptr,
            &buffers[buf_id],
            buf_id,
            mask,
            buffer_offset,
        );
    }

    fn init(
        io_uring_fd: fd_t,
        buffers: [][config.buf_size]u8,
    ) !BufRing {
        const flags = mem.zeroes(io_uring_buf_reg.Flags);
        const ptr = try IoUring.setup_buf_ring(
            io_uring_fd,
            config.buf_count,
            bg_id,
            flags,
        );

        IoUring.buf_ring_init(ptr);

        for (0..config.buf_count) |i| {
            const buf_id: u16 = @intCast(i);
            const buf_offset: u16 = @intCast(i);
            add_buf(ptr, buf_id, buffers, buf_offset);
        }

        IoUring.buf_ring_advance(ptr, config.buf_count);
        return .{ ._io_uring_fd = io_uring_fd, ._ptr = ptr };
    }

    fn deinit(self: BufRing) void {
        IoUring.free_buf_ring(
            self._io_uring_fd,
            self._ptr,
            config.buf_count,
            bg_id,
        );
    }

    pub fn release(self: BufRing, buf_id: u16, buffers: Buffers) void {
        debug.assert(config.buf_count > buf_id);

        add_buf(self._ptr, buf_id, buffers, 0);
        IoUring.buf_ring_advance(self._ptr, 1);
    }
};

pub const Server = struct {
    fd: i32,

    pub fn init() !Server {
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        const opt: c_int = 1;

        try posix.setsockopt(
            fd,
            posix.SOL.SOCKET,
            posix.SO.REUSEADDR,
            mem.asBytes(&opt),
        );

        const addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = mem.nativeToBig(u16, config.port),
            .addr = 0,
        };

        try posix.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
        try posix.listen(fd, config.backlog);
        return .{ .fd = fd };
    }

    pub fn deinit(self: Server) void {
        posix.close(self.fd);
    }
};

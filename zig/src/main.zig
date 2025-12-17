const std = @import("std");
const debug = std.debug;
const heap = std.heap;
const os = std.os;
const math = std.math;
const mem = std.mem;
const meta = std.meta;
const posix = std.posix;
const Random = std.Random;
const testing = std.testing;

const config = @import("./config.zig");

/// This modules bridges the gap between the state machine and particular OS
/// They are OS independent, but also represent quite low level operations
const OsMsg = packed struct {
    syscall: Syscall,
    payload: Payload,

    pub const UserData = u64;
    const Syscall = enum(u8) { accept = 1, recv = 2, send = 3 };

    const Accept = packed struct {
        _padding: u56 = 0,
    };

    const Recv = packed struct {
        client_fd: i32,
        _padding: u24 = 0,
    };

    const Send = packed struct {
        buf_id: u32,
        _padding: u24 = 0,
    };

    const Payload = packed union {
        accept: Accept,
        recv: Recv,
        send: Send,
    };

    comptime {
        debug.assert(@sizeOf(OsMsg) == 8);
        debug.assert(@bitSizeOf(OsMsg) == 64);
    }

    fn toUserData(self: OsMsg) UserData {
        return @bitCast(self);
    }

    fn fromUserData(ud: UserData) OsMsg {
        return @bitCast(ud);
    }

    fn accept() OsMsg {
        return .{
            .syscall = .accept,
            .payload = .{ .accept = .{} },
        };
    }

    fn recv(client_fd: i32) OsMsg {
        return .{
            .syscall = .recv,
            .payload = .{ .recv = .{ .client_fd = client_fd } },
        };
    }

    fn send(buf_id: u32) OsMsg {
        return .{
            .syscall = .send,
            .payload = .{ .send = .{ .buf_id = buf_id } },
        };
    }
};

test "serde Userdata" {
    var rng = Random.DefaultPrng.init(testing.random_seed);

    debug.print("{}", .{testing.random_seed});

    for (0..1_000_000) |_| {
        const ud = switch (rng.random().enumValue(OsMsg.Syscall)) {
            .accept => OsMsg.accept(),
            .recv => OsMsg.recv(rng.random().int(i32)),
            .send => OsMsg.send(rng.random().int(u32)),
        };
        const ud_recvd = OsMsg.fromUserData(ud.toUserData());

        try testing.expectEqual(ud, ud_recvd);
    }
}

const linux = struct {
    const BufRing = struct {
        const IoUring = os.linux.IoUring;

        _buf_ring: *os.linux.io_uring_buf_ring,
        _buffers: []u8,

        fn nth_buf(buffers: []u8, n: usize) []u8 {
            return buffers[n * config.buf_size .. (n + 1) * config.buf_size];
        }

        fn init(io_uring_fd: i32, allocator: mem.Allocator) !BufRing {
            const buffers = try allocator.alloc(
                u8,
                config.buf_count * config.buf_size,
            );
            const br = try IoUring.setup_buf_ring(
                io_uring_fd,
                config.buf_count,
                config.bg_id,
                mem.zeroes(os.linux.io_uring_buf_reg.Flags),
            );

            IoUring.buf_ring_init(br);

            for (0..config.buf_count) |i| {
                IoUring.buf_ring_add(
                    br,
                    nth_buf(buffers, i),
                    @intCast(i),
                    IoUring.buf_ring_mask(config.buf_count),
                    @intCast(i),
                );
            }

            IoUring.buf_ring_advance(br, config.buf_count);

            return .{ ._buf_ring = br, ._buffers = buffers };
        }

        fn deinit(self: BufRing, allocator: mem.Allocator) void {
            allocator.free(self._buffers);
        }

        fn release(self: BufRing, buf_id: u32) void {
            debug.assert(config.buf_count > buf_id);
            IoUring.buf_ring_add(
                self._buf_ring,
                nth_buf(self._buffers, buf_id),
                @intCast(buf_id),
                IoUring.buf_ring_mask(config.buf_count),
                0,
            );
            IoUring.buf_ring_advance(self._buf_ring, 1);
        }

        fn get(self: BufRing, buf_id: u32) []const u8 {
            debug.assert(config.buf_count > buf_id);
            return nth_buf(self._buffers, buf_id);
        }
    };

    fn setup_listening_socket() !i32 {
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        const opt: c_int = 1;

        try posix.setsockopt(
            fd,
            posix.SOL.SOCKET,
            posix.SO.REUSEADDR,
            mem.asBytes(&opt),
        );

        const addr = os.linux.sockaddr.in{
            .family = os.linux.AF.INET,
            .port = mem.nativeToBig(u16, config.port),
            .addr = 0,
        };

        try posix.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
        try posix.listen(fd, config.backlog);
        return fd;
    }

    const AsyncIO = struct {
        ring: os.linux.IoUring,
        buf_ring: BufRing,

        fn init(allocator: mem.Allocator) !AsyncIO {
            const ring = try os.linux.IoUring.init(config.ring_entries, 0);

            return .{
                .ring = ring,
                .buf_ring = try BufRing.init(ring.fd, allocator),
            };
        }

        fn deinit(self: *AsyncIO, allocator: mem.Allocator) void {
            self.ring.deinit();
            self.buf_ring.deinit(allocator);
        }

        fn submit(self: *AsyncIO) !u32 {
            return self.ring.submit();
        }

        fn accept(self: *AsyncIO, listen_fd: i32) !void {
            var sqe = try self.ring.get_sqe();
            sqe.prep_multishot_accept(listen_fd, null, null, 0);
            sqe.user_data = OsMsg.accept().toUserData();
        }

        fn recv(self: *AsyncIO, client_fd: i32) !void {
            var sqe = try self.ring.get_sqe();
            const empty_buf = &[_]u8{};
            sqe.prep_recv_multishot(@intCast(client_fd), empty_buf, 0);
            sqe.buf_index = config.bg_id;
            sqe.flags |= os.linux.IOSQE_BUFFER_SELECT;
            sqe.user_data = OsMsg.recv(client_fd).toUserData();
        }

        fn send(
            self: *AsyncIO,
            client_fd: i32,
            buf_id: u32,
            len: usize,
        ) !void {
            var sqe = try self.ring.get_sqe();

            const buf = self.buf_ring.get(buf_id);
            sqe.prep_send(client_fd, buf[0..len], 0);
            sqe.user_data = OsMsg.send(buf_id).toUserData();
        }
    };
};

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var aio = try linux.AsyncIO.init(allocator);
    defer aio.deinit(allocator);

    const listen_fd = try linux.setup_listening_socket();
    debug.print("Listening on port {d}\n", .{config.port});

    try aio.accept(listen_fd);

    while (true) {
        _ = try aio.submit();
        const cqe = try aio.ring.copy_cqe();
        const user_data = OsMsg.fromUserData(cqe.user_data);

        switch (user_data.syscall) {
            .accept => {
                const client_fd = cqe.res;
                try aio.recv(client_fd);

                // Multishot accept continues while MORE flag is set
                if ((cqe.flags & os.linux.IORING_CQE_F_MORE) == 0) {
                    // Accept multishot ended (no MORE flag) - restart it
                    debug.print("accept multishot ended, restarting\n", .{});
                    try aio.accept(listen_fd);
                }
            },
            .recv => {
                const client_fd = user_data.payload.recv.client_fd;

                if (0 > cqe.res) {
                    // Error occurred - always release the buffer first
                    const buf_id = cqe.flags >> os.linux.IORING_CQE_BUFFER_SHIFT;
                    aio.buf_ring.release(buf_id);

                    debug.print(
                        "recv error on fd {d}: {d}\n",
                        .{ client_fd, -cqe.res },
                    );

                    // If multishot is done (no MORE flag), close socket
                    if ((cqe.flags & os.linux.IORING_CQE_F_MORE) == 0) {
                        posix.close(client_fd);
                    }
                } else if (cqe.res == 0) {
                    // Orderly shutdown by client
                    const buf_id = cqe.flags >> os.linux.IORING_CQE_BUFFER_SHIFT;
                    aio.buf_ring.release(buf_id);

                    // If multishot is done (no MORE flag), close socket
                    if ((cqe.flags & os.linux.IORING_CQE_F_MORE) == 0) {
                        posix.close(client_fd);
                    }
                } else {
                    // Received actual data! Echo it back
                    const buf_id = cqe.flags >> os.linux.IORING_CQE_BUFFER_SHIFT;
                    const len: usize = @intCast(cqe.res);

                    try aio.send(client_fd, buf_id, len);
                }
            },
            .send => {
                // This is a send completion - return buffer
                const buf_id = user_data.payload.send.buf_id;
                aio.buf_ring.release(buf_id);
            },
        }
    }
}

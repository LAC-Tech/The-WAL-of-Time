const std = @import("std");

const net = std.net;
const posix = std.posix;
const linux = std.os.linux;
const debug = std.debug;
const mem = std.mem;

pub fn main() !void {
    var async_io = try AsyncIO.init();
    defer async_io.deinit();

    var server = try Server.init();
    defer server.deinit();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const recv_buf = try allocator.alloc(u8, core.write_buf_size);

    var client_fd: posix.fd_t = -1;

    for (0..core.max_clients) |_| {
        _ = try async_io.accept(.client_connected, &server);
    }
    debug.assert(try async_io.flush() == core.max_clients);

    debug.print("The WAL weaves as the WAL wills\n", .{});

    while (true) {
        const cqe = try async_io.wait_for_res();
        const usr_data: core.UsrData = @enumFromInt(cqe.user_data);

        switch (usr_data) {
            .client_connected => {
                client_fd = cqe.res;
                // Replace itself on the queue, so other clients can connect
                _ = try async_io.accept(.client_connected, &server);

                // Let client know they can connect.
                _ = try async_io.send(.client_ready, client_fd, "connection acknowledged\n");

                _ = try async_io.flush();
            },
            .client_ready => {
                @memset(recv_buf, 0);
                // so we can receive a message
                _ = try async_io.recv(.client_msg, client_fd, recv_buf);
                _ = try async_io.flush();
            },
            .client_msg => {
                debug.print("received: {s}", .{recv_buf});
                // So we can receive more messages
                _ = try async_io.recv(.client_msg, client_fd, recv_buf);
                _ = try async_io.flush();
            },
        }
    }
}

const AsyncIO = struct {
    ring: linux.IoUring,

    fn init() !@This() {
        // "The number of SQ or CQ entries determines the amount of shared
        // memory locked by the process. Setting this too high risks overflowing
        // non-root process limits." - Joran
        const entries = 128;
        return .{ .ring = try linux.IoUring.init(entries, 0) };
    }

    fn deinit(self: *@This()) void {
        self.ring.deinit();
    }

    fn accept(
        self: *@This(),
        usr_data: core.UsrData,
        server: *Server,
    ) !void {
        _ = try self.ring.accept(
            @intFromEnum(usr_data),
            server.socket_fd,
            &server.addr.any,
            &server.addr_len,
            0,
        );
    }

    fn recv(self: *@This(), usr_data: core.UsrData, client_fd: posix.fd_t, buf: []u8) !void {
        _ = try self.ring.recv(
            @intFromEnum(usr_data),
            client_fd,
            .{ .buffer = buf },
            0,
        );
    }

    fn send(
        self: *@This(),
        usr_data: core.UsrData,
        client_fd: posix.fd_t,
        buf: []const u8,
    ) !void {
        _ = try self.ring.send(
            @intFromEnum(usr_data),
            client_fd,
            buf,
            0,
        );
    }

    /// Number of entries submitted
    fn flush(self: *@This()) !u32 {
        return self.ring.submit();
    }

    fn wait_for_res(self: *@This()) !linux.io_uring_cqe {
        const cqe = try self.ring.copy_cqe();

        const err = cqe.err();
        if (err != .SUCCESS) {
            @panic(@tagName(err));
        }

        return cqe;
    }
};

const Server = struct {
    socket_fd: posix.socket_t,
    addr: net.Address,
    addr_len: posix.socklen_t,

    fn init() !@This() {
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

    fn deinit(self: *@This()) void {
        posix.close(self.socket_fd);
    }
};

// TODO:
// - Pre-populate queue with N accept requests. As each is used, add another
// - 64 bit UserData that tells the type of the request
// - SlotMap so we can have client ids pointing to socket fds
// - Zig client, which is a repl
// - inner loop that batch processes all ready CQE events, like TB blog
const core = struct {
    const UsrData = enum(u64) { client_connected, client_ready, client_msg };
    comptime {
        debug.assert(8 == @sizeOf(UsrData));
    }

    const max_clients = 1; // TODO: more
    const write_buf_size = 64;

    const max_slots: usize = 64;

    pub const CreateSlotErr = error{
        ValAlreadyExists,
        MaxVals,
    };

    fn SlotMap(comptime T: type) type {
        return struct {
            vals: [max_slots]T,
            used_slots: [max_slots]u1,

            fn init(allocator: std.mem.Allocator) !@This() {
                return .{
                    .vals = try allocator.create([max_slots]T),
                    .used_slots = [_]u1{0} ** max_slots,
                };
            }

            fn deinit(self: *@This(), allocator: mem.Allocator) void {
                allocator.free(self.vals);
            }

            /// Index if it succeeds, None if it's a duplicate
            fn add(
                self: *@This(),
                val: []const u8,
            ) CreateSlotErr!u8 {
                for (self.names) |existing_name| {
                    if (mem.eql(u8, existing_name, val))
                        return error.ValAlreadyExists;
                }

                // Find first free slot
                for (self.used_slots, 0..) |slot, idx| {
                    if (slot == 0) { // Free slot found
                        self.used_slots[idx] = 1;
                        self.names[idx] = val;
                        return @enumFromInt(idx);
                    }
                }

                return error.MaxTopics; // No free slots
            }

            fn remove(self: *@This(), slot: u8) T {
                self.used_slots[slot] = 0;
                const removed = self.names[slot];
                self.names[slot] = "";
                return removed;
            }
        };
    }

    //// This determines
    //// - number of initial accept requests
    //// - number of receive requests
    //// -
    //const max_clients = 8; // TODO: think about this number more

    //const n_recv_entries: usize = 8;
    //const max_msg_size: usize = 4096; // TODO: find a proper value for this

    //// Events that are dispatched to io_uring need places to read and write to.
    //// I'm just pre-allocating the maximum amount I can use, all at once.
    //fn Buffers(comptime n_buckets: usize, comptime bucket_size: usize) type {
    //    const Borrowed = struct {
    //        slot: usize,
    //        buffer: []u8,
    //    };

    //    return struct {
    //        lens: [n_buckets] usize,
    //        occupied: [n_buckets] u1,
    //        backing_bytes: [n_buckets * bucket_size]u8,

    //        fn init(allocator: std.mem.Allocator) !@This() {
    //            return .{
    //                .lens = try allocator.alloc(usize, n_buckets),
    //                .occupied = try allocator.alloc(u1, n_buckets),
    //            };
    //        }

    //        fn get_buf(self: *@This()) ![]u8 {
    //            for (self.occupied, 0..) |o, i| {
    //                if (o) {
    //                    continue;
    //                }

    //                self.occupied[i] = 1;
    //                return self.backing_bytes[i];
    //            }
    //        }
    //    };
    //}
};

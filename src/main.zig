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

    // TODO: one of these per client? pretty sure they could be overwritten
    const recv_buf = try allocator.alloc(u8, core.write_buf_size);
    @memset(recv_buf, 0); // Zig has no calloc equivalent I can see

    var client_fds = try core.SlotMap(
        posix.fd_t,
        core.max_clients,
        posix_fd_eql,
    ).init(allocator);

    for (0..core.max_clients) |_| {
        _ = try async_io.accept(
            @bitCast(core.UsrData.client_connected),
            &server,
        );
    }
    debug.assert(try async_io.flush() == core.max_clients);

    debug.print("The WAL weaves as the WAL wills\n", .{});

    while (true) {
        const cqe = try async_io.wait_for_res();
        const usr_data: core.UsrData = @bitCast(cqe.user_data);

        switch (usr_data.tag) {
            .client_connected => {
                const client_fd = cqe.res;
                const client_slot = try client_fds.add(client_fd);
                // Replace itself on the queue, so other clients can connect
                _ = try async_io.accept(core.UsrData.client_connected, &server);

                // Let client know they can connect.
                _ = try async_io.send(
                    core.UsrData.client_ready(client_slot),
                    client_fd,
                    "connection acknowledged\n",
                );

                _ = try async_io.flush();
            },
            .client_ready => {
                const client_slot = usr_data.payload.client_slot;
                // so we can receive a message
                const client_fd = client_fds.get(client_slot) orelse {
                    @panic("expect to have a client fd here");
                };
                _ = try async_io.recv(
                    core.UsrData.client_msg(client_slot),
                    client_fd,
                    recv_buf,
                );

                _ = try async_io.flush();
            },
            .client_msg => {
                const client_slot = usr_data.payload.client_slot;
                debug.print("received: {s}", .{recv_buf});
                @memset(recv_buf, 0);

                // So we can receive more messages
                const client_fd = client_fds.get(client_slot) orelse {
                    @panic("expect to have a client fd here");
                };
                _ = try async_io.recv(
                    core.UsrData.client_msg(client_slot),
                    client_fd,
                    recv_buf,
                );

                _ = try async_io.flush();
            },
        }
    }
}

fn posix_fd_eql(a: posix.fd_t, b: posix.fd_t) bool {
    return a == b;
}

// Almost pointlessly thin wrapper: the point is to be replaceable with a
// deterministic version
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

    fn accept(self: *@This(), usr_data: u64, server: *Server) !void {
        _ = try self.ring.accept(
            @bitCast(usr_data),
            server.socket_fd,
            &server.addr.any,
            &server.addr_len,
            0,
        );
    }

    fn recv(
        self: *@This(),
        usr_data: u64,
        client_fd: posix.fd_t,
        buf: []u8,
    ) !void {
        _ = try self.ring.recv(usr_data, client_fd, .{ .buffer = buf }, 0);
    }

    fn send(
        self: *@This(),
        usr_data: u64,
        client_fd: posix.fd_t,
        buf: []const u8,
    ) !void {
        _ = try self.ring.send(usr_data, client_fd, buf, 0);
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
    // Zig tagged unions can't be bitcast.
    // They're Go programmers and they don't know any better
    // So we hack it together like C
    const UsrData = packed struct(u64) {
        tag: enum(u8) { client_connected, client_ready, client_msg },
        payload: packed union { client_slot: u8 },
        _padding: u48 = 0,

        const client_connected: u64 = @bitCast(@This(){
            .tag = .client_connected,
            .payload = undefined,
        });

        fn client_ready(client_slot: u8) u64 {
            const result = @This(){
                .tag = .client_ready,
                .payload = .{ .client_slot = client_slot },
            };

            return @bitCast(result);
        }

        fn client_msg(client_slot: u8) u64 {
            const result = @This(){
                .tag = .client_msg,
                .payload = .{ .client_slot = client_slot },
            };

            return @bitCast(result);
        }
    };

    comptime {
        debug.assert(8 == @sizeOf(UsrData));
    }

    const max_clients = 2; // TODO: more
    const write_buf_size = 64;

    pub const CreateSlotErr = error{
        ValAlreadyExists,
        MaxVals,
    };

    fn SlotMap(
        comptime T: type,
        comptime max_slots: usize,
        /// Context must be a struct type with one member function:
        /// eql(self, T, T) bool
        comptime eql: fn (T, T) bool,
    ) type {
        return struct {
            vals: []T,
            used_slots: [max_slots]u1,

            fn init(allocator: std.mem.Allocator) !@This() {
                return .{
                    .vals = try allocator.alloc(T, max_slots),
                    .used_slots = [_]u1{0} ** max_slots,
                };
            }

            fn deinit(self: *@This(), allocator: mem.Allocator) void {
                allocator.free(self.vals);
            }

            fn add(
                self: *@This(),
                val: T,
            ) CreateSlotErr!u8 {
                for (self.vals) |existing| {
                    if (eql(existing, val))
                        return error.ValAlreadyExists;
                }

                // Find first free slot
                for (self.used_slots, 0..max_slots) |slot, idx| {
                    if (slot == 0) { // Free slot found
                        self.used_slots[idx] = 1;
                        self.vals[idx] = val;
                        return @intCast(idx);
                    }
                }

                return error.MaxVals; // No free slots
            }

            fn get(self: @This(), slot: u8) ?T {
                if (self.used_slots[slot] == 1) {
                    return self.vals[slot];
                } else {
                    return null;
                }
            }

            fn remove(self: *@This(), slot: u8) T {
                self.used_slots[slot] = 0;
                const removed = self.names[slot];
                self.names[slot] = "";
                return removed;
            }
        };
    }
};

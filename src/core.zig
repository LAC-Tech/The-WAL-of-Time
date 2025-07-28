const std = @import("std");
const BoundedArray = std.BoundedArray;
const debug = std.debug;
const mem = std.mem;

const util = @import("./util.zig");

const config = struct {
    const max_io_req: usize = 2;
};

/// Deterministic, in-memory state machine that keeps track of things while the
/// node is running
pub fn StateMachine(
    comptime FD: type,
    comptime OSRequest: type,
    comptime limits: struct { max_clients: usize, write_buf_size: usize },
) type {
    comptime {
        // Make sure it fits in the slot map
        debug.assert(256 > limits.max_clients);
    }

    return struct {
        const ClientSockets = util.SlotMap(
            Socket(FD).Client,
            Socket(FD).client_eql,
            limits.max_clients,
            .{ .duplicates = false },
        );

        client_sockets: ClientSockets,
        recv_buf: []u8,
        os_req_buf: BoundedArray(OSRequest.T, config.max_io_req),

        pub fn init(allocator: mem.Allocator) !@This() {
            return .{
                .client_sockets = try ClientSockets.init(allocator),
                // TODO: one of these per client? they can be overwritten
                .recv_buf = try allocator.alloc(u8, limits.write_buf_size),
                .os_req_buf = try BoundedArray(
                    OSRequest.T,
                    config.max_io_req,
                ).init(0),
            };
        }

        pub fn deinit(self: *@This(), allocator: mem.Allocator) void {
            self.client_sockets.deinit(allocator);
            allocator.free(self.recv_buf);
        }

        /// OS requests that need to be submitted before the main loop runs.
        // Note: It is tempting to put this in init
        // However then we either need to return two things from init, OR this
        // struct needs to become aware of where to send requests.
        pub fn initial_transition(
            self: *@This(),
            server_fd: Socket(FD).Server,
        ) ![]const OSRequest.T {
            // Unlimited accepts!
            {
                const req = OSRequest.multishot.accept(
                    @bitCast(UsrData{ .op = .accept_client_conn }),
                    server_fd,
                );
                try self.os_req_buf.append(req);
            }
            return self.os_req_buf.constSlice();
        }

        /// State Machine Transition Function
        /// After the OS respondes with information about an action that's been
        /// completed, the state machines calculates what to request from the
        /// OS.
        /// Note: the return value is only valid until the next time the
        /// function is called.
        pub fn transition(
            self: *@This(),
            response: OSResponse(FD),
        ) ![]const OSRequest.T {
            self.os_req_buf.clear();
            var res_ud: UsrData = @bitCast(response.usr_data);

            switch (res_ud.op) {
                .accept_client_conn => {
                    debug.print("accept client conn\n", .{});
                    const fd: Socket(FD).Client = @enumFromInt(response.rc);

                    if (self.client_sockets.add(fd)) |client_id| {
                        try self.enqueue_os_send_req(
                            fd,
                            .{ .op = .send_conn_ack, .client_id = client_id },
                            "connection acknowledged\n",
                        );
                    } else |err| switch (err) {
                        error.Duplicate => {
                            try self.enqueue_os_send_req(
                                fd,
                                .{ .op = .send_no_new_conn },
                                "client already connected\n",
                            );
                        },
                        error.Overflow => {
                            try self.enqueue_os_send_req(
                                fd,
                                .{ .op = .send_no_new_conn },
                                "err: maximum connections reached\n",
                            );
                        },
                    }
                },
                .send_conn_ack => {
                    debug.print("send conn ack\n", .{});
                    res_ud.op = .recv;
                    const os_req = OSRequest.multishot.recv(
                        res_ud.to_u64(),
                        self.client_sockets.get(res_ud.client_id).?,
                        self.recv_buf,
                    );
                    try self.os_req_buf.append(os_req);
                },
                .send_no_new_conn => {
                    @panic("TODO: handle this case");
                },
                // TODO: this just puts the req on the ring again...
                .recv => {
                    debug.print("recv\n", .{});
                    const buf_len: usize = @intCast(response.rc);
                    debug.print("Client {d} sent {s}", .{
                        res_ud.client_id,
                        self.recv_buf[0..buf_len],
                    });

                    //const os_req = OSRequest.recv(
                    //    res_ud.to_u64(),
                    //    self.client_sockets.get(res_ud.client_id).?,
                    //    self.recv_buf,
                    //);

                    //try self.os_req_buf.append(os_req);
                },
            }

            return self.os_req_buf.constSlice();
        }

        fn enqueue_os_send_req(
            self: *@This(),
            fd: Socket(FD).Client,
            ud: UsrData,
            msg: []const u8,
        ) !void {
            const os_req = OSRequest.oneshot.send(@bitCast(ud), fd, msg);
            try self.os_req_buf.append(os_req);
        }
    };
}

pub fn Socket(comptime FD: type) type {
    return struct {
        pub const Client = enum(FD) { _ };
        pub const Server = enum(FD) { _ };

        pub fn client_eql(a: Client, b: Client) bool {
            return std.meta.eql(a, b);
        }
    };
}

pub fn OSResponse(comptime FD: type) type {
    return struct { rc: FD, usr_data: u64 };
}

/// Data passed to async io systems
/// Sized at 64 bits to match io_urings user_data, and I think kqueue's udata
/// Can't  be a tagged union; zig can't bitcast those
const UsrData = packed struct(u64) {
    op: enum(u8) {
        accept_client_conn,
        send_conn_ack,
        send_no_new_conn,
        recv,
    },
    /// DB level operation
    verb: enum(u8) { create, append, delete } = undefined,
    client_id: u8 = undefined,
    _padding: u40 = 0,

    fn to_u64(self: UsrData) u64 {
        return @bitCast(self);
    }

    fn from_u64(n: u64) UsrData {
        return @bitCast(n);
    }
};

comptime {
    // IO Uring user_data
    debug.assert(@sizeOf(u64) == @sizeOf(UsrData));
    // Kqueue udata
    debug.assert(@sizeOf(usize) == @sizeOf(UsrData));
}

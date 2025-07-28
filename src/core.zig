const std = @import("std");
const BoundedArray = std.BoundedArray;
const debug = std.debug;
const mem = std.mem;

const util = @import("./util.zig");

const config = struct {
    const max_io_req: usize = 2;
};

const Limits = struct { max_clients: usize, write_buf_size: usize };

/// Deterministic, in-memory state machine that keeps track of things while the
/// node is running
pub fn StateMachine(
    comptime FD: type,
    comptime OSRequest: type,
    comptime limits: Limits,
) type {
    return struct {
        os_req_buf: BoundedArray(OSRequest.T, config.max_io_req),
        state: State(FD, OSRequest, limits),

        pub fn init(allocator: mem.Allocator) !@This() {
            return .{
                .state = try State(FD, OSRequest, limits).init(allocator),
                .os_req_buf = try BoundedArray(
                    OSRequest.T,
                    config.max_io_req,
                ).init(0),
            };
        }

        pub fn deinit(self: *@This(), allocator: mem.Allocator) void {
            self.state.deinit(allocator);
        }

        /// Needs to be run before transition
        // Note: It is tempting to put this in init
        // However then we either need to return two things from init, OR this
        // struct needs to become aware of where to send requests.
        pub fn initial_transition(
            self: *@This(),
            server_fd: Socket(FD).Server,
        ) ![]const OSRequest.T {
            const req = OSRequest.accept_multishot(
                @bitCast(UsrData{ .op = .accept_client_conn }),
                server_fd,
            );
            try self.os_req_buf.append(req);
            return self.os_req_buf.constSlice();
        }

        /// State Machine Transition Function
        pub fn transition(
            self: *@This(),
            response: OSResponse(FD),
        ) ![]const OSRequest.T {
            self.os_req_buf.clear();
            const res_ud: UsrData = @bitCast(response.usr_data);

            switch (res_ud.op) {
                .accept_client_conn => {
                    const fd: Socket(FD).Client = @enumFromInt(response.rc);

                    if (self.state.client_sockets.add(fd)) |client_id| {
                        try self.enqueue_os_send_req(
                            fd,
                            .{
                                .op = .send_ack_new_conn,
                                .client_id = client_id,
                            },
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
                .send_ack_new_conn => {
                    const os_req = self.state.send_ack_new_conn(response);
                    try self.os_req_buf.append(os_req);
                },
                .send_no_new_conn => {
                    @panic("TODO: handle this case");
                },
                // TODO: this just puts the req on the ring again...
                .recv => {
                    const os_req = self.state.recv(response);
                    try self.os_req_buf.append(os_req);
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
            const os_req = OSRequest.send(@bitCast(ud), fd, msg);
            try self.os_req_buf.append(os_req);
        }
    };
}

fn State(
    comptime FD: type,
    comptime OSReq: type,
    comptime limits: Limits,
) type {
    return struct {
        const Sock = Socket(FD);
        const ClientSockets = util.SlotMap(
            Sock.Client,
            Sock.client_eql,
            limits.max_clients,
            .{ .duplicates = false },
        );

        client_sockets: ClientSockets,
        recv_buf: []u8,

        fn init(allocator: mem.Allocator) !@This() {
            return .{
                .client_sockets = try ClientSockets.init(allocator),
                // TODO: one of these per client? they can be overwritten
                .recv_buf = try allocator.alloc(u8, limits.write_buf_size),
            };
        }

        fn deinit(self: *@This(), allocator: mem.Allocator) void {
            self.client_sockets.deinit(allocator);
            allocator.free(self.recv_buf);
        }

        fn send_ack_new_conn(self: *@This(), res: OSResponse(FD)) OSReq.T {
            var res_ud = UsrData.from_u64(res.usr_data);
            res_ud.op = .recv;
            return OSReq.recv(
                res_ud.to_u64(),
                self.client_sockets.get(res_ud.client_id).?,
                self.recv_buf,
            );
        }

        fn recv(self: *@This(), res: OSResponse(FD)) OSReq.T {
            const res_ud = UsrData.from_u64(res.usr_data);
            const buf_len: usize = @intCast(res.rc);
            debug.print("Client {d} sent {s}", .{
                res_ud.client_id,
                self.recv_buf[0..buf_len],
            });

            return OSReq.recv(
                res_ud.to_u64(),
                self.client_sockets.get(res_ud.client_id).?,
                self.recv_buf,
            );
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
        send_ack_new_conn,
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

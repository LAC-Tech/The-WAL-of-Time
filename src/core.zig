const std = @import("std");
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
    comptime IOReq: type,
    comptime limits: Limits,
) type {
    const IOReqs = std.BoundedArray(IOReq.T, config.max_io_req);

    return struct {
        io_req_buf: IOReqs,
        state: State(FD, IOReq, limits),

        pub fn init(allocator: mem.Allocator) !@This() {
            return .{
                .state = try State(FD, IOReq, limits).init(allocator),
                .io_req_buf = try IOReqs.init(0),
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
        ) ![]const IOReq.T {
            const req = IOReq.accept_multishot(
                @bitCast(UsrData{ .op = .accept_client_conn }),
                server_fd,
            );
            try self.io_req_buf.append(req);
            return self.io_req_buf.constSlice();
        }

        /// State Machine Transition Function
        pub fn transition(
            self: *@This(),
            response: Response(FD),
        ) ![]const IOReq.T {
            self.io_req_buf.clear();
            const res_ud: UsrData = @bitCast(response.usr_data);

            switch (res_ud.op) {
                .accept_client_conn => {
                    const io_req = self.state.accept_client_conn(response);
                    try self.io_req_buf.append(io_req);
                },
                .send_ack_new_conn => {
                    const io_req = self.state.send_ack_new_conn(response);
                    try self.io_req_buf.append(io_req);
                },
                .send_no_new_conn => {
                    @panic("TODO: handle this case");
                },
                // TODO: this just puts the req on the ring again...
                .recv => {
                    const io_req = self.state.recv(response);
                    try self.io_req_buf.append(io_req);
                },
            }

            return self.io_req_buf.constSlice();
        }
    };
}

fn State(
    comptime FD: type,
    comptime IOReq: type,
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

        fn accept_client_conn(self: *@This(), res: Response(FD)) IOReq.T {
            const fd: Sock.Client = @enumFromInt(res.rc);

            if (self.client_sockets.add(fd)) |client_id| {
                const ud: UsrData = .{
                    .op = .send_ack_new_conn,
                    .client_id = client_id,
                };

                return IOReq.send(
                    @bitCast(ud),
                    fd,
                    "connection acknowledged\n",
                );
            } else |err| switch (err) {
                error.Duplicate => {
                    const ud: UsrData = .{ .op = .send_no_new_conn };

                    return IOReq.send(
                        @bitCast(ud),
                        fd,
                        "client already connected\n",
                    );
                },
                error.Overflow => {
                    const ud: UsrData = .{ .op = .send_no_new_conn };

                    return IOReq.send(
                        @bitCast(ud),
                        fd,
                        "err: maximum connections reached\n",
                    );
                },
            }
        }

        fn send_ack_new_conn(self: *@This(), res: Response(FD)) IOReq.T {
            var res_ud: UsrData = @bitCast(res.usr_data);
            res_ud.op = .recv;
            return IOReq.recv(
                @bitCast(res_ud),
                self.client_sockets.get(res_ud.client_id).?,
                self.recv_buf,
            );
        }

        fn recv(self: *@This(), res: Response(FD)) IOReq.T {
            const res_ud: UsrData = @bitCast(res.usr_data);
            const buf_len: usize = @intCast(res.rc);
            debug.print("Client {d} sent {s}", .{
                res_ud.client_id,
                self.recv_buf[0..buf_len],
            });

            return IOReq.recv(
                @bitCast(res_ud),
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

pub fn Response(comptime FD: type) type {
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
};

comptime {
    // IO Uring user_data
    debug.assert(@sizeOf(u64) == @sizeOf(UsrData));
    // Kqueue udata
    debug.assert(@sizeOf(usize) == @sizeOf(UsrData));
}

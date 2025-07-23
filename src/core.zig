const std = @import("std");
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
    comptime AIOReq: type,
    comptime limits: struct {
        max_clients: comptime_int,
        write_buf_size: comptime_int,
    },
) type {
    const Sock = Socket(FD);
    const Clients = util.SlotMap(
        Sock.Client,
        Sock.client_eql,
        limits.max_clients,
        .{ .duplicates = false },
    );
    const AioReqs = std.BoundedArray(AIOReq.T, config.max_io_req);

    return struct {
        clients: Clients,
        recv_buf: []u8,
        io_req_buf: AioReqs,

        pub fn init(allocator: mem.Allocator) !@This() {
            return .{
                .clients = try Clients.init(allocator),
                // TODO: one of these per client? they can be overwritten
                .recv_buf = try allocator.alloc(u8, limits.write_buf_size),
                .io_req_buf = try AioReqs.init(0),
            };
        }

        pub fn deinit(self: *@This(), allocator: mem.Allocator) void {
            self.clients.deinit(allocator);
            allocator.free(self.recv_buf);
        }

        /// Needs to be run before transition
        // Note: It is tempting to put this in init
        // However then we either need to return two things from init, OR this
        // struct needs to become aware of where to send requests.
        pub fn initial_transition(
            self: *@This(),
            server_fd: Sock.Server,
        ) ![]const AIOReq.T {
            const usr_data: UsrData = .{ .op = .accept };
            const req = AIOReq.accept_multishot(@bitCast(usr_data), server_fd);
            try self.io_req_buf.append(req);
            return self.io_req_buf.constSlice();
        }

        /// State Machine Transition Function
        pub fn transition(
            self: *@This(),
            response: Response(FD),
        ) ![]const AIOReq.T {
            self.io_req_buf.clear();
            const res_ud: UsrData = @bitCast(response.usr_data);

            switch (res_ud.op) {
                .accept => {
                    const fd: Sock.Client = @enumFromInt(response.rc);
                    const id = try self.clients.add(fd);
                    const ud = UsrData{ .op = .send, .client_id = id };
                    const req = AIOReq.send(
                        @bitCast(ud),
                        fd,
                        "connection acknowledged\n",
                    );
                    try self.io_req_buf.append(req);
                },
                .send => {
                    const id = res_ud.client_id;
                    const ud = UsrData{ .op = .recv, .client_id = id };
                    const fd = self.clients.get(id).?;
                    const req = AIOReq.recv(@bitCast(ud), fd, self.recv_buf);

                    try self.io_req_buf.append(req);
                },
                .recv => {
                    const buf_len: usize = @intCast(response.rc);
                    debug.print("Msg received: {s}\n", .{
                        self.recv_buf[0..buf_len],
                    });

                    const id = res_ud.client_id;
                    const ud = UsrData{ .op = .recv, .client_id = id };
                    const fd = self.clients.get(res_ud.client_id).?;
                    const req = AIOReq.recv(@bitCast(ud), fd, self.recv_buf);

                    try self.io_req_buf.append(req);
                },
            }

            return self.io_req_buf.constSlice();
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
    op: enum(u8) { accept, send, recv },
    client_id: u8 = undefined,
    _padding: u48 = 0,
};

comptime {
    // IO Uring user_data
    debug.assert(@sizeOf(u64) == @sizeOf(UsrData));
    // Kqueue udata
    debug.assert(@sizeOf(usize) == @sizeOf(UsrData));
}

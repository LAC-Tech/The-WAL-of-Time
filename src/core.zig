const std = @import("std");
const debug = std.debug;
const mem = std.mem;

const util = @import("./util.zig");

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
    const Clients = util.SlotMap(
        FD.ClientSock.T,
        FD.ClientSock.eql,
        limits.max_clients,
        .{ .duplicates = false },
    );
    const AioReqs = std.BoundedArray(AIOReq.T, 2);

    return struct {
        clients: Clients,
        recv_buf: []u8,
        aio_req_buf: AioReqs,

        pub fn init(allocator: mem.Allocator) !@This() {
            return .{
                .clients = try Clients.init(allocator),
                // TODO: one of these per client?  they can be overwritten
                .recv_buf = try allocator.alloc(u8, limits.write_buf_size),
                .aio_req_buf = try AioReqs.init(0),
            };
        }

        pub fn deinit(self: *@This(), allocator: mem.Allocator) void {
            self.clients.deinit(allocator);
            allocator.free(self.recv_buf);
        }

        pub fn initial_aio_req(
            self: *@This(),
            fd: FD.ServerSock.T,
        ) ![]const AIOReq.T {
            const usr_data: UsrData = .{ .op = .accept };
            const req = AIOReq.accept_multishot(@bitCast(usr_data), fd);
            try self.aio_req_buf.append(req);
            return self.aio_req_buf.constSlice();
        }

        pub fn transition(self: *@This(), res: FD.IORes) ![]const AIOReq.T {
            self.aio_req_buf.clear();
            const res_ud: UsrData = @bitCast(res.usr_data);

            switch (res_ud.op) {
                .accept => {
                    const fd: FD.ClientSock.T = @enumFromInt(res.rc);
                    const client_id = try self.clients.add(fd);
                    const ud: u64 = @bitCast(
                        UsrData{ .op = .send, .client_id = client_id },
                    );

                    try self.aio_req_buf.append(
                        AIOReq.send(ud, fd, "connection acknowledged\n"),
                    );
                },
                .send => {
                    const ud: u64 = @bitCast(
                        .{ .op = .recv, .client_id = res_ud.client_id },
                    );
                    const fd_client = self.clients.get(res_ud.client_id).?;

                    try self.aio_req_buf.append(
                        AIOReq.recv(ud, fd_client, self.recv_buf),
                    );
                },
                .recv => {
                    const buf_len: usize = @intCast(res.rc);
                    const msg = self.recv_buf[0..buf_len];
                    debug.print("Msg received: {s}\n", .{msg});

                    const ud: u64 = @bitCast(
                        .{ .op = .recv, .client_id = res_ud.client_id },
                    );
                    const fd_client = self.clients.get(res_ud.client_id).?;

                    try self.aio_req_buf.append(
                        AIOReq.recv(ud, fd_client, self.recv_buf),
                    );
                },
            }

            return self.aio_req_buf.constSlice();
        }
    };
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

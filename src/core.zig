const std = @import("std");
const debug = std.debug;
const mem = std.mem;

const aio = @import("./async_io.zig");
const limits = @import("limits.zig");
const util = @import("./util.zig");

/// Deterministic, in-memory state machine that keeps track of things while the
/// node is running
pub fn InMem(
    comptime FD: type,
    comptime fd_eql: fn (FD, FD) bool,
    comptime AIOReq: type,
) type {
    const Clients = util.SlotMap(limits.max_clients, FD, fd_eql);
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

        pub fn initial_aio_req(self: *@This(), socket_fd: FD) ![]const AIOReq.T {
            const usr_data: UsrData = .{ .op = .accept };
            const req = AIOReq.accept_multishot(@bitCast(usr_data), socket_fd);
            try self.aio_req_buf.append(req);
            return self.aio_req_buf.constSlice();
        }

        fn prepare_client(self: *@This(), id: u8) AIOReq.T {
            // so we can receive a message
            const fd_client = self.clients.get(id) orelse {
                @panic("invalid client id");
            };

            const usr_data: u64 = @bitCast(UsrData{
                .op = .recv,
                .payload = .{ .client_id = id },
            });

            return AIOReq.recv(usr_data, fd_client, self.recv_buf);
        }

        pub fn res_with_ctx(self: *@This(), res: aio.Res(FD)) ![]const AIOReq.T {
            self.aio_req_buf.clear();
            const res_usr_data: UsrData = @bitCast(res.usr_data);

            switch (res_usr_data.op) {
                .accept => {
                    const fd_client: FD = res.rc;
                    const id = try self.clients.add(fd_client);

                    const usr_data: u64 = @bitCast(UsrData{
                        .op = .send,
                        .payload = .{ .client_id = id },
                    });

                    const req = AIOReq.send(
                        usr_data,
                        fd_client,
                        "connection acknowledged\n",
                    );

                    try self.aio_req_buf.append(req);
                },
                .send => {
                    const id = res_usr_data.payload.client_id;
                    const req = self.prepare_client(id);

                    try self.aio_req_buf.append(req);
                },
                .recv => {
                    const client_id = res_usr_data.payload.client_id;
                    const buf_len: usize = @intCast(res.rc);
                    const msg = self.recv_buf[0..buf_len];
                    std.debug.print("Msg received: {s}", .{msg});

                    const req = self.prepare_client(client_id);

                    try self.aio_req_buf.append(req);
                },
            }

            return self.aio_req_buf.constSlice();
        }
    };
}

const Op = enum(u8) { accept, send, recv };

pub fn Res(comptime FD: type) type {
    return union(Op) {
        accept: struct {
            reqs: struct { send: aio.req(FD).Send },
        },
        send: struct { reqs: struct { recv: aio.req(FD).Recv } },
        recv: struct {
            msg: []const u8,
            reqs: struct { recv: aio.req(FD).Recv },
        },
    };
}

/// Pata passed to async io systems
/// Sized at 64 bits to match io_urings user_data, and I think kqueue's udata

// Zig tagged unions can't be bitcast.
// So we hack it together like C
const UsrData = packed struct(u64) {
    op: Op,
    payload: packed union { client_id: u8 } = undefined,
    _padding: u48 = 0,
};

comptime {
    // IO Uring user_data
    debug.assert(@sizeOf(u64) == @sizeOf(UsrData));
    // Kqueue udata
    debug.assert(@sizeOf(usize) == @sizeOf(UsrData));
}

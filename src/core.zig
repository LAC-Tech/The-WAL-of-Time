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
) type {
    const Clients = util.SlotMap(limits.max_clients, FD, fd_eql);

    return struct {
        clients: Clients,
        recv_buf: []u8,

        pub fn init(allocator: mem.Allocator) !@This() {
            // TODO: one of these per client?  they can be overwritten
            const recv_buf = try allocator.alloc(u8, limits.write_buf_size);

            return .{
                .clients = try Clients.init(allocator),
                .recv_buf = recv_buf,
            };
        }

        pub fn deinit(self: *@This(), allocator: mem.Allocator) void {
            self.clients.deinit(allocator);
            allocator.free(self.recv_buf);
        }

        pub fn initial_aio_req() u64 {
            const usr_data: UsrData = .{ .op = .accept };
            return @bitCast(usr_data);
        }

        fn prepare_client(self: *@This(), id: u8) aio.req(FD).Recv {
            // so we can receive a message
            const fd_client = self.clients.get(id) orelse {
                @panic("invalid client id");
            };

            return .{
                .usr_data = @bitCast(UsrData{
                    .op = .recv,
                    .payload = .{ .client_id = id },
                }),
                .fd_client = fd_client,
                .buf = self.recv_buf,
            };
        }

        pub fn res_with_ctx(self: *@This(), res: aio.Res(FD)) !Res(FD) {
            const usr_data: UsrData = @bitCast(res.usr_data);

            switch (usr_data.op) {
                .accept => {
                    const fd_client: FD = res.rc;
                    const id = try self.clients.add(fd_client);

                    const send_req = aio.req(FD).Send{
                        .usr_data = @bitCast(UsrData{
                            .op = .send,
                            .payload = .{ .client_id = id },
                        }),
                        .fd_client = fd_client,
                        .buf = "connection acknowledged\n",
                    };

                    return .{
                        .accept = .{
                            .reqs = .{ .send = send_req },
                        },
                    };
                },
                .send => {
                    const client_id = usr_data.payload.client_id;

                    const recv_req = self.prepare_client(client_id);

                    return .{
                        .send = .{
                            .reqs = .{ .recv = recv_req },
                        },
                    };
                },
                .recv => {
                    const client_id = usr_data.payload.client_id;
                    const buf_len: usize = @intCast(res.rc);

                    const recv_req = self.prepare_client(client_id);

                    return .{
                        .recv = .{
                            .msg = self.recv_buf[0..buf_len],
                            .reqs = .{ .recv = recv_req },
                        },
                    };
                },
            }
        }
    };
}

pub fn Res(comptime FD: type) type {
    return union(aio.Op) {
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
    op: aio.Op,
    payload: packed union { client_id: u8 } = undefined,
    _padding: u48 = 0,
};

comptime {
    // IO Uring user_data
    debug.assert(@sizeOf(u64) == @sizeOf(UsrData));
    // Kqueue udata
    debug.assert(@sizeOf(usize) == @sizeOf(UsrData));
}

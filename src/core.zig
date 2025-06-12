const std = @import("std");
const debug = std.debug;
const mem = std.mem;

const aio = @import("./async_io.zig");
const limits = @import("limits.zig");
const util = @import("./util.zig");

const UsrData = aio.UsrData;

/// Deterministic, in-memory state machine that keeps track of things while the
/// node is running
pub fn InMem(
    comptime FD: type,
    comptime fd_eql: fn (FD, FD) bool,
) type {
    const ClientFDs = util.SlotMap(limits.max_clients, FD, fd_eql);

    return struct {
        client_fds: ClientFDs,
        recv_buf: []u8,

        pub fn init(allocator: mem.Allocator) !@This() {
            // TODO: one of these per client?  they can be overwritten
            const recv_buf = try allocator.alloc(u8, limits.write_buf_size);

            return .{
                .client_fds = try ClientFDs.init(allocator),
                .recv_buf = recv_buf,
            };
        }

        pub fn deinit(self: *@This(), allocator: mem.Allocator) void {
            self.client_fds.deinit(allocator);
            allocator.free(self.recv_buf);
        }

        pub fn initial_aio_req() u64 {
            const usr_data: UsrData = .{ .tag = .client_connected };
            return @bitCast(usr_data);
        }

        fn prepare_client(self: *@This(), client_slot: u8) aio.req(FD).Recv {
            // so we can receive a message
            const client_fd = self.client_fds.get(client_slot) orelse {
                @panic("expect to have a client fd here");
            };

            return .{
                .usr_data = UsrData.client_msg(client_slot),
                .client_fd = client_fd,
                .buf = self.recv_buf,
            };
        }

        pub fn res_with_ctx(self: *@This(), res: aio.Res(FD)) !Res(FD) {
            const usr_data: UsrData = @bitCast(res.usr_data);

            switch (usr_data.tag) {
                .client_connected => {
                    const client_fd: FD = res.rc;
                    const client_slot = try self.client_fds.add(client_fd);

                    const send_req = aio.req(FD).Send{
                        .usr_data = UsrData.client_ready(
                            client_slot,
                        ),
                        .client_fd = client_fd,
                        .buf = "connection acknowledged\n",
                    };

                    return .{
                        .client_connected = .{
                            .reqs = .{ .send = send_req },
                        },
                    };
                },
                .client_ready => {
                    const client_id = usr_data.payload.client_id;

                    const recv_req: aio.req(FD).Recv =
                        self.prepare_client(client_id);

                    return .{
                        .client_ready = .{
                            .reqs = .{ .recv = recv_req },
                        },
                    };
                },
                .client_msg => {
                    const client_id = usr_data.payload.client_id;
                    const buf_len: usize = @intCast(res.rc);

                    const recv_req: aio.req(FD).Recv =
                        self.prepare_client(client_id);

                    return .{
                        .client_msg = .{
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
    return union(aio.UsrData.Tag) {
        client_connected: struct {
            reqs: struct { send: aio.req(FD).Send },
        },
        client_ready: struct { reqs: struct { recv: aio.req(FD).Recv } },
        client_msg: struct {
            msg: []const u8,
            reqs: struct { recv: aio.req(FD).Recv },
        },
    };
}

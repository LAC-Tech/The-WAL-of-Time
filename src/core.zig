const std = @import("std");
const debug = std.debug;
const mem = std.mem;

const aio = @import("./async_io.zig");
const limits = @import("limits.zig");
const ds = @import("./ds.zig");

// TODO: awful hack
// Users of runtime should not have to know about UsrData
pub const UsrData = aio.UsrData;

/// Deterministic, in-memory state machine that keeps track of things while the
/// node is running
pub fn InMem(
    comptime fd: type,
    comptime fd_eql: fn (fd, fd) bool,
) type {
    const ClientFDs = ds.SlotMap(limits.max_clients, fd, fd_eql);
    const aio_msg = aio.msg(fd);
    const aio_req = aio_msg.req;

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
        }

        pub fn initial_aio_reqs() [limits.max_clients]u64 {
            const usr_data: UsrData = .{ .tag = .client_connected };
            return [_]u64{@bitCast(usr_data)} ** limits.max_clients;
        }

        pub fn register_client(self: *@This(), client_fd: fd) !aio_req.Send {
            const client_slot = try self.client_fds.add(client_fd);

            return .{
                .usr_data = UsrData.client_ready(client_slot),
                .client_fd = client_fd,
                .buf = "connection acknowledged\n",
            };
        }

        pub fn prepare_client(self: *@This(), client_slot: u8) aio_req.Recv {
            // so we can receive a message
            const client_fd = self.client_fds.get(client_slot) orelse {
                @panic("expect to have a client fd here");
            };

            @memset(self.recv_buf, 0);

            return .{
                .usr_data = UsrData.client_msg(client_slot),
                .client_fd = client_fd,
                .buf = self.recv_buf,
            };
        }
    };
}

const std = @import("std");
const debug = std.debug;
const mem = std.mem;

const limits = @import("./limits.zig");
const aio_msg = @import("./async_io_msg.zig");

// TODO: better name. Not only the enum name, but the names of the enums
const Tag = enum(u8) { client_connected, client_ready, client_msg };

// Zig tagged unions can't be bitcast.
// So we hack it together like C
// TODO: remove this pub
pub const UsrData = packed struct(u64) {
    tag: Tag,
    payload: packed union { client_slot: u8 },
    _padding: u48 = 0,

    pub const client_connected: u64 = @bitCast(@This(){
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

/// Deterministic, in-memory state machine that keeps track of things while the
/// node is running
pub fn RunTime(
    comptime FD: type,
    comptime fd_eql: fn (FD, FD) bool,
) type {
    const ClientFDs = SlotMap(FD, limits.max_clients, fd_eql);
    const aio_req = aio_msg.req(FD);

    const Res = union(Tag) {
        client_connected: struct {
            accept: aio_req.Accept,
            send: aio_req.Send,
        },
        client_ready: aio_req.Recv,
        client_msg: aio_req.Recv,
    };

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

        pub fn process_aio_res(self: *@This(), aio_res: aio_msg.Res) !Res {
            const usr_data: UsrData = @bitCast(aio_res.usr_data);

            switch (usr_data.tag) {
                .client_connected => {
                    const client_fd: FD = aio_res.rc;
                    const client_slot = try self.client_fds.add(client_fd);

                    return .{
                        .client_connected = .{
                            .accept = UsrData.client_connected,
                            .send = .{
                                .usr_data = UsrData.client_ready(client_slot),
                                .client_fd = client_fd,
                                .buf = "connection acknowledged\n",
                            },
                        },
                    };
                },
                .client_ready => {
                    const client_slot = usr_data.payload.client_slot;

                    return .{
                        .client_ready = self.prepare_client(client_slot),
                    };
                },
                .client_msg => {
                    const client_slot = usr_data.payload.client_slot;

                    // TODO: log this or something?
                    debug.print("received: {s}", .{self.recv_buf});

                    return .{
                        .client_ready = self.prepare_client(client_slot),
                    };
                },
            }
        }

        fn prepare_client(self: *@This(), client_slot: u8) aio_req.Recv {
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

pub const CreateSlotErr = error{
    ValAlreadyExists,
    MaxVals,
};

fn SlotMap(
    comptime T: type,
    comptime max_slots: usize,
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

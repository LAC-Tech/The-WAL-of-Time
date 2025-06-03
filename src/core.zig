const std = @import("std");
const debug = std.debug;
const mem = std.mem;

const aio = @import("./async_io.zig");
const limits = @import("limits.zig");

// TODO: awful hack
// Users of runtime should not have to know about UsrData
pub const UsrData = aio.UsrData;

/// Deterministic, in-memory state machine that keeps track of things while the
/// node is running
pub fn RunTime(
    comptime fd: type,
    comptime fd_eql: fn (fd, fd) bool,
) type {
    const ClientFDs = SlotMap(fd, limits.max_clients, fd_eql);
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

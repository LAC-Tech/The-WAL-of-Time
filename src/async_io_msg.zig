// TODO: this stuff is very POSIX specific

const std = @import("std");
const debug = std.debug;

pub const Res = struct { rc: i32, usr_data: u64 };

pub fn req(comptime fd: type) type {
    return struct {
        pub const Send = struct { usr_data: u64, client_fd: fd, buf: []const u8 };
        pub const Recv = struct { usr_data: u64, client_fd: fd, buf: []u8 };
    };
}

/// Pata passed to async io systems
/// Sized at 64 bits to match io_urings user_data, and I think kqueue's udata

// Zig tagged unions can't be bitcast.
// So we hack it together like C
pub const UsrData = packed struct(u64) {
    tag: enum(u8) { client_connected, client_ready, client_msg },
    payload: packed union { client_slot: u8 } = undefined,
    _padding: u48 = 0,

    pub const client_connected: u64 = @bitCast(@This(){
        .tag = .client_connected,
        .payload = undefined,
    });

    pub fn client_ready(client_slot: u8) u64 {
        const result = @This(){
            .tag = .client_ready,
            .payload = .{ .client_slot = client_slot },
        };

        return @bitCast(result);
    }

    pub fn client_msg(client_slot: u8) u64 {
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

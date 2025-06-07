// TODO: this stuff is very POSIX specific

const std = @import("std");
const debug = std.debug;

pub fn msg(comptime fd: type) type {
    return struct {
        pub const Res = struct { rc: fd, usr_data: u64 };
        pub const req = struct {
            pub const Accept = u64;
            pub const Send = struct {
                usr_data: u64,
                client_fd: fd,
                buf: []const u8,
            };
            pub const Recv = struct { usr_data: u64, client_fd: fd, buf: []u8 };
        };
    };
}

/// Pata passed to async io systems
/// Sized at 64 bits to match io_urings user_data, and I think kqueue's udata

// Zig tagged unions can't be bitcast.
// So we hack it together like C
pub const UsrData = packed struct(u64) {
    tag: enum(u8) { client_connected, client_ready, client_msg },
    payload: packed union { client_id: u8 } = undefined,
    _padding: u48 = 0,

    pub const client_connected: u64 = @bitCast(@This(){
        .tag = .client_connected,
        .payload = undefined,
    });

    pub fn client_ready(client_id: u8) u64 {
        const result = @This(){
            .tag = .client_ready,
            .payload = .{ .client_id = client_id },
        };

        return @bitCast(result);
    }

    pub fn client_msg(client_id: u8) u64 {
        const result = @This(){
            .tag = .client_msg,
            .payload = .{ .client_id = client_id },
        };

        return @bitCast(result);
    }
};

comptime {
    debug.assert(8 == @sizeOf(UsrData));
}

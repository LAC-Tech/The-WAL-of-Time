//! This modules bridges the gap between the state machine and particular OS
//! They are OS independent, but also represent quite low level operations
const std = @import("std");
const debug = std.debug;
const testing = std.testing;

const config = @import("config.zig");

/// This modules bridges the gap between the state machine and particular OS
/// They are OS independent, but also represent quite low level operations
pub const Accept = packed struct {
    _padding: u56 = 0,

    pub fn toUserData(self: Accept) u64 {
        const ud = UserData{
            .syscall = .accept,
            .payload = .{ .accept = self },
        };

        return @bitCast(ud);
    }
};

pub const Recv = packed struct {
    client_fd: i32,
    _padding: u24 = 0,

    pub fn toUserData(self: Recv) u64 {
        const ud = UserData{
            .syscall = .recv,
            .payload = .{ .recv = self },
        };

        return @bitCast(ud);
    }
};

pub const Send = packed struct {
    buf_id: u32,
    _padding: u24 = 0,

    pub fn toUserData(self: Send) u64 {
        const ud = UserData{
            .syscall = .send,
            .payload = .{ .send = self },
        };

        return @bitCast(ud);
    }
};

pub const Syscall = enum(u8) { accept = 1, recv = 2, send = 3 };

const Payload = packed union {
    accept: Accept,
    recv: Recv,
    send: Send,
};

const UserData = packed struct {
    syscall: Syscall,
    payload: Payload,

    comptime {
        debug.assert(@sizeOf(UserData) == 8);
        debug.assert(@bitSizeOf(UserData) == 64);
    }
};

pub fn fromUserData(ud: u64) UserData {
    return @bitCast(ud);
}

pub fn accept() Accept {
    return .{};
}

pub fn recv(client_fd: i32) Recv {
    return .{ .client_fd = client_fd };
}

pub fn send(buf_id: u32) Send {
    return .{ .buf_id = buf_id };
}

test "serde Userdata" {
    var rng = std.Random.DefaultPrng.init(testing.random_seed);

    debug.print("{}", .{testing.random_seed});

    for (0..1_000_000) |_| {
        const expected = switch (rng.random().enumValue(Syscall)) {
            .accept => accept().toUserData(),
            .recv => recv(rng.random().int(i32)).toUserData(),
            .send => send(rng.random().int(u32)).toUserData(),
        };
        const ud_recvd = fromUserData(expected);
        const actual = switch (ud_recvd.syscall) {
            .accept => ud_recvd.payload.accept.toUserData(),
            .recv => ud_recvd.payload.recv.toUserData(),
            .send => ud_recvd.payload.send.toUserData(),
        };

        try testing.expectEqual(expected, actual);
    }
}

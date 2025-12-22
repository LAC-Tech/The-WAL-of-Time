//! Glue layer between a core and a particular OS
//! They are OS independent, but also represent quite low level operations
const std = @import("std");
const debug = std.debug;
const testing = std.testing;

const config = @import("config.zig");

pub const Accept = packed struct {
    _padding: u56 = 0,

    pub fn toU64(self: Accept) u64 {
        const ud = UserData{
            .syscall = .accept,
            .msg = .{ .accept = self },
        };
        return @bitCast(ud);
    }
};

pub const Recv = packed struct {
    client_fd: i32,
    _padding: u24 = 0,

    pub fn toU64(self: Recv) u64 {
        const ud = UserData{
            .syscall = .recv,
            .msg = .{ .recv = self },
        };
        return @bitCast(ud);
    }
};

pub const Send = packed struct {
    buf_id: u16,
    _padding: u40 = 0,

    pub fn toU64(self: Send) u64 {
        const ud = UserData{
            .syscall = .send,
            .msg = .{ .send = self },
        };
        return @bitCast(ud);
    }
};

pub const Close = packed struct {
    _padding: u56 = 0,

    pub fn toU64(self: Close) u64 {
        const ud = UserData{
            .syscall = .close,
            .msg = .{ .close = self },
        };
        return @bitCast(ud);
    }
};

pub const Syscall = enum(u8) { accept, recv, send, close };

pub const UserData = packed struct {
    syscall: Syscall,
    msg: packed union {
        accept: Accept,
        recv: Recv,
        send: Send,
        close: Close,
    },

    comptime {
        debug.assert(@sizeOf(UserData) == 8);
        debug.assert(@bitSizeOf(UserData) == 64);
    }

    pub fn accept() Accept {
        return .{};
    }

    pub fn recv(client_fd: i32) Recv {
        return .{ .client_fd = client_fd };
    }

    pub fn send(buf_id: u16) Send {
        return .{ .buf_id = buf_id };
    }

    pub fn close() Close {
        return .{};
    }

    pub fn fromU64(n: u64) UserData {
        return @bitCast(n);
    }
};

pub const Res = struct {
    user_data: UserData,
    more: bool,
    buf_id: u16,
    result: i32,

    pub fn isError(self: Res) bool {
        return self.result < 0;
    }
};

pub const Req = union(enum) {
    recv: struct { client_fd: i32 },
    send: struct { client_fd: i32, buf_id: u16, len: usize },
    close: struct { client_fd: i32 },
    accept: struct { server_fd: i32 },
    release_buf: struct { buf_id: u16 },
};

test "UserData round-trip" {
    var rng = std.Random.DefaultPrng.init(testing.random_seed);

    debug.print("{}", .{testing.random_seed});

    for (0..1_000) |_| {
        const accept_expected = Accept{};
        const recv_expectedc = Recv{ .client_fd = rng.random().int(i32) };
        const send_expected = Send{ .buf_id = rng.random().int(u16) };

        const accept_u64 = accept_expected.toU64();
        const recv_u64 = recv_expectedc.toU64();
        const send_u64 = send_expected.toU64();

        const accept_actual = UserData.fromU64(accept_u64);
        const recv_actual = UserData.fromU64(recv_u64);
        const send_actual = UserData.fromU64(send_u64);

        // Verify we get the same values back
        try testing.expect(accept_actual.syscall == .accept);
        try testing.expect(recv_actual.syscall == .recv);
        try testing.expect(send_actual.syscall == .send);
        try testing.expect(
            recv_actual.msg.recv.client_fd == recv_expectedc.client_fd,
        );
        try testing.expect(send_actual.msg.send.buf_id == send_expected.buf_id);
    }
}

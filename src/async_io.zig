// TODO: this stuff is very POSIX specific

const std = @import("std");
const debug = std.debug;

pub fn Res(comptime fd: type) type {
    return struct { rc: fd, usr_data: u64 };
}

pub fn req(comptime fd: type) type {
    return struct {
        pub const Accept = u64;
        pub const Send = struct {
            usr_data: u64,
            fd_client: fd,
            buf: []const u8,
        };
        pub const Recv = struct { usr_data: u64, fd_client: fd, buf: []u8 };
    };
}

pub const Op = enum(u8) { accept, send, recv };

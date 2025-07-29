//! Information used for communicating with the underlying operating system

const std = @import("std");

pub fn os(comptime FD: type) type {
    return struct {
        pub const Socket = struct {
            pub const Client = enum(FD) { _ };
            pub const Server = enum(FD) { _ };

            pub fn client_eql(a: Client, b: Client) bool {
                return std.meta.eql(a, b);
            }
        };

        pub const Response = struct { rc: FD, usr_data: UsrData };

        pub const Request = struct {
            op: union(enum) {
                accept: struct { fd: Socket(FD).Server },
                recv: struct { fd: Socket(FD).Client, buf: []u8 },
                send: struct { fd: Socket(FD).Client, buf: []const u8 },
            },
            shot: enum { multi, one },
            usr_data: u64,
        };
    };
}

/// Data passed to async io systems
pub const UsrData = union(enum) {
    accept_client_conn,
    send_conn_ack,
    send_no_new_conn,
    recv,
};

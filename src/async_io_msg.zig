// This is very POSIX centric

pub const Res = struct { rc: i32, usr_data: u64 };

pub fn req(comptime FD: type) type {
    return struct {
        pub const Accept = u64;
        pub const Send = struct { usr_data: u64, client_fd: FD, buf: []const u8 };
        pub const Recv = struct { usr_data: u64, client_fd: FD, buf: []u8 };
    };
}

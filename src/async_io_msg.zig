// TODO: this is very POSIX specific

pub const Res = struct { rc: i32, usr_data: u64 };

pub fn req(comptime fd: type) type {
    return struct {
        pub const Send = struct { usr_data: u64, client_fd: fd, buf: []const u8 };
        pub const Recv = struct { usr_data: u64, client_fd: fd, buf: []u8 };
    };
}

/// Generic file descriptor module
/// On linux it's an i32, but for the sim it's easier if it's a usize
pub fn module(comptime Integer: type) type {
    return struct {
        pub const Int = Integer;
        pub const IORes = struct { rc: Int, usr_data: u64 };

        fn CreateSock() type {
            return struct {
                pub const T = enum(Int) { _ };
                pub fn eql(a: T, b: T) bool {
                    return @intFromEnum(a) == @intFromEnum(b);
                }
            };
        }

        pub const ClientSock = CreateSock();
        pub const ServerSock = CreateSock();
    };
}

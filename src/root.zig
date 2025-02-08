const std = @import("std");

const mem = std.mem;
const posix = std.posix;
const testing = std.testing;

// TODO: test if determinstic
// Looking at the code I am 95% sure..
const AutoHashMap = std.AutoHashMap;

const DeviceID = enum(u128) {
    _,
};
const StreamID = enum(u128) {
    _,
};

pub fn Stream(comptime OS: type) type {
    return struct {
        os: *OS,
        local: posix.fd_t,
        remotes: AutoHashMap(DeviceID, posix.fd_t),
        lc: LogicalClock,

        pub fn init(
            os: *OS,
            fd: posix.fd_t,
            allocator: mem.Allocator,
        ) @This() {
            return .{
                .os = os,
                .local = fd,
                .remotes = AutoHashMap.init(allocator),
                .lc = LogicalClock.init(allocator),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.remotes.deinit();
            self.lc.deinit();
        }
    };
}

//
const LogicalClock = struct {
    vv: AutoHashMap(DeviceID, u64),
    fn init(allocator: mem.Allocator) @This() {
        return .{ .vv = AutoHashMap.init(allocator) };
    }
    fn deinit(self: *@This()) void {
        self.vv.deinit();
    }
};

pub fn Node(comptime OS: type) type {
    return struct { device_id: DeviceID, os: *OS };
}

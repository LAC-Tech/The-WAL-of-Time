const std = @import("std");

const mem = std.mem;
const posix = std.posix;
const testing = std.testing;

const HashMap = std.HashMap;

const DeviceID = struct {};

const DeterministicHashContext = struct {
    seed: u64,

    pub fn hash(self: @This(), key: DeviceID) u64 {
        var hasher = std.hash.Wyhash.init(self.seed);
        hasher.update(key);
        return hasher.final();
    }

    pub const eql = std.hash_map.getAutoEqlFn(DeviceID, @This());
};

pub fn Stream(comptime OS: type) type {
    const Remotes = HashMap(DeviceID, posix.fd_t, DeterministicHashContext, 80);

    return struct {
        os: *OS,
        local: posix.fd_t,
        remotes: Remotes,

        pub fn init(
            os: *OS,
            fd: posix.fd_t,
            allocator: mem.Allocator,
            seed: u64,
        ) @This() {
            return .{
                .os = os,
                .local = fd,
                .remotes = Remotes.initContext(allocator, .{ .seed = seed }),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.remotes.deinit();
        }
    };
}

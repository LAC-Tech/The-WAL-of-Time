const std = @import("std");

const mem = std.mem;
const posix = std.posix;
const testing = std.testing;

pub const OsInput = union(enum) {
    create,
    read: struct { fd: posix.fd_t, buf: []u8, offset: usize },
    append: struct { fd: posix.fd_t, data: []const u8 },
    delete: posix.fd_t,
};

pub const OsOutput = union(enum) {
    create: posix.fd_t,
    read: usize,
    append: usize,
    delete: bool,
};

const Tasks = struct {
    const Callback = union {
        stream_created: *const fn () void,
    };

    callbacks: []const Callback,
    high_water_mark: usize = 0,
    recycled: std.ArrayListUnmanaged(usize),
    allocator: mem.Allocator,

    fn init(allocator: mem.Allocator) !@This() {
        return Tasks{
            .callbacks = try allocator.alloc(Callback, 256),
            .recycled = try std.ArrayListUnmanaged(usize).initCapacity(
                allocator,
                128,
            ),
            .allocator = allocator,
        };
    }

    fn deinit(self: *@This()) void {
        self.allocator.free(self.callbacks);
        self.recycled.deinit(self.allocator);
    }

    fn add(self: *@This(), cb: Callback) usize {
        if (self.recycled.pop()) |index| {
            self.callbacks[index] = cb;
            return index;
        } else {
            const index = self.high_water_mark;
            self.callbacks[index] = cb;
            self.high_water_mark += 1;
            return index;
        }
    }
};

pub fn DB(comptime OS: type) type {
    return struct {
        tasks: Tasks,
        os: OS,

        pub fn init(allocator: mem.Allocator) !@This() {
            return .{
                .os = try OS.init(allocator, &on_os_output),
                .tasks = try Tasks.init(allocator),
            };
        }

        fn on_os_output(self: *@This(), msg: OsOutput) void {
            _ = self;
            _ = msg;
            @panic("TODO: handle os output messages in DB struct");
        }

        pub fn deinit(self: *@This()) void {
            self.os.deinit();
            self.tasks.deinit();
        }

        pub fn create_stream(
            self: *@This(),
            cb: *const fn (ctx: anytype) void,
        ) void {
            const index = self.tasks.add(.{}, .{ .stream_created = cb });
            self.os.send(.{}, .create, index);
        }
    };
}

//// TODO: test if determinstic
//// Looking at the code I am 95% sure..
//const AutoHashMap = std.AutoHashMap;
//const StringHashMapUnmanaged = std.StringHashMapUnmanaged;
//
//pub fn DB(comptime OS: type) type {
//    return struct {
//        device_id: DeviceID,
//        os: *OS,
//        streams: StringHashMapUnmanaged(Stream(OS)),
//        allocator: mem.Allocator,
//
//        pub fn init(
//            device_id: DeviceID,
//            os: *OS,
//            allocator: mem.Allocator,
//        ) @This() {
//            return .{
//                .device_id = device_id,
//                .os = os,
//                .streams = .{},
//                .allocator = allocator,
//            };
//        }
//
//        pub fn deinit(self: *@This()) void {
//            // TODO: who owns the keys?
//            self.streams.deinit(self.allocator);
//        }
//
//        fn stream_from_fd(ctx: anytype, fd: posix.OpenError!posix.fd_t) void {
//            return Stream.init(ctx.os, fd);
//        }
//        pub fn create_stream(
//            self: *@This(),
//            comptime Ctx: type,
//            ctx: *Ctx,
//            stream_created: *const fn() void,
//        ) !void {
//            try self.os.create_file(ctx, stream_from_fd);
//        }
//    };
//}
//
//fn Stream(comptime OS: type) type {
//    return struct {
//        os: *OS,
//        local: posix.fd_t,
//        remotes: AutoHashMap(DeviceID, posix.fd_t),
//        lc: LogicalClock,
//
//        pub fn init(
//            os: *OS,
//            fd: posix.fd_t,
//            allocator: mem.Allocator,
//        ) @This() {
//            return .{
//                .os = os,
//                .local = fd,
//                .remotes = AutoHashMap.init(allocator),
//                .lc = LogicalClock.init(allocator),
//            };
//        }
//
//        pub fn deinit(self: *@This()) void {
//            self.remotes.deinit();
//            self.lc.deinit();
//        }
//    };
//}
//
//pub const DeviceID = enum(u128) {
//    _,
//    pub fn init(rng: anytype) @This() {
//        return @enumFromInt(rng.random().int(u128));
//    }
//};
//const StreamID = enum(u128) { _ };
//
//// Thin wrapper; there are more space efficient logical clocks I need to
//// investigate, ie interval tree clocks.
//const LogicalClock = struct {
//    vv: AutoHashMap(DeviceID, u64),
//    fn init(allocator: mem.Allocator) @This() {
//        return .{ .vv = AutoHashMap.init(allocator) };
//    }
//    fn deinit(self: *@This()) void {
//        self.vv.deinit();
//    }
//};

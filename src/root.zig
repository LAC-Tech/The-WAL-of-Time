const std = @import("std");

const mem = std.mem;
const posix = std.posix;
const testing = std.testing;

pub fn AsyncRuntime(
    comptime FD: type, 
    comptime OSFunctor: fn(fd: FD) type,
    /// Some state, so that callbacks can effect the outside world.
    /// What Baker/Hewitt called "proper environment", AFAICT
    comptime Env: type,
) type {
    return struct {
        const TaskID = u64;
        pub const OsInput = struct {
            task_id: TaskID,
            // Represent inputs for syscalls
            file_op: union(enum) {
                create,
                read: struct { fd: FD, buf: []u8, offset: usize },
                append: struct { fd: FD, data: []const u8 },
                delete: FD,
            },
        };

        pub const OsOutput = struct {
            task_id: TaskID,
            // Represent outputs for syscalls
            file_op: union(enum) {
                create: posix.fd_t,
                read: usize,
                append: usize,
                delete: bool,
            },
        };

        const OS = OSFunctor(FD);

        // We always know what type the function is at this point
        const Callback = union {
            create: *const fn(env: *Env, fd: FD) void,
        };

        // "Unit of execution"
        const Task = struct {env: *Env, callback: Callback};

        tasks: std.ArrayListUnmanaged(Task),
        recycled: std.ArrayListUnmanaged(TaskID),
        allocator: mem.Allocator,

        fn init(allocator: mem.Allocator) !@This() {
            return .{
                .tasks = try std.ArrayListUnmanaged(Task).initCapacity(
                    allocator,
                    256,
                ),
                .recycled = try std.ArrayListUnmanaged(TaskID).initCapacity(
                    allocator,
                    128,
                ),
                .allocator = allocator,
            };
        }

        fn deinit(self: *@This()) void {
            self.tasks.deinit(self.allocator);
            self.recycled.deinit(self.allocator);
        }

        fn push(self: *@This(), t: Task) !usize {
            if (self.recycled.popOrNull()) |index| {
                self.tasks.items[index] = t;
                return index;
            } else {
                const index = self.tasks.items.len;
                try self.tasks.append(self.allocator, t);
                return index;
            }
        }

        fn pop(self: *@This(), task_id: TaskID) Task {
            self.recycled.append(self.allocator, task_id) catch |err| {
                @panic(@errorName(err));
            };
            return self.tasks.items[@intCast(task_id)];
        }
    };
}

pub fn DB(
    comptime FD: type, 
    comptime OSFunctor: fn(fd: FD) type,
    comptime Env: type,
) type {
    return struct {
        async_runtime: AsyncRuntime(FD, OSFunctor, Env),

        pub fn init(allocator: mem.Allocator) !@This() {
            return .{
                .async_runtime = try AsyncRuntime(FD,OSFunctor, Env,).init(allocator),
            };
        }

        fn os_receive(self: *@This(), msg: os.Output) void {
            switch (msg.file_op) {
                .create => |fd| {
                    const t = self.async_runtime.pop(msg.task_id);
                    const fp: *const fn (*@This(), posix.fd_t) void =
                        @ptrCast(t.callback);

                    fp(self, fd);
                },
                .read => @panic("TODO: handle receiving 'read' from OS"),
                .append => @panic("TODO: handle receiving 'append' from OS"),
                .delete => @panic("TODO: handle receiving 'delete' from OS"),
            }
        }

        pub fn deinit(self: *@This()) void {
            self.os.deinit();
            self.async_runtime.deinit();
        }

        pub fn create_stream(
            self: *@This(),
            ctx: *UserCtx,
            cb: *const fn (ctx: *UserCtx, fd: posix.fd_t) void,
        ) !void {
            const index = try self.async_runtime.push(.{
                .ctx = ctx,
                .callback = @ptrCast(cb),
            });
            try self.os.send(ctx, .{ .task_id = index, .file_op = .create });
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

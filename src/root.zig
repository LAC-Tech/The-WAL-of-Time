const std = @import("std");

const mem = std.mem;
const posix = std.posix;
const testing = std.testing;

// Data structures for interacting with the OS
pub const os = struct {
    pub const Input = struct {
        task_id: task.ID,
        // Represent inputs for syscalls
        file_op: union(enum) {
            create,
            read: struct { fd: posix.fd_t, buf: []u8, offset: usize },
            append: struct { fd: posix.fd_t, data: []const u8 },
            delete: posix.fd_t,
        },
    };

    pub const Output = struct {
        task_id: task.ID,
        // Represent outputs for syscalls
        file_op: union(enum) {
            create: posix.fd_t,
            read: usize,
            append: usize,
            delete: bool,
        },
    };
};

// "Unit of execution"
const task = struct {
    const ID = u64;

    fn Task(comptime UserCtx: type) type {
        return struct {
            // Pointer to some mutable context, so the callback can effect
            // the outside world.
            // What Baker/Hewitt called "proper environment", AFAICT
            ctx: *UserCtx,
            // Executed when the OS Output is available.
            // First param will always be the context
            callback: *const anyopaque,
        };
    }
};

// Currently in-flight "units of execution" waiting to be completed
fn AsyncRuntime(comptime UserCtx: type) type {
    const Task = task.Task(UserCtx);
    return struct {
        tasks: std.ArrayListUnmanaged(Task),
        recycled: std.ArrayListUnmanaged(task.ID),
        allocator: mem.Allocator,

        fn init(allocator: mem.Allocator) !@This() {
            return .{
                .tasks = try std.ArrayListUnmanaged(Task).initCapacity(
                    allocator,
                    256,
                ),
                .recycled = try std.ArrayListUnmanaged(task.ID).initCapacity(
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

        fn push(self: *@This(), t: Task) usize {
            if (self.recycled.pop()) |index| {
                self.tasks.items[index] = t;
                return index;
            } else {
                const index = self.tasks.items.len;
                self.tasks.append(t);
                return index;
            }
        }

        fn pop(self: *@This(), task_id: task.ID) Task {
            self.recycled.append(task_id);
            return self.callbacks[@intCast(task_id)];
        }
    };
}

pub fn DB(comptime OS: type, comptime UserCtx: type) type {
    return struct {
        async_runtime: AsyncRuntime(UserCtx),
        os: OS,

        pub fn init(allocator: mem.Allocator) !@This() {
            return .{
                .os = try OS.init(allocator, &os_receive),
                .async_runtime = try AsyncRuntime(UserCtx).init(allocator),
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

            @panic("TODO: handle os output messages in DB struct");
        }

        pub fn deinit(self: *@This()) void {
            self.os.deinit();
            self.tasks.deinit();
        }

        pub fn create_stream(
            self: *@This(),
            ctx: *UserCtx,
            cb: *const fn (ctx: *UserCtx, fd: posix.fd_t) void,
        ) void {
            const index = self.async_runtime.push(.{
                .ctx = ctx,
                .callback = @ptrCast(cb),
            });
            self.os.send(.create, index);
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

const std = @import("std");

const mem = std.mem;
const posix = std.posix;
const testing = std.testing;

const StringHashMapUnmanaged = std.StringHashMapUnmanaged;

// Unique identifier for messages
const ReqID = u64;

const Req = union(enum) { create_stream: []const u8 };
pub const Res = union(enum) { stream_created: []const u8 };

// In flight messages, as a sort of ECS list
const Reqs = struct {
    reqs: std.ArrayListUnmanaged(Req),
    available_ids: std.ArrayListUnmanaged(ReqID),

    fn init(allocator: mem.Allocator) !@This() {
        return .{
            .msgs = try std.ArrayListUnmanaged(Req).initCapacity(
                allocator,
                256,
            ),
            .available_ids = try std.ArrayListUnmanaged(ReqID).initCapacity(
                allocator,
                128,
            ),
        };
    }

    fn deinit(self: *@This(), allocator: mem.Allocator) void {
        self.tasks.deinit(allocator);
        self.recycled.deinit(allocator);
    }

    fn add(self: *@This(), msg: Req, allocator: mem.Allocator) !void {
        // Reuse a slot if one is available
        if (self.available_ids.popOrNull()) |id| {
            self.reqs.items[id] = msg;
            return;
        }

        // Otherwise, add to the end
        try self.reqs.append(msg, allocator);
    }

    fn remove(self: *@This(), id: ReqID, allocator: mem.Allocator) !void {
        const msg = self.reqs.items[id];
        try self.available_ids.append(id, allocator);
        return msg;
    }
};

pub fn FileOp(comptime FD: type) type {
    return struct {
        pub const Input = struct {
            req_id: ReqID,
            // Represent inputs for syscalls
            args: union(enum) {
                create,
                read: struct { fd: FD, buf: []u8, offset: usize },
                append: struct { fd: FD, data: []const u8 },
                delete: FD,
            },
        };

        pub const Output = struct {
            req_id: ReqID,
            // Represent outputs for syscalls
            ret_val: union(enum) {
                create: posix.fd_t,
                read: usize,
                append: usize,
                delete: bool,
            },
        };
    };
}

//// TODO: test if determinstic
//// Looking at the code I am 95% sure..
//const AutoHashMap = std.AutoHashMap;

pub fn Node(
    comptime FileIO: type,
    comptime Context: type,
    comptime Receiver: fn (ctx: *Context, res: Res) void,
) type {
    return struct {
        db: DB(FileIO, Context, Receiver),
        file_io: FileIO,

        pub fn init(
            allocator: mem.Allocator,
            ctx: Context,
        ) @This() {
            const db = DB(FileIO).init(allocator, ctx.receiver);
            const file_io = FileIO.init(allocator, db.receive_io);
            return .{ .db = db, .file_io = file_io };
        }

        pub fn deinit(self: *@This()) @This() {
            self.db.deinit();
            self.file_io.deinit();
        }

        pub fn create_stream(self: *@This(), name: []const u8) void {
            self.db.send(.{ .create_stream = name }, self.file_io);
        }
    };
}

fn DB(
    comptime FileIO: type,
    comptime Context: type,
    comptime Receiver: fn (ctx: *Context, res: Res) void,
) type {
    return struct {
        reqs: Reqs,
        streams: StringHashMapUnmanaged(FileIO.FD),
        receiver: Receiver,
        allocator: mem.Allocator,

        pub fn init(
            allocator: mem.Allocator,
            receiver: fn (res: Res) void,
        ) @This() {
            return .{
                .reqs = Reqs.init(allocator),
                .streams = .{},
                .receiver = receiver,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *@This()) void {
            // TODO: keys need to be freed.
            self.streams.deinit(self.allocator);
        }

        pub fn send(self: *@This(), req: Req, file_io: anyopaque) !void {
            const id = try self.reqs.add(req);
            // given a particular msg, dispatch the appropriate file op
            switch (req) {
                .create_stream => {
                    const file_op = FileOp(FileIO.FD).Input{
                        .req_id = id,
                        .args = .{.create},
                    };
                    file_io.send(id, file_op);
                },
            }
        }

        fn receive_io(
            self: *@This(),
            file_op: FileOp(FileIO.FD).Output,
        ) !void {
            const req = try self.reqs.remove(file_op.req_id);

            switch (req) {
                .create_stream => |name| {
                    self.streams.insert(name, file_op.ret_val);
                    self.receiver(.{.stream_created + name});
                },
            }
        }
    };
}

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

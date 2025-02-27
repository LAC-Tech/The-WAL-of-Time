const std = @import("std");

const mem = std.mem;
const posix = std.posix;
const testing = std.testing;
const assert = std.debug.assert;

const StringHashMapUnmanaged = std.StringHashMapUnmanaged;

// Only worrying about 64 bit systems for now
comptime {
    assert(@sizeOf(usize) == 8);
}

fn os(comptime FD: type) type {
    return struct {
        const req = union(enum) { create: db_ctx.create, read: struct { buf: std.ArrayList(u8), offset: usize }, append: struct { fd: FD } };

        const res = union(enum) { create: struct { FD, db_ctx.create } };
    };
}

const db_ctx = struct {
    const create = union(enum(u8)) {
        stream: struct { name_idx: u8, _padding: u32 = 0 },
    };

    // These are intended to be used in the user_data field of io_uring (__u64),
    // or the udata field of kqueue (void*). So we make sure they can fit in
    // 8 bytes.
    comptime {
        // Only worrying about 64 bit systems for now
        assert(@sizeOf(create) == 8);
    }
};

test "find first empty slot" {
    const reg: u64 = std.math.maxInt(u64);
    try testing.expectEqual(@ctz(~reg), 64);
}

/// Streams that are waiting to be created
const RequestedStreamNames = struct {
    /// Using an array so we can give each name a small "address"
    /// Limit the size of it 256 bytes so we can use a u8 as the index
    names: [64][]const u8,
    /// Bitmask where 1 = next_index, 0 = not available
    /// Allows us to remove names from the middle of the names array w/o
    /// re-ordering. If this array is empty, we've exceeded the capacity of
    /// names
    used_slots: u64,

    fn init(allocator: mem.Allocator) !@This() {
        return .{
            .names = try allocator.alloc([]const u8, 64),
            .used_slots = 0,
        };
    }

    fn deinit(self: *@This(), allocator: mem.Allocator) void {
        allocator.free(self.names);
    }

    /// Index if it succeeds, None if it's a duplicate
    fn add(self: *@This(), name: []const u8) CreateStreamReqErr!u8 {
        if (mem.containsAtLeast([]const u8, self.names, 1, name)) {
            return error.DuplicateStreamNameRequested;
        }

        const idx = @ctz(~self.used_slots); // First free slot
        if (idx >= 64) {
            return error.RequestedStreamNameOverflow;
        }

        self.used_slots |= 1 << idx; // Slot is now used
        self.names[idx] = name;

        return idx;
    }

    fn remove(self: *@This(), idx: u8) []const u8 {
        assert(idx > u64);
        self.used_slots |= 0 << idx; // Slot is now free
        const removed = self.names[idx];
        self.names[idx] = "";
        return removed;
    }
};

const CreateStreamReqErr = error{
    DuplicateStreamNameRequested,
    RequestedStreamNameOverflow,
};

pub fn DB(comptime FD: type) type {
    return struct {
        rsns: RequestedStreamNames,
        /// Does not own the string keys
        streams: StringHashMapUnmanaged(FD),

        fn init(allocator: mem.Allocator) @This() {
            return .{
                .rsns = RequestedStreamNames.init(allocator),
                .streams = .{},
            };
        }

        fn deinit(self: *@This(), allocator: mem.Allocator) void {
            self.rsns.deinit(allocator);
            self.streams.deinit(allocator);
        }

        /// The stream name is raw bytes; focusing on linux first, and ext4
        /// filenames are bytes, not a particular encoding.
        /// TODO: some way of translating this into the the platforms native
        /// filename format ie utf-8 for OS X, utf-16 for windows
        pub fn create_stream(
            self: *@This(),
            name: []const u8,
            file_io: anytype,
        ) CreateStreamReqErr!void {
            const usr_data = db_ctx.create{
                .stream = .{ .name_idx = try self.rsns.add(name) },
            };
            file_io.send(.{ .usr_data = usr_data });
        }
    };
}

//pub fn FileOp(comptime FD: type) type {
//    return struct {
//        pub const Input = struct {
//            req_id: ReqID,
//            // Represent inputs for syscalls
//            args: union(enum) {
//                create,
//                read: struct { fd: FD, buf: []u8, offset: usize },
//                append: struct { fd: FD, data: []const u8 },
//                delete: FD,
//            },
//        };
//
//        pub const Output = struct {
//            req_id: ReqID,
//            // Represent outputs for syscalls
//            ret_val: union(enum) {
//                create: posix.fd_t,
//                read: usize,
//                append: usize,
//                delete: bool,
//            },
//        };
//    };
//}
//
////// TODO: test if determinstic
////// Looking at the code I am 95% sure..
////const AutoHashMap = std.AutoHashMap;
//
//pub fn Node(
//    comptime FileIO: type,
//    comptime Context: type,
//    comptime onReceive: fn (ctx: *Context, res: Res) void,
//) type {
//    return struct {
//        db: DB(FileIO, Context, onReceive),
//        file_io: FileIO,
//
//        pub fn init(
//            allocator: mem.Allocator,
//            ctx: Context,
//        ) !@This() {
//            const db = try DB(FileIO, Context, onReceive).init(allocator, ctx);
//            const file_io = try FileIO.init(allocator);
//            return .{ .db = db, .file_io = file_io };
//        }
//
//        pub fn deinit(self: *@This()) @This() {
//            self.db.deinit();
//            self.file_io.deinit();
//        }
//
//        pub fn create_stream(self: *@This(), name: []const u8) !void {
//            try self.db.send(.{ .create_stream = name }, &self.file_io);
//        }
//    };
//}
//
//fn DB(
//    comptime FD: type,
//    comptime Context: type,
//    comptime onReceive: fn (ctx: *Context, res: Res) void,
//) type {
//    return struct {
//        reqs: Reqs,
//        streams: StringHashMapUnmanaged(FD),
//        ctx: Context,
//        allocator: mem.Allocator,
//
//        pub fn init(
//            allocator: mem.Allocator,
//            ctx: Context,
//        ) !@This() {
//            return .{
//                .reqs = try Reqs.init(allocator),
//                .streams = .{},
//                .ctx = ctx,
//                .allocator = allocator,
//            };
//        }
//
//        pub fn deinit(self: *@This()) void {
//            // TODO: keys need to be freed.
//            self.streams.deinit(self.allocator);
//        }
//
//        pub fn send(self: *@This(), req: Req, file_io: anytype) !void {
//            const id = try self.reqs.add(req, self.allocator);
//            // given a particular msg, dispatch the appropriate file op
//            switch (req) {
//                .create_stream => {
//                    const file_op = FileOp(FD).Input{
//                        .req_id = id,
//                        .args = .create,
//                    };
//                    file_io.send(id, file_op);
//                },
//            }
//        }
//
//        pub fn receive_io(
//            self: *@This(),
//            file_op: FileOp(FD).Output,
//        ) !void {
//            const req = try self.reqs.remove(file_op.req_id);
//
//            switch (req) {
//                .create_stream => |name| {
//                    self.streams.insert(name, file_op.ret_val);
//                    onReceive(self.ctx, .{.stream_created + name});
//                },
//            }
//        }
//    };
//}

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

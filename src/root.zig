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

pub fn file_io(comptime FD: type) type {
    return struct {
        pub const req = union(enum) {
            create: db_ctx.create,
            read: struct { buf: std.ArrayList(u8), offset: usize },
            append: struct { fd: FD },
        };

        pub const res = union(enum) {
            create: struct { fd: FD, usr_data: db_ctx.create },
        };
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

/// Streams that are waiting to be created
const RequestedStreamNames = struct {
    /// Using an array so we can give each name a small "address"
    /// Limit the size of it 256 bytes so we can use a u8 as the index
    names: *[64][]const u8,
    /// Bitmask where 1 = next_index, 0 = not available
    /// Allows us to remove names from the middle of the names array w/o
    /// re-ordering. If this array is empty, we've exceeded the capacity of
    /// names
    used_slots: u64,

    fn init(allocator: mem.Allocator) !@This() {
        return .{
            .names = try allocator.create([64][]const u8),
            .used_slots = 0,
        };
    }

    fn deinit(self: *@This(), allocator: mem.Allocator) void {
        allocator.free(self.names);
    }

    /// Index if it succeeds, None if it's a duplicate
    fn add(self: *@This(), name: []const u8) CreateStreamReqErr!u8 {
        if (mem.containsAtLeast(*[64][]const u8, self.names, 1, name)) {
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
        assert(idx > 64);
        self.used_slots |= 0 << idx; // Slot is now free
        const removed = self.names[idx];
        self.names[idx] = "";
        return removed;
    }
};

pub const CreateStreamReqErr = error{
    DuplicateStreamNameRequested,
    RequestedStreamNameOverflow,
};

/// User Response
pub const URes = union(enum) {
    stream_created: struct { name: []const u8 },
};

pub fn DB(comptime FD: type) type {
    return struct {
        rsns: RequestedStreamNames,
        /// Does not own the string keys
        streams: StringHashMapUnmanaged(FD),
        allocator: mem.Allocator,

        pub fn init(allocator: mem.Allocator) !@This() {
            return .{
                .rsns = try RequestedStreamNames.init(allocator),
                .streams = .{},
                .allocator = allocator,
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
            os: anytype,
        ) CreateStreamReqErr!void {
            const file_io_req: file_io(FD).req = .{
                .create = .{
                    .stream = .{
                        .name_idx = try self.rsns.add(name),
                    },
                },
            };
            os.send(file_io_req);
        }

        fn res_file_io_to_usr(
            self: *@This(),
            file_io_res: file_io(FD).res,
        ) !URes {
            switch (file_io_res) {
                .create => |op| {
                    switch (op.usr_data) {
                        .stream => {
                            const name_idx = op.usr_data.stream.name_idx;
                            const name = self.rsns.remove(name_idx);
                            const prev_val = try self.streams.getOrPut(
                                self.allocator,
                                name,
                            );
                            assert(!prev_val.found_existing);
                            prev_val.value_ptr.* = op.fd;
                            return URes{ .stream_created = .{ .name = name } };
                        },
                    }
                },
            }
        }

        pub fn receive_io(
            self: *@This(),
            res: file_io(FD).res,
            usr_ctx: anytype,
        ) !void {
            const usr_res = try self.res_file_io_to_usr(res);
            usr_ctx.send(usr_res);
        }
    };
}

const std = @import("std");

const mem = std.mem;
const posix = std.posix;
const testing = std.testing;
const assert = std.debug.assert;

const StringHashMap = std.StringHashMapUnmanaged;

// Only worrying about 64 bit systems for now
comptime {
    assert(@sizeOf(usize) == 8);
}

const FileOps = enum { create, read, append, delete };

// Messages sent to an async file system with a req/res interface
pub fn fs_msg(comptime FD: type) type {
    return struct {
        pub const req = union(FileOps) {
            create: ctx.create,
            read: struct { buf: std.ArrayList(u8), offset: usize },
            append: struct { fd: FD, payload: std.ArrayList(u8) },
            delete: struct { fd: FD },
        };

        pub const res = union(FileOps) {
            create: struct { fd: FD, ctx: ctx.create },
            read: struct {},
            append: struct {},
            delete: struct {},
        };
    };
}

const topic = struct {
    const _backing_int = u6;
    const id = enum(_backing_int) { _ };
    const max_n = std.math.maxInt(_backing_int) + 1;
};

/// Higher level context given to lower level file system messages
/// This is so we can associate CRAD operations with User operations
const ctx = struct {
    const create = union(enum) {
        topic: struct { id: topic.id, _padding: u32 = 0 },
    };

    // These are intended to be used in the user_data field of io_uring
    // (__u64) or the udata field of kqueue (void*). So we make sure they
    // can fit in 8 bytes.
    comptime {
        assert(@sizeOf(create) == 8);
    }
};

/// Topics that are waiting to be created
const RequestedTopicNames = struct {
    /// Using an array so we can give each name a small "address"
    /// Limit the size of it 256 bytes so we can use a u8 as the index
    names: *[topic.max_n][]const u8,
    /// Bitmask where 1 = next_index, 0 = not available
    /// Allows us to remove names from the middle of the names array w/o
    /// re-ordering. If this array is empty, we've exceeded the capacity of
    /// names
    used_slots: [topic.max_n]u1,

    fn init(allocator: mem.Allocator) !@This() {
        return .{
            .names = try allocator.create([topic.max_n][]const u8),
            .used_slots = [_]u1{0} ** topic.max_n,
        };
    }

    fn deinit(self: *@This(), allocator: mem.Allocator) void {
        allocator.free(self.names);
    }

    /// Index if it succeeds, None if it's a duplicate
    fn add(
        self: *@This(),
        name: []const u8,
    ) CreateTopicErr!topic.id {
        for (self.names) |existing_name| {
            if (mem.eql(u8, existing_name, name))
                return error.TopicNameAlreadyExists;
        }

        // Find first free slot
        for (self.used_slots, 0..) |slot, idx| {
            if (slot == 0) { // Free slot found
                self.used_slots[idx] = 1;
                self.names[idx] = name;
                return @enumFromInt(idx);
            }
        }

        return error.MaxTopics; // No free slots
    }

    fn remove(self: *@This(), id: topic.id) []const u8 {
        const idx = @intFromEnum(id);
        self.used_slots[idx] = 0;
        const removed = self.names[idx];
        self.names[idx] = "";
        return removed;
    }
};

pub const CreateTopicErr = error{
    TopicNameAlreadyExists,
    MaxTopics,
};

/// User Response
pub const URes = union(enum) {
    topic_created: struct { name: []const u8 },
};

pub fn DB(comptime FD: type) type {
    return struct {
        rt_names: RequestedTopicNames,
        /// Does not own the string keys
        topics: StringHashMap(FD),
        allocator: mem.Allocator,

        pub fn init(allocator: mem.Allocator) !@This() {
            return .{
                .rt_names = try RequestedTopicNames.init(allocator),
                .topics = .{},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *@This(), allocator: mem.Allocator) void {
            self.rt_names.deinit(allocator);
            self.topics.deinit(allocator);
        }

        /// The topic name is raw bytes; focusing on linux first, and ext4
        /// filenames are bytes, not a particular encoding.
        /// TODO: some way of translating this into the the platforms native
        /// filename format ie utf-8 for OS X, utf-16 for windows
        pub fn create_stream(
            self: *@This(),
            name: []const u8,
            fs: anytype,
        ) !void {
            // Cannot request the name of a stream we already have
            if (self.topics.contains(name)) {
                return error.TopicNameAlreadyExists;
            }

            const fs_req: fs_msg(FD).req = .{
                .create = .{
                    .topic = .{ .id = try self.rt_names.add(name) },
                },
            };
            try fs.send(fs_req);
        }

        fn res_file_io_to_usr(
            self: *@This(),
            file_io_res: fs_msg(FD).res,
        ) !URes {
            switch (file_io_res) {
                .create => |op| {
                    switch (op.ctx) {
                        .topic => {
                            const name_idx = op.ctx.topic.id;
                            const name = self.rt_names.remove(name_idx);
                            const prev_val = try self.topics.getOrPut(
                                self.allocator,
                                name,
                            );
                            assert(!prev_val.found_existing);
                            prev_val.value_ptr.* = op.fd;
                            return URes{ .topic_created = .{ .name = name } };
                        },
                    }
                },
                else => @panic("TODO"),
            }
        }

        pub fn receive_io(
            self: *@This(),
            res: fs_msg(FD).res,
            usr_ctx: anytype,
        ) !void {
            const usr_res = try self.res_file_io_to_usr(res);
            usr_ctx.send(usr_res);
        }
    };
}

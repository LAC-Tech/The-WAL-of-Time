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
pub fn FsMsg(comptime FD: type) type {
    return struct {
        pub const req = union(FileOps) {
            create: Ctx.create,
            read: struct { buf: std.ArrayList(u8), offset: usize },
            append: struct { fd: FD, payload: std.ArrayList(u8) },
            delete: struct { fd: FD },
        };

        pub const res = union(FileOps) {
            create: struct { fd: FD, ctx: Ctx.create },
            read: struct {},
            append: struct {},
            delete: struct {},
        };
    };
}

const topic = struct {
    const ID = enum(u6) { _ };

    const max_n = std.math.powi(u64, 2, @bitSizeOf(ID)) catch |err| {
        @compileError(@errorName(err));
    };

    comptime {
        assert(max_n == 64);
    }
};

/// Higher level context given to lower level file system messages
/// This is so we can associate CRAD operations with User operations
const Ctx = struct {
    const create = union(enum) {
        topic: struct { id: topic.ID, _padding: u32 = 0 },
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
    ) CreateTopicErr!topic.ID {
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

    fn remove(self: *@This(), id: topic.ID) []const u8 {
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

/// Top Level Response, for the application
pub const Res = union(enum) {
    topic_created: struct { name: []const u8 },
};

/// This structs job is to receive "completed" async fs events, and:
/// 1 - update reflect changs to the node in memory and
/// 2 - return a meaningful response for user code
/// It's completey decoupled from any async runtime
pub fn Node(comptime FD: type) type {
    return struct {
        rtns: RequestedTopicNames,
        /// Does not own the string keys
        topic_names_to_fds: StringHashMap(FD),
        allocator: mem.Allocator,

        pub fn init(allocator: mem.Allocator) !@This() {
            return .{
                .rtns = try RequestedTopicNames.init(allocator),
                .topic_names_to_fds = .{},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *@This(), allocator: mem.Allocator) void {
            self.rtns.deinit(allocator);
            self.topic_names_to_fds.deinit(allocator);
        }

        /// The topic name is raw bytes; focusing on linux first, and ext4
        /// filenames are bytes, not a particular encoding.
        /// TODO: some way of translating this into the the platforms native
        /// filename format ie utf-8 for OS X, utf-16 for windows
        pub fn create_topic(
            self: *@This(),
            name: []const u8,
        ) !FsMsg(FD).req {
            if (self.topic_names_to_fds.contains(name)) {
                return error.TopicNameAlreadyExists;
            }

            return .{
                .create = .{
                    .topic = .{ .id = try self.rtns.add(name) },
                },
            };
        }

        /// This turns internal DB and async io stuff into something relevant
        /// to the end user.
        /// It is one function, rather than one for each case, because I
        /// envison the result of this having a single callback associated with
        /// it in user code.
        /// TODO: review these assumptions
        pub fn receive_fs_res(
            self: *@This(),
            fs_res: FsMsg(FD).res,
        ) !Res {
            switch (fs_res) {
                .create => |create| {
                    switch (create.ctx) {
                        .topic => {
                            const topic_id = create.ctx.topic.id;
                            const name = self.rtns.remove(topic_id);
                            const existing_name =
                                try self.topic_names_to_fds.getOrPut(
                                    self.allocator,
                                    name,
                                );
                            assert(!existing_name.found_existing);
                            existing_name.value_ptr.* = create.fd;
                            return Res{
                                .topic_created = .{ .name = name },
                            };
                        },
                    }
                },
                else => @panic("TODO"),
            }
        }
    };
}

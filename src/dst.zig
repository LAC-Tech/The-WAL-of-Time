//! Deterministic Simulation Tester

const std = @import("std");
const heap = std.heap;
const math = std.math;
const mem = std.mem;
const posix = std.posix;
const rand = std.rand;
const testing = std.testing;

const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const PriorityQueue = std.PriorityQueue;

/// Simulating an OS with async IO, and append-only files
const OperatingSystem = struct {
    fs: FileSystem,
    events: Events,
    rng: *rand.DefaultPrng,
    allocator: mem.Allocator,

    const FileOp = union(enum) {
        create: *const fn (fd: posix.fd_t) void,
        read: struct {
            fd: posix.fd_t,
            buf: *ArrayList(u8),
            len: usize,
            offset: usize,
            callback: *const fn (bytes_read: usize) void,
        },
        append: struct {
            fd: posix.fd_t,
            data: []const u8,
            callback: *const fn (
                bytes_appended: posix.WriteError!usize,
            ) void,
        },
        delete: struct {
            fd: posix.fd_t,
            callback: *const fn (success: bool) void,
        },
    };

    const AppendOnlyFile = struct {
        data: ArrayList(u8),
        fn init(allocator: mem.Allocator) @This() {
            return .{ .data = ArrayList(u8).init(allocator) };
        }

        fn deinit(self: *@This()) void {
            self.data.deinit();
        }

        fn read(
            self: @This(),
            buf: *ArrayList(u8),
            len: usize,
            offset: usize,
        ) !usize {
            try buf.appendSlice(self.data.items[offset .. offset + len]);
            // TODO: randomly fail to read all data expected?
            return len;
        }

        fn append(
            self: *@This(),
            data: []const u8,
        ) posix.WriteError!usize {
            self.data.appendSlice(data) catch return error.NoSpaceLeft;
            // TODO: randomly fail to append all data?
            return data.len;
        }
    };

    // TODO: this approach means we allocate a lot.
    // Ideally, file system should be a flat array of bytes
    const FileSystem = AutoHashMap(posix.fd_t, AppendOnlyFile);
    const Event = struct { priority: u64, file_op: FileOp };
    const Events = PriorityQueue(Event, void, struct {
        fn compare(_: void, a: Event, b: Event) math.Order {
            return math.order(a.priority, b.priority);
        }
    }.compare);

    fn init(allocator: mem.Allocator, rng: *rand.DefaultPrng) @This() {
        return .{
            .fs = FileSystem.init(allocator),
            .events = Events.init(allocator, {}),
            .rng = rng,
            .allocator = allocator,
        };
    }

    fn deinit(self: *@This()) void {
        self.fs.deinit();
        self.events.deinit();
    }

    /// Nothing ever happens... until we advance the state of the OS.
    fn tick(self: *@This()) !bool {
        const event = self.events.removeOrNull() orelse {
            std.debug.print("No events :'(\n", .{});
            return false;
        };

        switch (event.file_op) {
            .create => |callback| {
                const fd = self.rng.random().int(posix.fd_t);
                const file = AppendOnlyFile.init(self.allocator);
                try self.fs.putNoClobber(fd, file);
                callback(@intCast(fd));
            },
            .read => |e| {
                std.debug.print("{}", .{e});
            },
            .append => |e| {
                const res = if (self.fs.getPtr(e.fd)) |aof|
                    aof.append(e.data)
                else
                    posix.WriteError.InvalidArgument;
                e.callback(res);
            },
            .delete => |e| {
                e.callback(self.fs.remove(e.fd));
            },
        }

        return true;
    }

    fn create_file(
        self: *@This(),
        callback: *const fn (fd: posix.fd_t) void,
    ) !void {
        const event: Event = .{
            .priority = self.rng.random().int(u64),
            .file_op = .{ .create = callback },
        };
        try self.events.add(event);
    }
};

fn on_file_create(fd: posix.fd_t) void {
    std.debug.print("fd created = {}\n", .{fd});
}

fn get_seed() !u64 {
    var args = std.process.args();
    _ = args.skip();

    if (args.next()) |arg| {
        return std.fmt.parseInt(u64, arg, 10) catch |err| {
            std.debug.print("Failed to parse seed: {}\n", .{err});
            return err;
        };
    }

    return std.crypto.random.int(u64);
}

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};

    const seed = try get_seed();
    var rng = rand.DefaultPrng.init(seed);

    std.debug.print("Deterministic Simulation Tester\n", .{});
    std.debug.print("seed = {}\n", .{seed});

    var os = OperatingSystem.init(gpa.allocator(), &rng);
    defer os.deinit();
    try os.create_file(&on_file_create);
    try os.create_file(&on_file_create);
    try os.create_file(&on_file_create);
    try os.create_file(&on_file_create);
    try os.create_file(&on_file_create);
    try os.create_file(&on_file_create);
    try os.create_file(&on_file_create);
    while (try os.tick()) {}
}

test "OS sanity check" {
    var rng = rand.DefaultPrng.init(0);
    var os = OperatingSystem.init(testing.allocator, &rng);
    defer os.deinit();
    try os.create_file(&on_file_create);
    _ = try os.tick();
}

test "Append-only File sanity check" {
    var aof = OperatingSystem.AppendOnlyFile.init(testing.allocator);
    defer aof.deinit();
    const text = "They're making the last film; they say it's the best.";

    const bytes_appended = try aof.append(text);
    try testing.expectEqual(bytes_appended, text.len);

    var buf = ArrayList(u8).init(testing.allocator);
    defer buf.deinit();
    const bytes_written = try aof.read(&buf, text.len, 0);
    try testing.expectEqual(bytes_written, text.len);
    try testing.expectEqualDeep(buf.items, text);
}

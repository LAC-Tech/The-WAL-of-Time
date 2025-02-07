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

const c = @cImport({
    @cInclude("locale.h");
    @cInclude("notcurses/notcurses.h");
});

const root = @import("./root.zig");
const Stream = root.Stream;

/// Simulating an OS with async IO, and append-only files
const OperatingSystem = struct {
    fs: FileSystem,
    events: Events,
    allocator: mem.Allocator,

    const FileOp = union(enum) {
        create: *const fn (
            fd: posix.OpenError!posix.fd_t,
            ctx: *Context,
        ) void,
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
    const FileSystem = struct {
        files: ArrayList(AppendOnlyFile),
        allocator: mem.Allocator,

        fn init(allocator: mem.Allocator) @This() {
            return .{
                .files = ArrayList(AppendOnlyFile).init(allocator),
                .allocator = allocator,
            };
        }

        fn deinit(self: *@This()) void {
            self.files.deinit();
        }

        fn create(self: *@This()) posix.OpenError!posix.fd_t {
            const fd = self.files.items.len;
            const file = AppendOnlyFile.init(self.allocator);
            self.files.append(file) catch return posix.OpenError.NoSpaceLeft;
            return @intCast(fd);
        }

        fn append(
            self: *@This(),
            fd: posix.fd_t,
            data: []const u8,
        ) posix.WriteError!usize {
            const index: usize = @intCast(fd);
            if (self.files.items.len > index) {
                var aof = self.files.items[index];
                return aof.append(data);
            } else {
                return posix.WriteError.InvalidArgument;
            }
        }
    };

    const Event = struct { priority: u64, file_op: FileOp };
    const Events = PriorityQueue(Event, void, struct {
        fn compare(_: void, a: Event, b: Event) math.Order {
            return math.order(a.priority, b.priority);
        }
    }.compare);

    fn init(allocator: mem.Allocator) @This() {
        return .{
            .fs = FileSystem.init(allocator),
            .events = Events.init(allocator, {}),
            .allocator = allocator,
        };
    }

    fn deinit(self: *@This()) void {
        self.fs.deinit();
        self.events.deinit();
    }

    /// Nothing ever happens... until we advance the state of the OS.
    fn tick(self: *@This(), ctx: *Context) !void {
        const event = self.events.removeOrNull() orelse return;

        switch (event.file_op) {
            .create => |callback| {
                const fd = self.fs.create();
                callback(fd, ctx);
            },
            .read => |e| {
                std.debug.print("{}", .{e});
            },
            .append => |e| {
                e.callback(self.fs.append(e.fd, e.data));
            },
            .delete => |e| {
                std.debug.print("TODO impl delete {}\n", .{e});
            },
        }
    }

    fn create_file(
        self: *@This(),
        callback: *const fn (
            fd: posix.OpenError!posix.fd_t,
            ctx: *Context,
        ) void,
        ctx: *Context,
    ) !void {
        const event: Event = .{
            .priority = ctx.rng.random().int(u64),
            .file_op = .{ .create = callback },
        };
        try self.events.add(event);
    }

    fn delete_file(
        self: *@This(),
        fd: posix.fd_t,
        callback: *const fn (fd: posix.fd_t) void,
    ) !void {
        const event: Event = .{
            .priority = self.rng.random().int(u64),
            .file_op = .{ .fd = fd, .callback = callback },
        };
        try self.events.add(event);
    }
};

fn on_file_create(fd: posix.OpenError!posix.fd_t, context: *Context) void {
    if (fd) |_| {
        const str: [*c]const u8 = "fd created";
        _ = c.ncplane_printf(context.ncplane, str);
    } else |_| {
        const str: [*c]const u8 = "fd create err";
        _ = c.ncplane_printf(context.ncplane, str);
    }

    _ = c.notcurses_render(context.nc);
}

fn on_file_delete(fd: posix.fd_t) void {
    std.debug.print("fd {} ここで死ね", .{fd});
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

const Context = struct {
    rng: *rand.DefaultPrng,
    ncplane: *c.struct_ncplane,
    nc: *c.struct_notcurses,
};

// Configuration parameters for the DST
// In one place for ease of tweaking
const Config = struct {
    const max_sim_time_in_ms: u64 = 1000 * 60 * 60 * 24; // 24 hours

    // TODO: these chances are temporary; will later be driven by actual db
    const create_file_chance = 0.1;
    const delete_file_chance = 0.05;
};

pub fn main() !void {
    const locale = c.setlocale(c.LC_ALL, "");
    if (locale == null) {
        std.debug.print("Failed to set locale", .{});
        return;
    }
    const ncopt = mem.zeroes(c.notcurses_options);

    const nc = c.notcurses_init(&ncopt, c.stdout) orelse {
        std.debug.print("Failed to init ncurses", .{});
        return;
    };

    const ncplane = c.notcurses_stdplane(nc) orelse {
        std.debug.print("Failed to create std plane", .{});
        return;
    };

    const seed = try get_seed();
    var rng = rand.DefaultPrng.init(seed);

    var ctx = Context{ .rng = &rng, .ncplane = ncplane, .nc = nc };

    var gpa = heap.GeneralPurposeAllocator(.{}){};
    var os = OperatingSystem.init(gpa.allocator());
    defer os.deinit();

    const phys_start_time = std.time.nanoTimestamp();

    var time: u64 = 0;
    while (time <= 1000 * 60 * 60 * 24) : (time += 10) {
        if (Config.create_file_chance > rng.random().float(f64)) {
            try os.create_file(&on_file_create, &ctx);
        }

        //if (Config.delete_file_chance > rng.random().float(f64)) {
        //    try os.delete_file(&on_file_delete);
        //}

        try os.tick(&ctx);
    }

    const phys_end_time = std.time.nanoTimestamp();
    const phys_time_elapsed: f128 = @floatFromInt(phys_end_time - phys_start_time);

    _ = c.ncplane_printf(ctx.ncplane, "time elapsed = %f", phys_time_elapsed);
    _ = c.notcurses_render(ctx.nc);
}

test "OS sanity check" {
    const seed = 0;
    var rng = rand.DefaultPrng.init(seed);
    var os = OperatingSystem.init(testing.allocator, &rng);
    defer os.deinit();
    try os.create_file(&on_file_create);
    _ = try os.tick();

    var stream = Stream(OperatingSystem).init(
        &os,
        -1,
        testing.allocator,
        seed,
    );
    defer stream.deinit();
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

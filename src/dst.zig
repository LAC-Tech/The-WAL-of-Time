//! Deterministic Simulation Tester

const std = @import("std");
const heap = std.heap;
const math = std.math;
const mem = std.mem;
const posix = std.posix;
const rand = std.rand;
const testing = std.testing;

const ArrayListUnmanged = std.ArrayListUnmanaged;
const AutoHashMap = std.AutoHashMap;
const PriorityQueue = std.PriorityQueue;

const lib = @import("./root.zig");

const c = @cImport({
    @cInclude("tui.h");
});

const OS = struct {
    fs: ArrayListUnmanged(ArrayListUnmanged(u8)),
    events: Events,
    receiver: *const fn (db: *lib.DB(OS, Context), msg: lib.os.Output) void,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        receiver: *const fn (db: *lib.DB(OS, Context), msg: lib.os.Output) void,
    ) !@This() {
        const events = Events.init(allocator, {});
        //try events.ensureTotalCapacity(256);
        return .{
            .fs = try ArrayListUnmanged(ArrayListUnmanged(u8)).initCapacity(
                allocator,
                1_000_000,
            ),
            .events = events,
            .receiver = receiver,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.fs.deinit(self.allocator);
        self.events.deinit();
    }

    const Event = struct {
        priority: u64,
        os_input: lib.os.Input,
    };
    const Events = PriorityQueue(Event, void, struct {
        fn compare(_: void, a: Event, b: Event) math.Order {
            return math.order(a.priority, b.priority);
        }
    }.compare);

    /// Nothing ever happens... until we advance the state of the OS.
    fn tick(self: *@This(), db: *lib.DB(OS, Context)) !void {
        const event = self.events.removeOrNull() orelse return;

        switch (event.os_input.file_op) {
            .create => {
                const fd = self.fs.items.len;
                const file = ArrayListUnmanged(u8){};
                try self.fs.append(self.allocator, file);
                self.receiver(db, .{
                    .task_id = event.os_input.task_id,
                    .file_op = .{ .create = @intCast(fd) },
                });
            },
            .read => |_| {
                @panic("TODO: Read");
            },
            .append => |_| {
                @panic("TODO: Append");
            },
            .delete => |_| {
                @panic("TODO: Delete");
            },
        }
    }

    pub fn send(
        self: *@This(),
        ctx: *Context,
        msg: lib.os.Input,
    ) !void {
        const event = .{
            .priority = ctx.random.int(u64),
            .os_input = msg,
        };
        try self.events.add(event);
    }
};

fn on_create_stream(ctx: *Context, fd: posix.fd_t) void {
    _ = fd;
    ctx.stats.os_files_created += 1;
}

const Context = struct {
    random: std.Random,
    stats: c.stats,
    fn update_stats(self: *@This(), msg: lib.OsOutput) void {
        switch (msg) {
            .create => {
                self.stats.os_files_created += 1;
            },
            else => @panic("TODO: collect more stats"),
        }
    }
};

const Simulator = struct {
    db: lib.DB(OS, Context),
    ctx: Context,

    fn init(allocator: mem.Allocator, random: std.Random) !@This() {
        return .{
            .db = try lib.DB(OS, Context).init(allocator),
            .ctx = .{
                .random = random,
                .stats = .{ .os_files_created = 0 },
            },
        };
    }

    fn deinit(self: *@This()) void {
        self.db.deinit();
    }

    fn tick(self: *@This()) !void {
        if (Config.create_file_chance > self.ctx.random.float(f64)) {
            try self.db.create_stream(&self.ctx, &on_create_stream);
        }

        try self.db.os.tick(&self.db);
    }
};

// Configuration parameters for the DST
// In one place for ease of tweaking
const Config = struct {
    const max_sim_time_in_ms: u64 = 1000 * 60 * 60 * 24; // 24 hours

    // TODO: these chances are temporary; will later be driven by actual db
    const create_file_chance = 0.1;
    const delete_file_chance = 0.05;
};

fn live_simulation(sim: *Simulator) !void {
    var tui = mem.zeroes(c.tui);
    c.tui_init(&tui);

    var time: u64 = 0;
    while (time <= Config.max_sim_time_in_ms) : (time += 10) {
        try sim.tick();
        if (time % (1000 * 60) == 0) {
            c.tui_sim_render(&tui, &sim.ctx.stats, time);
        }
    }

    c.tui_deinit(&tui);
}

fn bg_simulation(sim: *Simulator) !void {
    const phys_start_time = std.time.microTimestamp();

    var time: u64 = 0;
    while (time <= Config.max_sim_time_in_ms) : (time += 10) {
        try sim.tick();
    }

    const phys_end_time = std.time.microTimestamp();
    const phys_time_elapsed: f128 =
        @floatFromInt(phys_end_time - phys_start_time);

    std.debug.print(
        "Stats: OS files created: {}\n",
        .{sim.ctx.stats.os_files_created},
    );
    std.debug.print("Time: {} μs\n", .{phys_time_elapsed});
}

pub fn main() !void {
    var args = std.process.args();
    _ = args.skip();

    const mode = args.next() orelse @panic("First arg must be 'live' or 'bg'");
    const seed = if (args.next()) |arg|
        try std.fmt.parseInt(u64, arg, 10)
    else
        std.crypto.random.int(u64);

    std.debug.print("Seed = {}\n", .{seed});

    var rng = rand.DefaultPrng.init(seed);
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    var sim = try Simulator.init(gpa.allocator(), rng.random());

    if (std.mem.eql(u8, mode, "bg")) {
        try bg_simulation(&sim);
    } else if (std.mem.eql(u8, mode, "live")) {
        try live_simulation(&sim);
    } else {
        unreachable;
    }

    sim.deinit();
    gpa.deinit();
}

test "sim lifetime" {
    var rng = rand.DefaultPrng.init(0);
    var sim = try Simulator.init(testing.allocator, rng.random());
    _ = try sim.tick();
    defer sim.deinit();
}

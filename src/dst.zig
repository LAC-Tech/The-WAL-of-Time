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

const root = @import("./root.zig");

const c = @cImport({
    @cInclude("tui.h");
});

const OS = struct {
    fs: ArrayListUnmanged(ArrayListUnmanged(u8)),
    events: Events,
    receiver: *const fn (ctx: *Context, msg: root.OsOutput) void,
    allocator: std.mem.Allocator,

    fn init(
        allocator: std.mem.Allocator,
        receiver: *const fn (ctx: *Context, msg: root.OsOutput) void,
    ) !@This() {
        const events = Events.init(allocator, {});
        //try events.ensureTotalCapacity(256);
        return .{
            .fs = try ArrayListUnmanged(ArrayListUnmanged(u8)).initCapacity(
                allocator,
                90_000,
            ),
            .events = events,
            .receiver = receiver,
            .allocator = allocator,
        };
    }

    fn deinit(self: *@This()) void {
        self.fs.deinit(self.allocator);
        self.events.deinit();
    }

    const Event = struct { priority: u64, file_op: root.OsInput };
    const Events = PriorityQueue(Event, void, struct {
        fn compare(_: void, a: Event, b: Event) math.Order {
            return math.order(a.priority, b.priority);
        }
    }.compare);

    /// Nothing ever happens... until we advance the state of the OS.
    fn tick(self: *@This(), ctx: *Context) !void {
        const event = self.events.removeOrNull() orelse return;

        switch (event.file_op) {
            .create => {
                const fd = self.fs.items.len;
                const file = ArrayListUnmanged(u8){};
                try self.fs.append(self.allocator, file);
                self.receiver(ctx, .{ .create = @intCast(fd) });
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

    fn send(self: *@This(), ctx: *Context, msg: root.OsInput) !void {
        const event = .{
            .priority = ctx.random.int(u64),
            .file_op = msg,
        };
        try self.events.add(event);
    }
};

fn on_output_msg(ctx: *Context, msg: root.OsOutput) void {
    ctx.update_stats(msg);
}

const Context = struct {
    random: std.Random,
    stats: c.stats,
    fn update_stats(self: *@This(), msg: root.OsOutput) void {
        switch (msg) {
            .create => {
                self.stats.os_files_created += 1;
            },
            else => @panic("TODO: collect more stats"),
        }
    }
};

const Simulator = struct {
    os: OS,
    ctx: Context,

    fn init(allocator: mem.Allocator, random: std.Random) !@This() {
        return .{
            .os = try OS.init(allocator, on_output_msg),
            .ctx = .{
                .random = random,
                .stats = .{ .os_files_created = 0 },
            },
        };
    }

    fn deinit(self: *@This()) void {
        self.os.deinit();
    }

    fn tick(self: *@This()) !void {
        if (Config.create_file_chance > self.ctx.random.float(f64)) {
            try self.os.send(&self.ctx, .create);
        }

        try self.os.tick(&self.ctx);
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
        if (time % 1000 == 0) {
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

    const fp = blk: {
        if (args.next()) |m| {
            if (mem.eql(u8, m, "bg")) break :blk &bg_simulation;
            if (mem.eql(u8, m, "live")) break :blk &live_simulation;
        }
        @panic("First arg must be 'live' or 'bg'");
    };

    const seed = if (args.next()) |arg|
        try std.fmt.parseInt(u64, arg, 10)
    else
        std.crypto.random.int(u64);

    std.debug.print("Seed = {}\n", .{seed});

    var rng = rand.DefaultPrng.init(seed);
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    var sim = try Simulator.init(gpa.allocator(), rng.random());

    try fp(&sim);
}

test "sim lifetime" {
    var sim = try Simulator.init(testing.allocator, 0);
    _ = try sim.tick();
    defer sim.deinit();
}

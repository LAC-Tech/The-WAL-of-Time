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

const FileIO = struct {
    fs: ArrayListUnmanged(ArrayListUnmanged(u8)),
    events: Events,
    io_receiver: *const fn (db: lib.FileOp(FD)) void,
    allocator: std.mem.Allocator,

    pub const FD = usize;
    pub fn init(
        allocator: std.mem.Allocator,
        io_receiver: fn (output: lib.FileOp(FD).Output) void,
    ) !@This() {
        const events = Events.init(allocator, {});
        //try events.ensureTotalCapacity(256);
        return .{
            .fs = try ArrayListUnmanged(ArrayListUnmanged(u8)).initCapacity(
                allocator,
                1_000_000,
            ),
            .events = events,
            .io_receiver = io_receiver,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.fs.deinit(self.allocator);
        self.events.deinit();
    }

    const Event = struct { priority: u64, os_input: lib.FileOp(FD).Input };
    const Events = PriorityQueue(Event, void, struct {
        fn compare(_: void, a: Event, b: Event) math.Order {
            return math.order(a.priority, b.priority);
        }
    }.compare);

    /// Nothing ever happens... until we advance the state of the OS.
    fn tick(self: *@This(), node: *lib.DB(FileIO)) !void {
        const event = self.events.removeOrNull() orelse return;

        switch (event.os_input.file_op) {
            .create => {
                const fd = self.fs.items.len;
                const file = ArrayListUnmanged(u8){};
                try self.fs.append(self.allocator, file);
                self.receiver(node, .{
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

const Context = struct {
    random: std.Random,
    stats: c.stats,
    pub fn receive(self: *@This(), res: lib.Res) void {
        switch (res) {
            .create => {
                self.stats.os_files_created += 1;
            },
            else => @panic("TODO: collect more stats"),
        }
    }
};

const Simulator = struct {
    node: lib.Node(FileIO, Context),
    ctx: Context,

    fn init(allocator: mem.Allocator, random: std.Random) !@This() {
        const ctx = .{
            .random = random,
            .stats = .{ .os_files_created = 0 },
        };
        return .{
            .ctx = ctx,
            .node = try lib.Node(FileIO, Context).init(allocator, ctx.receive),
        };
    }

    fn deinit(self: *@This()) void {
        self.node.deinit();
    }

    fn tick(self: *@This()) !void {
        if (Config.create_file_chance > self.ctx.random.float(f64)) {
            try self.node.create_stream("lmao");
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
    defer c.tui_deinit(&tui);

    var time: u64 = 0;
    while (time <= Config.max_sim_time_in_ms) : (time += 10) {
        try sim.tick();
        if (time % (1000 * 60) == 0) {
            c.tui_sim_render(&tui, &sim.ctx.stats, time);
        }
    }
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
    if (gpa.deinit() == .leak) {
        std.debug.print("memory leak!!!!", .{});
    }
}

test "sim lifetime" {
    var rng = rand.DefaultPrng.init(0);
    var sim = try Simulator.init(testing.allocator, rng.random());
    for (0..1000) |_| {
        try sim.tick();
    }
    defer sim.deinit();
}

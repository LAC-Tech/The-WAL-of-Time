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
    @cInclude("tui.c");
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
            .priority = ctx.rng.random().int(u64),
            .file_op = msg,
        };
        try self.events.add(event);
    }
};

fn on_output_msg(ctx: *Context, msg: root.OsOutput) void {
    ctx.update_stats(msg);
}

const Context = struct {
    rng: rand.DefaultPrng,
    stats: struct {
        os_files_created: u64 = 0,
    },

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

    fn init(allocator: mem.Allocator, seed: u64) !@This() {
        return .{
            .os = try OS.init(allocator, on_output_msg),
            .ctx = .{
                .rng = rand.DefaultPrng.init(seed),
                .stats = .{},
            },
        };
    }

    fn deinit(self: *@This()) void {
        self.os.deinit();
    }

    fn tick(self: *@This()) !void {
        if (Config.create_file_chance > self.ctx.rng.random().float(f64)) {
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
    std.debug.print("Deterministic Simulation Tester\n", .{});
    const seed = try get_seed();

    var gpa = heap.GeneralPurposeAllocator(.{}){};

    const ncopt = mem.zeroes(c.notcurses_options);
    const nc = c.notcurses_core_init(&ncopt, c.stdout);
    const stdplane = c.notcurses_stdplane(nc);
    //const str: [*:0]const u8 = "HELLO WORLD";
    _ = c.ncplane_putc(stdplane, 'x');
    _ = c.notcurses_render(nc);
    _ = c.notcurses_get(nc, null, null);

    var sim = try Simulator.init(gpa.allocator(), seed);

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

test "sim lifetime" {
    var sim = try Simulator.init(testing.allocator, 0);
    _ = try sim.tick();
    defer sim.deinit();
}

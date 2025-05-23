//! Deterministic Simulation Tester

const std = @import("std");
const heap = std.heap;
const math = std.math;
const mem = std.mem;
const posix = std.posix;
const rand = std.Random;
const testing = std.testing;

const ArrayList = std.ArrayListUnmanaged;
const PriorityQueue = std.PriorityQueue;

const lib = @import("./lib.zig");

const c = @cImport({
    @cInclude("tui.h");
});

// Configuration parameters for the DST
// In one place for ease of tweaking
const config = struct {
    const max_time_in_ms: u64 = 1000 * 60 * 60 * 24; // 24 hours,
    const create_stream_chance: f64 = 0.001;
    const advance_os_chance: f64 = 0.1;
    const max_stream_name_len: usize = 64;
    const max_bytes_stream_names_src: usize = 0xFFFF;
};

const os = struct {
    const FD = usize;
    const fs_msg = lib.FsMsg(FD);
    const fs_req = fs_msg.req;
    const fs_res = fs_msg.res;
    const Event = struct { priority: u64, req: fs_req };

    fn event_compare(_: void, a: Event, b: Event) math.Order {
        return math.order(a.priority, b.priority);
    }
    const EventQueue = PriorityQueue(Event, void, event_compare);

    const OS = struct {
        events: EventQueue,
        files: ArrayList(ArrayList(u8)),
        rng: *std.Random,
        stats: c.os_stats,

        fn init(allocator: mem.Allocator, rng: *std.Random) @This() {
            return .{
                .events = EventQueue.init(allocator, {}),
                .files = .{},
                .rng = rng,
                .stats = mem.zeroes(c.os_stats),
            };
        }

        fn deinit(self: *@This(), allocator: mem.Allocator) void {
            self.events.deinit();
            for (self.files.items) |*file| {
                file.deinit(allocator);
            }
            self.files.deinit(allocator);
        }

        pub fn send(self: *@This(), req: fs_req) !void {
            const e: Event = .{ .priority = self.rng.int(u64), .req = req };
            try self.events.add(e);
        }

        fn handle_req(
            self: *@This(),
            allocator: mem.Allocator,
            req: fs_req,
        ) !fs_res {
            switch (req) {
                .create => |ctx| {
                    try self.files.append(allocator, .{});
                    const fd = self.files.items.len;
                    self.stats.files_created += 1;
                    return .{ .create = .{ .fd = fd, .ctx = ctx } };
                },
                else => @panic("TODO: handle more events"),
            }
        }

        // Advances the state of the OS.
        // Should not happen every sim tick, I don't think
        pub fn tick(
            self: *@This(),
            allocator: mem.Allocator,
            node: *lib.Node(FD),
            usr_ctx: *usr.Ctx,
        ) !void {
            const event = self.events.removeOrNull() orelse return;
            const res = try self.handle_req(allocator, event.req);
            usr_ctx.send(try node.res_fs_to_usr(res));
        }
    };
};

const usr = struct {
    const Ctx = struct {
        stats: c.usr_stats,

        fn init() @This() {
            return .{ .stats = mem.zeroes(c.usr_stats) };
        }

        fn on_stream_create_req_err(
            self: *@This(),
            err: lib.CreateTopicErr,
        ) void {
            switch (err) {
                error.TopicNameAlreadyExists => {
                    self.stats.topic_name_duplicates += 1;
                },
                error.MaxTopics => {
                    self.stats.topic_name_reservation_limit_exceeded += 1;
                },
            }
        }

        pub fn send(self: *@This(), res: lib.Usr.Res) void {
            switch (res) {
                .topic_create => {
                    self.stats.topics_created += 1;
                },
            }
        }
    };
};

const RandStreamNameGenerator = struct {
    str: []const u8,
    idx: usize,

    pub fn init(allocator: mem.Allocator, rng: *std.Random) !@This() {
        const bytes: []u8 = try allocator.alloc(
            u8,
            config.max_bytes_stream_names_src,
        );
        rng.bytes(bytes);
        return RandStreamNameGenerator{ .str = bytes, .idx = 0 };
    }

    pub fn deinit(self: *@This(), allocator: mem.Allocator) void {
        allocator.free(self.str);
    }

    pub fn get(self: *@This(), rng: *std.Random) ?[]const u8 {
        if (self.idx >= self.str.len) {
            return null;
        }
        const remaining = self.str.len - self.idx;
        const max_len = @min(remaining, config.max_stream_name_len);
        const len = rng.intRangeAtMost(usize, 0, max_len);
        const end = self.idx + len;
        const res = self.str[self.idx..end];
        self.idx = end;
        return res;
    }
};

const Simulator = struct {
    const Node = lib.Node(os.FD);

    rng: *std.Random,
    usr_ctx: usr.Ctx,
    node: Node,
    os: os.OS,
    rsng: RandStreamNameGenerator,
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator, rng: *std.Random) !@This() {
        return .{
            .rng = rng,
            .usr_ctx = usr.Ctx.init(),
            .node = try Node.init(allocator),
            .os = os.OS.init(allocator, rng),
            .rsng = try RandStreamNameGenerator.init(allocator, rng),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.node.deinit(self.allocator);
        self.os.deinit(self.allocator);
        self.rsng.deinit(self.allocator);
    }

    fn tick(self: *@This()) !void {
        if (config.create_stream_chance > self.rng.float(f64)) {
            if (self.rsng.get(self.rng)) |s| {
                const usr_req = lib.Usr.Req{ .topic_create = .{ .name = s } };
                const fs_req = self.node.req_usr_to_fs(usr_req) catch |err| {
                    self.usr_ctx.on_stream_create_req_err(err);
                    return;
                };

                try self.os.send(fs_req);
            }
        }
        if (config.advance_os_chance > self.rng.float(f64)) {
            try self.os.tick(self.allocator, &self.node, &self.usr_ctx);
        }
    }

    fn stats(self: *@This()) struct { c.os_stats, c.usr_stats } {
        return .{ self.os.stats, self.usr_ctx.stats };
    }
};

fn live_simulation(sim: *Simulator) !void {
    var tui = mem.zeroes(c.tui);
    c.tui_init(&tui);
    defer c.tui_deinit(&tui);

    var time: u64 = 0;
    while (time <= config.max_time_in_ms) : (time += 10) {
        try sim.tick();
        if (time % 1000 == 0) {
            const more_ticks = c.tui_tick(
                &tui,
                &sim.os.stats,
                &sim.usr_ctx.stats,
                time,
            );

            if (!more_ticks) return;
        }
    }
}

fn bg_simulation(sim: *Simulator) !void {
    const phys_start_time = std.time.microTimestamp();

    var time: u64 = 0;
    while (time <= config.max_time_in_ms) : (time += 10) {
        try sim.tick();
    }

    const phys_end_time = std.time.microTimestamp();
    const phys_time_elapsed: f128 =
        @floatFromInt(phys_end_time - phys_start_time);

    std.debug.print("Stats: {}\n", .{sim.stats()});
    std.debug.print("Time: {} μs\n", .{phys_time_elapsed});
}

pub fn main() !void {
    var args = std.process.args();
    _ = args.skip();

    const mode = args.next() orelse @panic("First arg must be 'live' or 'bg'");
    const seed = if (args.next()) |arg|
        try std.fmt.parseInt(u64, arg, 16)
    else
        std.crypto.random.int(u64);

    std.debug.print("Seed = {x}\n", .{seed});

    var rng = rand.DefaultPrng.init(seed);
    var random = rng.random();
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    var sim = try Simulator.init(gpa.allocator(), &random);

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
    var random = rng.random();
    var sim = try Simulator.init(testing.allocator, &random);
    for (0..1000) |_| {
        try sim.tick();
    }
    defer sim.deinit();
}

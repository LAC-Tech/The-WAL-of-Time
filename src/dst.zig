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
    const file_io = lib.file_io(FD);
    const Event = struct { priority: u64, req: file_io.req };

    fn event_compare(_: void, a: Event, b: Event) math.Order {
        return math.order(a.priority, b.priority);
    }
    const EventQueue = PriorityQueue(Event, void, event_compare);

    const OS = struct {
        events: PriorityQueue(Event, void, event_compare),
        files: ArrayListUnmanged(ArrayListUnmanged(u8)),
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

        pub fn send(self: *@This(), req: file_io.req) !void {
            const e = .{ .priority = self.rng.int(u64), .req = req };
            try self.events.add(e);
        }

        fn handle_req(
            self: *@This(),
            allocator: mem.Allocator,
            req: file_io.req,
        ) !file_io.res {
            switch (req) {
                .create => |usr_data| {
                    try self.files.append(allocator, .{});
                    const fd = self.files.items.len;
                    self.stats.files_created += 1;
                    return .{ .create = .{ .fd = fd, .usr_data = usr_data } };
                },
                else => @panic("TODO: handle more events"),
            }
        }

        // Advances the state of the OS.
        // Should not happen every sim tick, I don't think
        pub fn tick(
            self: *@This(),
            allocator: mem.Allocator,
            db: *lib.DB(FD),
            usr_ctx: *usr.Ctx,
        ) !void {
            const event = self.events.removeOrNull() orelse return;
            const res = try self.handle_req(allocator, event.req);
            try db.receive_io(res, usr_ctx);
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
            err: lib.CreateStreamReqErr,
        ) void {
            switch (err) {
                error.DuplicateStreamNameRequested => {
                    self.stats.stream_name_duplicates += 1;
                },
                error.RequestedStreamNameOverflow => {
                    self.stats.stream_name_reservation_limit_exceeded += 1;
                },
            }
        }

        pub fn send(self: *@This(), res: lib.URes) void {
            switch (res) {
                .stream_created => {
                    self.stats.streams_created += 1;
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
    const DB = lib.DB(os.FD);

    rng: *std.Random,
    usr_ctx: usr.Ctx,
    db: DB,
    os: os.OS,
    rsng: RandStreamNameGenerator,
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator, rng: *std.Random) !@This() {
        return .{
            .rng = rng,
            .usr_ctx = usr.Ctx.init(),
            .db = try DB.init(allocator),
            .os = os.OS.init(allocator, rng),
            .rsng = try RandStreamNameGenerator.init(allocator, rng),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.db.deinit(self.allocator);
        self.os.deinit(self.allocator);
        self.rsng.deinit(self.allocator);
    }

    fn tick(self: *@This()) !void {
        if (config.create_stream_chance > self.rng.float(f64)) {
            if (self.rsng.get(self.rng)) |s| {
                self.db.create_stream(s, &self.os) catch |err| {
                    switch (err) {
                        error.OutOfMemory => return err,
                        else => |scre| {
                            self.usr_ctx.on_stream_create_req_err(scre);
                        },
                    }
                };
            }
        }
        if (config.advance_os_chance > self.rng.float(f64)) {
            try self.os.tick(self.allocator, &self.db, &self.usr_ctx);
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
        if (time % (1000 * 60) == 0) {
            const res = c.tui_tick(
                &tui,
                &sim.os.stats,
                &sim.usr_ctx.stats,
                time,
            );

            switch (res) {
                c.TUI_EXIT => return,
                c.TUI_CONTINUE => {},
                c.TUI_PAUSE => {} // TODO: ,
                // Zig can't do exhausting switching on C enums
                else => unreachable,
            }
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
        try std.fmt.parseInt(u64, arg, 10)
    else
        std.crypto.random.int(u64);

    std.debug.print("Seed = {}\n", .{seed});

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
//
//test "sim lifetime" {
//    var rng = rand.DefaultPrng.init(0);
//    var sim = try Simulator.init(testing.allocator, rng.random());
//    for (0..1000) |_| {
//        try sim.tick();
//    }
//    defer sim.deinit();
//}

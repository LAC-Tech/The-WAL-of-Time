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

const os = struct {
    const FD = usize;
    const file_io = lib.file_io(FD);
    const Event = struct { priority: u64, req: file_io.req };

    fn event_compare(_: void, a: Event, b: Event) math.Order {
        return math.order(a.priority, b.priority);
    }
    const EventQueue = PriorityQueue(Event, void, event_compare);
    const Stats = struct { file_created: u64 = 0 };

    const OS = struct {
        events: PriorityQueue(Event, void, event_compare),
        files: ArrayListUnmanged(ArrayListUnmanged(u8)),
        // Needs its own rng so we can confrom to FileIO interface
        // TODO: make FileIO pass in some arbitrary "context" parameter???
        random: std.Random,
        stats: Stats,

        pub fn init(allocator: mem.Allocator, random: std.Random) @This() {
            return .{
                .events = EventQueue.init(allocator),
                .files = .{},
                .random = random,
                .stats = .{},
            };
        }

        pub fn deinit(self: *@This(), allocator: mem.Allocator) void {
            self.events.deinit(allocator);
            for (self.files.items) |file| {
                file.deinit(allocator);
            }
            self.files.deinit(allocator);
        }

        // Advances the state of the OS.
        // Should not happen every sim tick, I don't think
        pub fn tick(self: *@This(), db: lib.DB(FD), usr_ctx: *usr.Ctx) !void {
            const event = self.events.removeOrNull() orelse return;
            const res = switch(event.req) {
            };

            db.receive_io(res, usr_ctx);
        }
    };
};

const usr = struct {
    const Ctx = struct {
        stats: Stats,

        pub fn on_stream_create_req_err(
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
    };

    const Stats = struct {
        streams_created: u64,
        stream_name_duplicates: u64,
        stream_name_reservation_limit_exceeded: u64,
    };
};

const RandStreamNameGenerator = struct {
    str: []const u8,
    idx: usize,

    fn init(allocator: mem.Allocator, rng: *std.Random) @This() {
        var str = try allocator.alloc([]const u8, config.MAX_BYTES_STREAM_NAMES_SRC);
        rng.fill(self.str);
        //let str: Box<[u8]> = (0..config::MAX_BYTES_STREAM_NAMES_SRC)
        //    .map(|_| rng.random::<u8>())
        //    .collect();
        //let str = Box::leak(str);
        //Self { str, idx: 0 }
    }
    //fn get(&mut self, rng: &mut impl Rng) -> Option<&'static [u8]> {
    //    if self.idx >= self.str.len() {
    //        return None;
    //    }
    //    let remaining = self.str.len() - self.idx;
    //    let len =
    //        rng.random_range(0..=remaining.min(config::MAX_STREAM_NAME_LEN));
    //    let end = self.idx + len;
    //    let res = &self.str[self.idx..end];
    //    self.idx = end;
    //    Some(res)
    //}
};


}
// Configuration parameters for the DST
// In one place for ease of tweaking
const config = struct {
    const MAX_TIME_IN_MS: u64 = 1000 * 60 * 60 * 24; // 24 hours,
    const CREATE_STREAM_CHANCE: f64 = 0.01;
    const ADVANCE_OS_CHANCE: f64 = 0.1;
    const MAX_STREAM_NAME_LEN: usize = 64;
    const MAX_BYTES_STREAM_NAMES_SRC: usize = 1024;
};
//const FileIO = struct {
//    fs: ArrayListUnmanged(ArrayListUnmanged(u8)),
//    events: Events,
//    allocator: std.mem.Allocator,
//
//    pub const FD = usize;
//    pub fn init(allocator: std.mem.Allocator) !@This() {
//        const events = Events.init(allocator, {});
//        //try events.ensureTotalCapacity(256);
//        return .{
//            .fs = try ArrayListUnmanged(ArrayListUnmanged(u8)).initCapacity(
//                allocator,
//                1_000_000,
//            ),
//            .events = events,
//            .allocator = allocator,
//        };
//    }
//
//    pub fn deinit(self: *@This()) void {
//        self.fs.deinit(self.allocator);
//        self.events.deinit();
//    }
//
//    const Event = struct { priority: u64, os_input: lib.FileOp(FD).Input };
//    const Events = PriorityQueue(Event, void, struct {
//        fn compare(_: void, a: Event, b: Event) math.Order {
//            return math.order(a.priority, b.priority);
//        }
//    }.compare);
//
//    /// Nothing ever happens... until we advance the state of the OS.
//    fn tick(self: *@This(), db: *lib.DB(FileIO)) !void {
//        const event = self.events.removeOrNull() orelse return;
//
//        switch (event.os_input.file_op) {
//            .create => {
//                const fd = self.fs.items.len;
//                const file = ArrayListUnmanged(u8){};
//                try self.fs.append(self.allocator, file);
//                db.receive_io(.{
//                    .task_id = event.os_input.task_id,
//                    .file_op = .{ .create = @intCast(fd) },
//                });
//            },
//            .read => |_| {
//                @panic("TODO: Read");
//            },
//            .append => |_| {
//                @panic("TODO: Append");
//            },
//            .delete => |_| {
//                @panic("TODO: Delete");
//            },
//        }
//    }
//
//    pub fn send(
//        ctx: *Context,
//        msg: lib.FileOp(FD).Input,
//    ) !void {
//        const event = .{
//            .priority = ctx.random.int(u64),
//            .os_input = msg,
//        };
//        try self.events.add(event);
//    }
//};
//
//const Context = struct {
//    random: std.Random,
//    stats: c.stats,
//};
//
//pub fn onReceive(ctx: *Context, res: lib.Res) void {
//    switch (res) {
//        .create => {
//            ctx.stats.os_files_created += 1;
//        },
//        else => @panic("TODO: collect more stats"),
//    }
//}
//
//const Simulator = struct {
//    node: lib.Node(FileIO, Context, onReceive),
//    ctx: Context,
//
//    fn init(allocator: mem.Allocator, random: std.Random) !@This() {
//        const ctx = .{
//            .random = random,
//            .stats = .{ .os_files_created = 0 },
//        };
//        return .{
//            .ctx = ctx,
//            .node = try lib.Node(FileIO, Context, onReceive).init(allocator, ctx),
//        };
//    }
//
//    fn deinit(self: *@This()) void {
//        self.node.deinit();
//    }
//
//    fn tick(self: *@This()) !void {
//        if (Config.create_file_chance > self.ctx.random.float(f64)) {
//            try self.node.create_stream("lmao");
//        }
//
//        try self.db.os.tick(&self.db);
//    }
//};
//
//// Configuration parameters for the DST
//// In one place for ease of tweaking
//const Config = struct {
//    const max_sim_time_in_ms: u64 = 1000 * 60 * 60 * 24; // 24 hours
//
//    // TODO: these chances are temporary; will later be driven by actual db
//    const create_file_chance = 0.1;
//    const delete_file_chance = 0.05;
//};
//
//fn live_simulation(sim: *Simulator) !void {
//    var tui = mem.zeroes(c.tui);
//    c.tui_init(&tui);
//    defer c.tui_deinit(&tui);
//
//    var time: u64 = 0;
//    while (time <= Config.max_sim_time_in_ms) : (time += 10) {
//        try sim.tick();
//        if (time % (1000 * 60) == 0) {
//            c.tui_sim_render(&tui, &sim.ctx.stats, time);
//        }
//    }
//}
//
//fn bg_simulation(sim: *Simulator) !void {
//    const phys_start_time = std.time.microTimestamp();
//
//    var time: u64 = 0;
//    while (time <= Config.max_sim_time_in_ms) : (time += 10) {
//        try sim.tick();
//    }
//
//    const phys_end_time = std.time.microTimestamp();
//    const phys_time_elapsed: f128 =
//        @floatFromInt(phys_end_time - phys_start_time);
//
//    std.debug.print(
//        "Stats: OS files created: {}\n",
//        .{sim.ctx.stats.os_files_created},
//    );
//    std.debug.print("Time: {} μs\n", .{phys_time_elapsed});
//}

pub fn main() !void {
    //var args = std.process.args();
    //_ = args.skip();

    //const mode = args.next() orelse @panic("First arg must be 'live' or 'bg'");
    //const seed = if (args.next()) |arg|
    //    try std.fmt.parseInt(u64, arg, 10)
    //else
    //    std.crypto.random.int(u64);

    //std.debug.print("Seed = {}\n", .{seed});

    //var rng = rand.DefaultPrng.init(seed);
    //var gpa = heap.GeneralPurposeAllocator(.{}){};
    //var sim = try Simulator.init(gpa.allocator(), rng.random());

    //if (std.mem.eql(u8, mode, "bg")) {
    //    try bg_simulation(&sim);
    //} else if (std.mem.eql(u8, mode, "live")) {
    //    try live_simulation(&sim);
    //} else {
    //    unreachable;
    //}

    //sim.deinit();
    //if (gpa.deinit() == .leak) {
    //    std.debug.print("memory leak!!!!", .{});
    //}
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

//! Deterministic Simulation Tester

const std = @import("std");
const math = std.math;
const mem = std.mem;
const ArrayList = std.ArrayListUnmanaged;
const Random = std.Random;

const aio = @import("./async_io.zig");

pub const FD = usize;

pub fn fd_eql(a: FD, b: FD) bool {
    return a == b;
}

const aio_msg = aio.msg(FD);
const aio_req = aio_msg.req;
const AioRes = aio_msg.Res;

fn RandRange(comptime T: type) type {
    return struct {
        at_least: T,
        at_most: T,

        fn init(at_least: T, at_most: T) @This() {
            return .{ .at_least = at_least, .at_most = at_most };
        }

        fn gen(self: @This(), rng: anytype) T {
            return rng.random().intRangeAtMost(T, self.at_least, self.at_most);
        }
    };
}

const config = struct {
    const kernel_process_time = RandRange(u64).init(1, 10);
    const completion_transfer_time = RandRange(u64).init(1, 5);
    const flush_time = RandRange(u64).init(1, 5);
};

pub const Time = struct {
    _current: u64,

    pub fn init() Time {
        return .{ ._current = 0 };
    }

    fn advance(self: *Time, delta: u64) void {
        self._current += delta;
    }

    fn now(self: Time) u64 {
        return self._current;
    }
};

const DebugLog = struct {
    file: std.fs.File,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, seed: u64) !@This() {
        const log_dir = "log";
        try std.fs.cwd().makePath(log_dir);
        const filename = try std.fmt.allocPrint(
            allocator,
            "{s}/log_{d}_{d}.txt",
            .{
                log_dir,
                seed,
                std.time.milliTimestamp(),
            },
        );
        defer allocator.free(filename);
        const file = try std.fs.cwd().createFile(filename, .{});
        return .{ .file = file, .allocator = allocator };
    }

    pub fn deinit(self: *@This()) void {
        self.file.close();
    }

    pub fn write(
        self: *@This(),
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        try self.file.writer().print(fmt, args);
    }
};

// TODO: single "inflight req" queue, with processing and completed items.
// advanced time until you find a completed item and pop that, to sim blocking
// can also receive messages

pub const AsyncIO = struct {
    input_reqs: ArrayList(Req),
    pq: Processing.Queue,
    cq: Completion.Queue,
    rng: Random.DefaultPrng,
    time: *Time,

    pub fn init(allocator: mem.Allocator, seed: u64, time: *Time) !@This() {
        return .{
            .input_reqs = try ArrayList(Req).initCapacity(allocator, 64),
            .pq = Processing.Queue.init(allocator, {}),
            .cq = Completion.Queue.init(allocator, {}),
            .rng = Random.DefaultPrng.init(seed),
            .time = time,
        };
    }

    pub fn deinit(self: *@This(), allocator: mem.Allocator) void {
        self.input_reqs.deinit(allocator);
        self.pq.deinit();
        self.cq.deinit();
    }

    pub fn accept(self: *@This(), usr_data: u64) !void {
        self.input_reqs.appendAssumeCapacity(.{ .accept = usr_data });
    }

    pub fn recv(self: *@This(), req: aio_req.Recv) !void {
        self.input_reqs.appendAssumeCapacity(.{ .recv = req });
    }

    pub fn send(self: *@This(), req: aio_req.Send) !void {
        self.input_reqs.appendAssumeCapacity(.{ .send = req });
    }

    pub fn flush(self: *@This()) !u32 {
        const result = self.input_reqs.items.len;

        for (self.input_reqs.items) |req| {
            // put things on the processing queue

            const pqe: Processing.Item = .{
                .req = req,
                .exec_time = self.time.now() + config.kernel_process_time.gen(
                    &self.rng,
                ),
            };

            try self.pq.add(pqe);
        }

        self.input_reqs.clearRetainingCapacity();
        return @intCast(result);
    }

    pub fn wait_for_res(self: *@This()) !AioRes {
        // TODO:
        // - skip forward

        if (self.cq.removeOrNull()) |completed| {
            self.time.advance(completed.ready_time - self.time.now());

            // Remove any processed ops from processing queue
            while (self.pq.peek()) |proc| {
                if (proc.exec_time <= self.time.now()) {
                    _ = self.pq.remove();
                } else {
                    break;
                }
            }

            return .{
                .rc = completed.result,
                .usr_data = switch (completed.req) {
                    .accept => |u| u,
                    .recv => |r| r.usr_data,
                    .send => |s| s.usr_data,
                },
            };
        }
        return error.NoCompletions;
    }

    fn rand(
        self: *@This(),
        comptime T: type,
        at_least: T,
        at_most: T,
    ) u64 {
        return self.rng.random().intRangeAtMost(T, at_least, at_most);
    }
};

const Req = union(enum) {
    accept: u64,
    recv: aio_req.Recv,
    send: aio_req.Send,
};

const Processing = struct {
    const Queue = std.PriorityQueue(Item, void, compare);

    const Item = struct {
        req: Req,
        /// At this point it will be executed and passed to the Completion queue
        exec_time: u64,
    };

    fn compare(_: void, a: Item, b: Item) math.Order {
        return math.order(a.exec_time, b.exec_time);
    }
};

const Completion = struct {
    const Queue = std.PriorityQueue(Item, void, compare);

    const Item = struct {
        req: Req,
        /// Time when it can be popped off the completion queue
        ready_time: u64,
        result: FD,
    };

    fn compare(_: void, a: Item, b: Item) math.Order {
        return math.order(a.ready_time, b.ready_time);
    }
};

//const heap = std.heap;
//const math = std.math;
//const mem = std.mem;
//const posix = std.posix;
//const rand = std.Random;
//const testing = std.testing;
//
//const ArrayList = std.ArrayListUnmanaged;
//const PriorityQueue = std.PriorityQueue;
//
//const lib = @import("./lib.zig");
//
//const c = @cImport({
//    @cInclude("tui.h");
//});
//
//// Configuration parameters for the DST
//// In one place for ease of tweaking
//const config = struct {
//    const max_time_in_ms: u64 = 1000 * 60 * 60 * 24; // 24 hours,
//    const create_stream_chance: f64 = 0.001;
//    const advance_os_chance: f64 = 0.1;
//    const max_stream_name_len: usize = 64;
//    const max_bytes_stream_names_src: usize = 0xFFFF;
//};
//
//const os = struct {
//    const FD = usize;
//    const fs_msg = lib.FsMsg(FD);
//    const fs_req = fs_msg.req;
//    const fs_res = fs_msg.res;
//    const Event = struct { priority: u64, req: fs_req };
//
//    fn event_compare(_: void, a: Event, b: Event) math.Order {
//        return math.order(a.priority, b.priority);
//    }
//    const EventQueue = PriorityQueue(Event, void, event_compare);
//
//    const OS = struct {
//        events: EventQueue,
//        files: ArrayList(ArrayList(u8)),
//        rng: *std.Random,
//        stats: c.os_stats,
//
//        fn init(allocator: mem.Allocator, rng: *std.Random) @This() {
//            return .{
//                .events = EventQueue.init(allocator, {}),
//                .files = .{},
//                .rng = rng,
//                .stats = mem.zeroes(c.os_stats),
//            };
//        }
//
//        fn deinit(self: *@This(), allocator: mem.Allocator) void {
//            self.events.deinit();
//            for (self.files.items) |*file| {
//                file.deinit(allocator);
//            }
//            self.files.deinit(allocator);
//        }
//
//        pub fn send(self: *@This(), req: fs_req) !void {
//            const e: Event = .{ .priority = self.rng.int(u64), .req = req };
//            try self.events.add(e);
//        }
//
//        fn handle_req(
//            self: *@This(),
//            allocator: mem.Allocator,
//            req: fs_req,
//        ) !fs_res {
//            switch (req) {
//                .create => |ctx| {
//                    try self.files.append(allocator, .{});
//                    const fd = self.files.items.len;
//                    self.stats.files_created += 1;
//                    return .{ .create = .{ .fd = fd, .ctx = ctx } };
//                },
//                else => @panic("TODO: handle more events"),
//            }
//        }
//
//        // Advances the state of the OS.
//        // Should not happen every sim tick, I don't think
//        pub fn tick(
//            self: *@This(),
//            allocator: mem.Allocator,
//            node: *lib.Node(FD),
//            usr_ctx: *usr.Ctx,
//        ) !void {
//            const event = self.events.removeOrNull() orelse return;
//            const res = try self.handle_req(allocator, event.req);
//            usr_ctx.send(try node.res_fs_to_usr(res));
//        }
//    };
//};
//
//const usr = struct {
//    const Ctx = struct {
//        stats: c.usr_stats,
//
//        fn init() @This() {
//            return .{ .stats = mem.zeroes(c.usr_stats) };
//        }
//
//        fn on_stream_create_req_err(
//            self: *@This(),
//            err: lib.CreateTopicErr,
//        ) void {
//            switch (err) {
//                error.TopicNameAlreadyExists => {
//                    self.stats.topic_name_duplicates += 1;
//                },
//                error.MaxTopics => {
//                    self.stats.topic_name_reservation_limit_exceeded += 1;
//                },
//            }
//        }
//
//        pub fn send(self: *@This(), res: lib.Usr.Res) void {
//            switch (res) {
//                .topic_create => {
//                    self.stats.topics_created += 1;
//                },
//            }
//        }
//    };
//};
//
//const RandStreamNameGenerator = struct {
//    str: []const u8,
//    idx: usize,
//
//    pub fn init(allocator: mem.Allocator, rng: *std.Random) !@This() {
//        const bytes: []u8 = try allocator.alloc(
//            u8,
//            config.max_bytes_stream_names_src,
//        );
//        rng.bytes(bytes);
//        return RandStreamNameGenerator{ .str = bytes, .idx = 0 };
//    }
//
//    pub fn deinit(self: *@This(), allocator: mem.Allocator) void {
//        allocator.free(self.str);
//    }
//
//    pub fn get(self: *@This(), rng: *std.Random) ?[]const u8 {
//        if (self.idx >= self.str.len) {
//            return null;
//        }
//        const remaining = self.str.len - self.idx;
//        const max_len = @min(remaining, config.max_stream_name_len);
//        const len = rng.intRangeAtMost(usize, 0, max_len);
//        const end = self.idx + len;
//        const res = self.str[self.idx..end];
//        self.idx = end;
//        return res;
//    }
//};
//
//const Simulator = struct {
//    const Node = lib.Node(os.FD);
//
//    rng: *std.Random,
//    usr_ctx: usr.Ctx,
//    node: Node,
//    os: os.OS,
//    rsng: RandStreamNameGenerator,
//    allocator: mem.Allocator,
//
//    pub fn init(allocator: mem.Allocator, rng: *std.Random) !@This() {
//        return .{
//            .rng = rng,
//            .usr_ctx = usr.Ctx.init(),
//            .node = try Node.init(allocator),
//            .os = os.OS.init(allocator, rng),
//            .rsng = try RandStreamNameGenerator.init(allocator, rng),
//            .allocator = allocator,
//        };
//    }
//
//    pub fn deinit(self: *@This()) void {
//        self.node.deinit(self.allocator);
//        self.os.deinit(self.allocator);
//        self.rsng.deinit(self.allocator);
//    }
//
//    fn tick(self: *@This()) !void {
//        if (config.create_stream_chance > self.rng.float(f64)) {
//            if (self.rsng.get(self.rng)) |s| {
//                const usr_req = lib.Usr.Req{ .topic_create = .{ .name = s } };
//                const fs_req = self.node.req_usr_to_fs(usr_req) catch |err| {
//                    self.usr_ctx.on_stream_create_req_err(err);
//                    return;
//                };
//
//                try self.os.send(fs_req);
//            }
//        }
//        if (config.advance_os_chance > self.rng.float(f64)) {
//            try self.os.tick(self.allocator, &self.node, &self.usr_ctx);
//        }
//    }
//
//    fn stats(self: *@This()) struct { c.os_stats, c.usr_stats } {
//        return .{ self.os.stats, self.usr_ctx.stats };
//    }
//};
//
//fn live_simulation(sim: *Simulator) !void {
//    var tui = mem.zeroes(c.tui);
//    c.tui_init(&tui);
//    defer c.tui_deinit(&tui);
//
//    var time: u64 = 0;
//    while (time <= config.max_time_in_ms) : (time += 10) {
//        try sim.tick();
//        if (time % 1000 == 0) {
//            const more_ticks = c.tui_tick(
//                &tui,
//                &sim.os.stats,
//                &sim.usr_ctx.stats,
//                time,
//            );
//
//            if (!more_ticks) return;
//        }
//    }
//}
//
//fn bg_simulation(sim: *Simulator) !void {
//    const phys_start_time = std.time.microTimestamp();
//
//    var time: u64 = 0;
//    while (time <= config.max_time_in_ms) : (time += 10) {
//        try sim.tick();
//    }
//
//    const phys_end_time = std.time.microTimestamp();
//    const phys_time_elapsed: f128 =
//        @floatFromInt(phys_end_time - phys_start_time);
//
//    std.debug.print("Stats: {}\n", .{sim.stats()});
//    std.debug.print("Time: {} μs\n", .{phys_time_elapsed});
//}
//
//pub fn main() !void {
//    var args = std.process.args();
//    _ = args.skip();
//
//    const mode = args.next() orelse @panic("First arg must be 'live' or 'bg'");
//    const seed = if (args.next()) |arg|
//        try std.fmt.parseInt(u64, arg, 16)
//    else
//        std.crypto.random.int(u64);
//
//    std.debug.print("Seed = {x}\n", .{seed});
//
//    var rng = rand.DefaultPrng.init(seed);
//    var random = rng.random();
//    var gpa = heap.GeneralPurposeAllocator(.{}){};
//    var sim = try Simulator.init(gpa.allocator(), &random);
//
//    if (std.mem.eql(u8, mode, "bg")) {
//        try bg_simulation(&sim);
//    } else if (std.mem.eql(u8, mode, "live")) {
//        try live_simulation(&sim);
//    } else {
//        unreachable;
//    }
//
//    sim.deinit();
//    if (gpa.deinit() == .leak) {
//        std.debug.print("memory leak!!!!", .{});
//    }
//}
//
//test "sim lifetime" {
//    var rng = rand.DefaultPrng.init(0);
//    var random = rng.random();
//    var sim = try Simulator.init(testing.allocator, &random);
//    for (0..1000) |_| {
//        try sim.tick();
//    }
//    defer sim.deinit();
//}

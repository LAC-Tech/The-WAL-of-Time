//! Simulated Async IO, for use with Deterministic Simulation Testing

const std = @import("std");
const math = std.math;
const mem = std.mem;
const testing = std.testing;

pub const FD = @import("./fd.zig").module(usize);
const util = @import("./util.zig");

const Rng = std.Random.DefaultPrng;

const config = struct {
    const completion_time = RandRange(u64).init(1, 10);
    const user_time = RandRange(u64).init(1, 5);
};

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

pub fn AsyncIO(comptime settings: struct { max_clients: comptime_int }) type {
    const Submitted = TickQueue(Req.T, 8);
    const Completed = TickQueue(FD.IORes, 8);
    const ClientFDs = std.bit_set.StaticBitSet(settings.max_clients);

    return struct {
        sq: Submitted,
        cq: Completed,
        socket_fd: FD.ServerSock.T,
        rng: *Rng,
        ticks: *const u64,
        client_fds: ClientFDs,

        pub fn init(
            allocator: mem.Allocator,
            rng: *Rng,
            ticks: *const u64,
        ) !@This() {
            // TODO maybe we'll need one eventually? idk
            _ = allocator;
            return .{
                .sq = try Submitted.init(),
                .cq = try Completed.init(),
                .socket_fd = @enumFromInt(rng.random().int(FD.Int)),
                .rng = rng,
                .ticks = ticks,
                .client_fds = ClientFDs.initEmpty(),
            };
        }

        pub fn deinit(self: *@This(), allocator: mem.Allocator) void {
            _ = self;
            _ = allocator;
            @panic("we need this now");
        }

        /// Number of entries submitted
        pub fn send(self: *@This(), reqs: []const Req.T) !u32 {
            for (reqs) |r| {
                try self.sq.insert(
                    r,
                    self.ticks.* + config.completion_time.gen(self.rng),
                );
            }

            return @intCast(reqs.len);
        }

        pub fn tick(self: *@This()) !?FD.IORes {
            if (self.sq.pop(self.ticks)) |req| {
                const res = try self.exec(req);

                try self.cq.insert(
                    res,
                    self.ticks.* + config.user_time.gen(self.rng),
                );
            }

            return self.cq.pop(self.ticks);
        }

        // TODO this may beling in a separate struct that wraps client FDs
        fn exec(self: *@This(), req: Req.T) !FD.IORes {
            switch (req) {
                // Ignored the socket arg; not relevant in sim?
                .accept => |a| {
                    const fd = self.rng.random().int(FD.Int);
                    self.client_fds.set(fd);
                    return .{ .rc = fd, .usr_data = a.usr_data };
                },
                .recv => |r| {
                    const fd = @intFromEnum(r.fd);
                    if (!self.client_fds.isSet(fd)) {
                        @panic("recv: handle a non existent client ID");
                    }

                    // TODO: random lengths?
                    self.rng.random().bytes(r.buf);

                    return .{
                        .rc = r.buf.len,
                        .usr_data = r.usr_data,
                    };
                },
                .send => |s| {
                    const fd = @intFromEnum(s.fd);
                    if (!self.client_fds.isSet(fd)) {
                        @panic("send: handle a non existent client ID");
                    }
                    std.log.debug("{}", .{std.fmt.fmtSliceHexLower(s.buf)});

                    return .{ .rc = s.buf.len, .usr_data = s.usr_data };
                },
            }
        }
    };
}

/// Small, sorted arrays that pop elements when it's time
fn TickQueue(comptime Item: type, comptime capacity: usize) type {
    return struct {
        const Elem = struct { item: Item, pop_time: u64 };

        fn lessThan(_: void, a: Elem, b: Elem) bool {
            return a.pop_time > b.pop_time;
        }

        const Elems = std.BoundedArray(Elem, capacity);

        elems: std.BoundedArray(Elem, capacity),

        fn init() !@This() {
            return .{ .elems = try Elems.init(0) };
        }

        fn insert(self: *@This(), item: Item, pop_time: u64) !void {
            try self.elems.append(.{ .item = item, .pop_time = pop_time });
            std.sort.insertion(Elem, self.elems.slice(), {}, lessThan);
        }

        fn pop(self: *@This(), tick: *const u64) ?Item {
            if (self.elems.len == 0) return null;
            const last = self.elems.get(self.elems.len - 1);
            if (last.pop_time > tick.*) {
                return null;
            }
            return self.elems.pop().?.item;
        }

        fn constSlice(self: *@This()) []const Elem {
            return self.list.constSlice();
        }
    };
}

pub const Req = struct {
    pub const T = union(enum) {
        accept: struct { usr_data: u64, fd: FD.ServerSock.T },
        recv: struct { usr_data: u64, fd: FD.ClientSock.T, buf: []u8 },
        send: struct { usr_data: u64, fd: FD.ClientSock.T, buf: []const u8 },
    };

    pub fn accept_multishot(usr_data: u64, fd: FD.ServerSock.T) T {
        return .{
            .accept = .{ .usr_data = usr_data, .fd = fd },
        };
    }

    pub fn recv(usr_data: u64, fd: FD.ClientSock.T, buf: []u8) T {
        return .{
            .recv = .{ .usr_data = usr_data, .fd = fd, .buf = buf },
        };
    }

    pub fn send(usr_data: u64, fd: FD.ClientSock.T, buf: []const u8) T {
        return .{
            .send = .{ .usr_data = usr_data, .fd = fd, .buf = buf },
        };
    }
};

//const DebugLog = struct {
//    file: std.fs.File,
//    allocator: std.mem.Allocator,
//
//    pub fn init(allocator: std.mem.Allocator, seed: u64) !@This() {
//        const log_dir = "log";
//        try std.fs.cwd().makePath(log_dir);
//        const filename = try std.fmt.allocPrint(
//            allocator,
//            "{s}/log_{d}_{d}.txt",
//            .{
//                log_dir,
//                seed,
//                std.time.milliTimestamp(),
//            },
//        );
//        defer allocator.free(filename);
//        const file = try std.fs.cwd().createFile(filename, .{});
//        return .{ .file = file, .allocator = allocator };
//    }
//
//    pub fn deinit(self: *@This()) void {
//        self.file.close();
//    }
//
//    pub fn write(
//        self: *@This(),
//        comptime fmt: []const u8,
//        args: anytype,
//    ) !void {
//        try self.file.writer().print(fmt, args);
//    }
//};

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

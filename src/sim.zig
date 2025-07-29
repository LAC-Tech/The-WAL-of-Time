//! Simulated Async IO, for use with Deterministic Simulation Testing

const std = @import("std");
const debug = std.debug;
const math = std.math;
const mem = std.mem;
const testing = std.testing;

pub const FD = u8;
const core = @import("./core.zig");
const Res = core.OSResponse(FD);
const Sock = core.Socket(FD);

const util = @import("./util.zig");

const Rng = std.Random.DefaultPrng;

const config = struct {
    const delay = struct {
        const exec = .{ 1, 20 };
        const usr = .{ 1, 5 };
    };
};

fn rand_range(rng: anytype, range: struct { u64, u64 }) u64 {
    const at_least, const at_most = range;
    return rng.random().intRangeAtMost(u64, at_least, at_most);
}

pub const AsyncIO = struct {
    // Makes things easier, but a bit artifical
    const max_clients = math.maxInt(FD);
    const ClientFDs = std.bit_set.StaticBitSet(max_clients);

    processing: TickQueue(Req.T, 8),
    /// Intermediate state; req has been executed, but not seen by user
    completed: TickQueue(Res, 8),
    server_fd: Sock.Server,
    rng: *Rng,
    ticks: *const u64,
    client_fds: ClientFDs,

    pub fn init(
        rng: *Rng,
        ticks: *const u64,
    ) !@This() {
        return .{
            .processing = try TickQueue(Req.T, 8).init(),
            .completed = try TickQueue(Res, 8).init(),
            .server_fd = @enumFromInt(rng.random().int(FD)),
            .rng = rng,
            .ticks = ticks,
            .client_fds = ClientFDs.initEmpty(),
        };
    }

    /// Number of entries submitted
    pub fn send(self: *@This(), reqs: []const Req.T) !u32 {
        for (reqs) |r| {
            const t = self.ticks.* + rand_range(self.rng, config.delay.exec);
            try self.processing.insert(r, t);
        }

        return @intCast(reqs.len);
    }

    pub fn tick(self: *@This()) !?Res {
        if (self.processing.pop(self.ticks)) |req| {
            const res = try self.exec(req);
            const t = self.ticks.* + rand_range(self.rng, config.delay.usr);
            try self.completed.insert(res, t);
        }

        return self.completed.pop(self.ticks);
    }

    // TODO this may belong in a separate struct that wraps client FDs
    fn exec(self: *@This(), req: Req.T) !Res {
        switch (req.op) {
            // TODO: Ignored the socket arg; this seems like a massive error
            .accept => |_| {
                @panic("Read your TODO comment");
                //const fd = self.rng.random().int(FD);
                //self.client_fds.set(fd);
                //return .{ .rc = fd, .usr_data = req.usr_data };
            },
            .recv => |r| {
                const fd = @intFromEnum(r.fd);
                if (!self.client_fds.isSet(fd)) {
                    @panic("recv: handle a non existent client ID");
                }

                // TODO: random lengths?
                self.rng.random().bytes(r.buf);

                return .{
                    .rc = @intCast(r.buf.len),
                    .usr_data = req.usr_data,
                };
            },
            .send => |s| {
                const fd = @intFromEnum(s.fd);
                if (!self.client_fds.isSet(fd)) {
                    @panic("send: handle a non existent client ID");
                }

                return .{
                    .rc = @intCast(s.buf.len),
                    .usr_data = req.usr_data,
                };
            },
        }
    }
};

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
    const Shot = enum { multi, one };

    pub const T = struct {
        op: union(enum) {
            accept: struct { fd: Sock.Server },
            recv: struct { fd: Sock.Client, buf: []u8 },
            send: struct { fd: Sock.Client, buf: []const u8 },
        },
        shot: Shot,
        usr_data: u64,
    };

    pub const oneshot = struct {
        pub fn send(usr_data: u64, fd: Sock.Client, buf: []const u8) T {
            return .{
                .op = .{ .send = .{ .fd = fd, .buf = buf } },
                .shot = .one,
                .usr_data = usr_data,
            };
        }

        pub fn provide_buffers(recv_buf: []u8) T {
            _ = recv_buf;
            @panic("TODO!");
        }
    };

    pub const multishot = struct {
        pub fn accept(usr_data: u64, fd: Sock.Server) T {
            return .{
                .op = .{ .accept = .{ .fd = fd } },
                .shot = .multi,
                .usr_data = usr_data,
            };
        }

        pub fn recv(usr_data: u64, fd: Sock.Client, buf: []u8) T {
            return .{
                .op = .{ .recv = .{ .fd = fd, .buf = buf } },
                .shot = .multi,
                .usr_data = usr_data,
            };
        }
    };
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

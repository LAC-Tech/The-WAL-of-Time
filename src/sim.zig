//! Simulated Async IO, for use with Deterministic Simulation Testing

const std = @import("std");
const debug = std.debug;
const math = std.math;
const mem = std.mem;
const testing = std.testing;

pub const FD = @import("./fd.zig").module(u8);
const util = @import("./util.zig");

const Rng = std.Random.DefaultPrng;

const config = struct {
    const exec_delay = RandRange(u64).init(1, 10);
    const user_delay = RandRange(u64).init(1, 5);
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

pub const AsyncIO = struct {
    const Submitted = TickQueue(Req.T, 8);
    const Completed = TickQueue(FD.IORes, 8);

    // Makes things easier, but a bit artifical
    const max_clients = std.math.maxInt(FD.Int);
    const ClientFDs = std.bit_set.StaticBitSet(max_clients);

    sq: Submitted,
    cq: Completed,
    socket_fd: FD.ServerSock.T,
    rng: *Rng,
    ticks: *const u64,
    client_fds: ClientFDs,

    pub fn init(
        rng: *Rng,
        ticks: *const u64,
    ) !@This() {
        return .{
            .sq = try Submitted.init(),
            .cq = try Completed.init(),
            .socket_fd = @enumFromInt(rng.random().int(FD.Int)),
            .rng = rng,
            .ticks = ticks,
            .client_fds = ClientFDs.initEmpty(),
        };
    }

    /// Number of entries submitted
    pub fn send(self: *@This(), reqs: []const Req.T) !u32 {
        for (reqs) |r| {
            try self.sq.insert(
                r,
                self.ticks.* + config.exec_delay.gen(self.rng),
            );
        }

        return @intCast(reqs.len);
    }

    pub fn tick(self: *@This()) !?FD.IORes {
        if (self.sq.pop(self.ticks)) |req| {
            const res = try self.exec(req);

            try self.cq.insert(
                res,
                self.ticks.* + config.user_delay.gen(self.rng),
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
                debug.print("client fd = {}\n", .{fd});
                debug.print("max clients = {}\n", .{max_clients});
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
                    .rc = @intCast(r.buf.len),
                    .usr_data = r.usr_data,
                };
            },
            .send => |s| {
                const fd = @intFromEnum(s.fd);
                if (!self.client_fds.isSet(fd)) {
                    @panic("send: handle a non existent client ID");
                }

                return .{
                    .rc = @intCast(s.buf.len),
                    .usr_data = s.usr_data,
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

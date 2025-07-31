const std = @import("std");
const ArrayList = std.ArrayListUnmanaged;
const debug = std.debug;
const Rng = std.Random.DefaultPrng;
const mem = std.mem;
const Random = std.Random;
const testing = std.testing;

pub const ClientID = u8;
pub const Limits = struct { max_client_conns: u8, max_io_reqs: u8 };

test "gracefully handles the maximum number of client connections being reached" {
    const FD = u32;
    const os = msg.os(FD);

    var rng = Rng.init(testing.random_seed);

    const limits = Limits{
        .max_client_conns = rng.random().int(u8),
        .max_io_reqs = 1,
    };

    var sm = try StateMachine(FD).init(testing.allocator, limits);
    defer sm.deinit(testing.allocator);

    for (0..limits.max_client_conns) |i| {
        const fd = rng.random().int(FD);
        const actual_reqs = try sm.transition(
            .{ .rc = fd, .req = .accept_client_conn },
        );

        const expected_client_id: ClientID = @intCast(i);

        try testing.expectEqualSlices(
            os.Req,
            &.{.{ .send_conn_ack = expected_client_id }},
            actual_reqs,
        );
    }

    const actual_reqs = try sm.transition(
        .{ .rc = testing.random_seed, .req = .accept_client_conn },
    );

    try testing.expectEqualSlices(
        os.Req,
        &.{.{ .send_conn_refused = .max_clients }},
        actual_reqs,
    );
}

/// Deterministic, in-memory state machine that keeps track of things while the
/// node is running.
pub fn StateMachine(comptime FD: type) type {
    const os = msg.os(FD);

    return struct {
        os_req_buf: ArrayList(os.Req),

        // Having limits be a run time parameter lets us load them from config
        // It also let's use randomly genearate limits in tests
        fn init(allocator: mem.Allocator, limits: Limits) !@This() {
            return .{
                .os_req_buf = ArrayList(os.Req).fromOwnedSlice(
                    try allocator.alloc(os.Req, limits.max_io_reqs),
                ),
            };
        }

        fn deinit(self: *@This(), allocator: mem.Allocator) void {
            self.os_req_buf.deinit(allocator);
        }

        /// State Machine Transition Function
        /// After the OS respondes with information about an action that's been
        /// completed, the state machine,fs calculates what to request from the
        /// OS.
        /// Note: the return value is only valid until the next time the
        /// function is called.
        fn transition(self: *@This(), res: os.Res) ![]const os.Req {
            self.os_req_buf.clearRetainingCapacity();
            switch (res.req) {
                .accept_client_conn => {
                    self.os_req_buf.appendAssumeCapacity(
                        .{ .send_conn_refused = .max_clients },
                    );
                },
                else => @panic("TODO"),
            }

            return self.os_req_buf.items;
        }
    };
}

const msg = struct {
    pub fn os(comptime FD: type) type {
        return struct {
            pub const Socket = struct {
                pub const Client = enum(FD) { _ };
                pub const Server = enum(FD) { _ };

                pub fn client_eql(a: Client, b: Client) bool {
                    return std.meta.eql(a, b);
                }
            };

            const Req = union(enum) {
                /// Recurring request that accepts incoming client connection
                accept_client_conn,
                /// A new a connection has been created OR a connection already
                /// existed.
                // TODO: distinquish between those cases?
                send_conn_ack: ClientID,
                /// State machine refuses a new connection
                send_conn_refused: enum { max_clients },
            };

            pub const Res = struct { rc: FD, req: Req };
        };
    }
};

//const BoundedArray = std.BoundedArray;
//const mem = std.mem;
//
//const msg = @import("./msg.zig");
//const util = @import("./util.zig");
//
//const config = struct {
//    const max_io_req: usize = 2;
//};
//
///// Deterministic, in-memory state machine that keeps track of things while the
///// node is running
//pub fn StateMachine(
//    comptime FD: type,
//    comptime limits: struct { max_clients: usize, write_buf_size: usize },
//) type {
//    comptime {
//        // Make sure it fits in the slot map
//        debug.assert(256 > limits.max_clients);
//    }
//
//    const os = msg.os(FD);
//
//    return struct {
//        const ClientSockets = util.SlotMap(
//            os.Socket.Client,
//            os.Socket.client_eql,
//            limits.max_clients,
//            .{ .duplicates = false },
//        );
//
//        client_sockets: ClientSockets,
//        recv_buf: []u8,
//        os_req_buf: BoundedArray(msg.os.Request(FD), config.max_io_req),
//
//        pub fn init(allocator: mem.Allocator) !@This() {
//            return .{
//                .client_sockets = try ClientSockets.init(allocator),
//                // TODO: one of these per client? they can be overwritten
//                .recv_buf = try allocator.alloc(u8, limits.write_buf_size),
//                .os_req_buf = try BoundedArray(
//                    os.Request(FD),
//                    config.max_io_req,
//                ).init(0),
//            };
//        }
//
//        pub fn deinit(self: *@This(), allocator: mem.Allocator) void {
//            self.client_sockets.deinit(allocator);
//            allocator.free(self.recv_buf);
//        }
//
//        /// State Machine Transition Function
//        /// After the OS respondes with information about an action that's been
//        /// completed, the state machine,fs calculates what to request from the
//        /// OS.
//        /// Note: the return value is only valid until the next time the
//        /// function is called.
//        pub fn transition(
//            self: *@This(),
//            response: os.Response
//        ) ![]const os.Request {
//            self.os_req_buf.clear();
//
//            switch (res_ud.op) {
//                .accept_client_conn => {
//                    debug.print("accept client conn\n", .{});
//                    const fd: os.Socket.Client = @enumFromInt(response.rc);
//
//                    if (self.client_sockets.add(fd)) |client_id| {
//                        try self.enqueue_os_send_req(
//                            fd,
//                            .{ .op = .send_conn_ack, .client_id = client_id },
//                            "connection acknowledged\n",
//                        );
//                    } else |err| switch (err) {
//                        error.Duplicate => {
//                            try self.enqueue_os_send_req(
//                                fd,
//                                .{ .op = .send_no_new_conn },
//                                "client already connected\n",
//                            );
//                        },
//                        error.Overflow => {
//                            try self.enqueue_os_send_req(
//                                fd,
//                                .{ .op = .send_no_new_conn },
//                                "err: maximum connections reached\n",
//                            );
//                        },
//                    }
//                },
//                .send_conn_ack => {
//                    debug.print("send conn ack\n", .{});
//                    res_ud.op = .recv;
//                    const os_req = OSRequest.multishot.recv(
//                        res_ud.to_u64(),
//                        self.client_sockets.get(res_ud.client_id).?,
//                        self.recv_buf,
//                    );
//
//                    try self.os_req_buf.append(.{
//                        .
//                    });
//                },
//                .send_no_new_conn => {
//                    @panic("TODO: handle this case");
//                },
//                // TODO: this just puts the req on the ring again...
//                .recv => {
//                    debug.print("recv\n", .{});
//                    const buf_len: usize = @intCast(response.rc);
//                    debug.print("Client {d} sent {s}", .{
//                        res_ud.client_id,
//                        self.recv_buf[0..buf_len],
//                    });
//
//                    //const os_req = OSRequest.recv(
//                    //    res_ud.to_u64(),
//                    //    self.client_sockets.get(res_ud.client_id).?,
//                    //    self.recv_buf,
//                    //);
//
//                    //try self.os_req_buf.append(os_req);
//                },
//            }
//
//            return self.os_req_buf.constSlice();
//        }
//
//        fn enqueue_os_send_req(
//            self: *@This(),
//            fd: Socket(FD).Client,
//            ud: UsrData,
//            msg: []const u8,
//        ) !void {
//            const os_req = OSRequest.oneshot.send(@bitCast(ud), fd, msg);
//            try self.os_req_buf.append(os_req);
//        }
//    };
//}
//
//

const std = @import("std");
const ArrayList = std.ArrayListUnmanaged;
const debug = std.debug;
const Rng = std.Random.DefaultPrng;
const math = std.math;
const mem = std.mem;
const meta = std.meta;
const Random = std.Random;
const testing = std.testing;

const util = @import("util.zig");

pub const ClientID = u8;
pub const TopicID = u8;

pub const Limits = struct {
    max_client_conns: u8,
    // TODO: this can be worked out statically?
    max_io_reqs: u8,
};

test "gracefully handles the max number of client connections being reached" {
    const FD = u8; // small int to trigger duplicates
    const os = msg.os(FD);

    var rng = Rng.init(testing.random_seed);

    const limits = Limits{
        .max_client_conns = rng.random().int(u8),
        .max_io_reqs = 1,
    };

    var sm = try StateMachine(FD).init(testing.allocator, limits);
    defer sm.deinit(testing.allocator);

    var conns_made: usize = 0;
    while (limits.max_client_conns > conns_made) {
        const actual_reqs = try sm.transition(.{
            // This allows maxInt to used for an FD that won't be there
            .rc = rng.random().intRangeLessThan(FD, 0, math.maxInt(FD)),
            .req = .accept_client_conn,
        });

        try testing.expectEqual(actual_reqs.len, 1);
        const actual: meta.Tag(os.Req) = meta.activeTag(actual_reqs[0]);

        switch (actual) {
            .send_conn_reused => {},
            .send_conn_ack => {
                conns_made += 1;
            },
            else => @panic("failed to make a connection"),
        }
    }

    const actual_reqs = try sm.transition(
        .{ .rc = math.maxInt(FD), .req = .accept_client_conn },
    );

    try testing.expectEqualSlices(
        os.Req,
        &.{.{ .send_conn_rejected = .max_clients }},
        actual_reqs,
    );
}

/// Deterministic, in-memory state machine that keeps track of things while the
/// node is running.
pub fn StateMachine(comptime FD: type) type {
    const os = msg.os(FD);
    const ClientIDs = util.SlotMap(
        os.Socket.Client,
        os.Socket.client_eql,
        .{ .duplicates = false },
    );

    return struct {
        os_req_buf: ArrayList(os.Req),
        client_sockets: ClientIDs,

        // Having limits be a run time parameter lets us load them from config
        // It also let's use randomly genearate limits in tests
        fn init(allocator: mem.Allocator, limits: Limits) !@This() {
            return .{
                .os_req_buf = ArrayList(os.Req).fromOwnedSlice(
                    try allocator.alloc(os.Req, limits.max_io_reqs),
                ),
                .client_sockets = try ClientIDs.init(
                    allocator,
                    limits.max_client_conns,
                ),
            };
        }

        fn deinit(self: *@This(), allocator: mem.Allocator) void {
            self.os_req_buf.deinit(allocator);
            self.client_sockets.deinit(allocator);
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
                    const fd: os.Socket.Client = @enumFromInt(res.rc);

                    if (self.client_sockets.add(fd)) |add_res| {
                        const client_id = add_res.slot;
                        const os_req: os.Req = if (add_res.existed)
                            .{ .send_conn_reused = client_id }
                        else
                            .{ .send_conn_ack = client_id };

                        self.enqueue_os_req(os_req);
                    } else |err| switch (err) {
                        error.Overflow => {
                            self.enqueue_os_req(
                                .{ .send_conn_rejected = .max_clients },
                            );
                        },
                    }
                },

                else => @panic("TODO"),
            }

            return self.os_req_buf.items;
        }

        // TODO: use this to translate to OS specific stuff on the fly?
        // ie io_uring_sqe
        fn enqueue_os_req(self: *@This(), req: os.Req) void {
            self.os_req_buf.appendAssumeCapacity(req);
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

            pub const File = enum(FD) { _ };

            const Req = union(enum) {
                /// Recurring request that accepts incoming client connection
                accept_client_conn,
                /// A new a connection has been created
                send_conn_ack: ClientID,
                /// A connection already existed and we're re-using it
                send_conn_reused: ClientID,
                /// The client is unable to connect
                send_conn_rejected: enum { max_clients },
                recv_topic_create: []const u8,
                send_topic_created: TopicID,
                recv_topic_delete: TopicID,
                send_topic_delete: TopicID,
            };

            pub const Res = struct { rc: FD, req: Req };
        };
    }
};

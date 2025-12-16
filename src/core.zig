const std = @import("std");
const debug = std.debug;
const Rng = std.Random.DefaultPrng;
const math = std.math;
const mem = std.mem;
const meta = std.meta;
const Random = std.Random;
const testing = std.testing;

const msg = @import("msg.zig");
const local_io = msg.local_io;
const util = @import("./util.zig");

/// Deterministic, in-memory state machine that keeps track of things while the
/// node is running.
pub const StateMachine = struct {
    bufs: util.SlotMap(u256, std.meta.eql, .{ .duplicates = false }),

    /// State Machine Transition Function
    /// After the OS respondes with information about an action that's been
    /// completed, the state machine calculates what to request from the OS.
    pub fn transition(res: local_io.Res) !local_io.Req {
        switch (res.req) {
            .accept_client_conn => |client_id_or_err| {
                if (client_id_or_err) |client_id| {
                    return .{ .send_conn_ack = client_id };
                } else |err| {
                    return .{ .send_conn_rejected = err };
                }
            },

            else => @panic("TODO"),
        }
    }
};

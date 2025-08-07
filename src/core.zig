const std = @import("std");
//const ArrayList = std.ArrayListUnmanaged;
const BoundedArray = std.BoundedArray;
const debug = std.debug;
const Rng = std.Random.DefaultPrng;
const math = std.math;
const mem = std.mem;
const meta = std.meta;
const Random = std.Random;
const testing = std.testing;

const msg = @import("msg.zig");
const local_io = msg.local_io;

test "sanity" {
    _ = try StateMachine.init();
}

/// Deterministic, in-memory state machine that keeps track of things while the
/// node is running.
pub const StateMachine = struct {
    // I believe the capacity can be statically determined
    local_io_req_buf: BoundedArray(msg.local_io.Req, 1),

    pub fn init() !@This() {
        return .{
            .local_io_req_buf = try BoundedArray(local_io.Req, 1).init(0),
        };
    }

    /// State Machine Transition Function
    /// After the OS respondes with information about an action that's been
    /// completed, the state machine,fs calculates what to request from the
    /// OS.
    /// Note: the return value is only valid until the next time the
    /// function is called.
    pub fn transition(self: *@This(), res: local_io.Res) ![]const local_io.Req {
        self.local_io_req_buf.clearRetainingCapacity();
        switch (res.req) {
            .accept_client_conn => |client_id_or_err| {
                if (client_id_or_err) |client_id| {
                    self.enqueue_os_req(.{ .send_conn_ack = client_id });
                } else |err| {
                    self.enqueue_os_req(.{ .send_conn_rejected = err });
                }
            },

            else => @panic("TODO"),
        }

        return self.local_io_req_buf.items;
    }

    // ie io_uring_sqe
    fn enqueue_os_req(self: *@This(), req: local_io.Req) void {
        self.local_io_req_buf.appendAssumeCapacity(req);
    }
};

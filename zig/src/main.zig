const std = @import("std");
const debug = std.debug;
const heap = std.heap;
const math = std.math;
const mem = std.mem;
const meta = std.meta;
const posix = std.posix;
const Random = std.Random;
const testing = std.testing;

const config = @import("./config.zig");

const os_msg = @import("os_msg.zig");
const linux = @import("linux.zig");

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var aio = try linux.AsyncIO.init(allocator);
    defer aio.deinit(allocator);

    const server_fd = try linux.init_server_fd();
    debug.print("Listening on port {d}\n", .{config.port});

    try aio.accept(server_fd, os_msg.accept());

    while (true) {
        _ = try aio.submit();
        const cqe = try aio.waitForReq();
        const user_data = os_msg.fromUserData(cqe.user_data);

        switch (user_data.syscall) {
            .accept => {
                const client_fd = cqe.res;
                try aio.recv(os_msg.recv(client_fd));

                // Multishot accept continues while MORE flag is set
                if ((cqe.flags & std.os.linux.IORING_CQE_F_MORE) == 0) {
                    // Accept multishot ended (no MORE flag) - restart it
                    debug.print("accept multishot ended, restarting\n", .{});
                    try aio.accept(server_fd, os_msg.accept());
                }
            },
            .recv => {
                const msg = user_data.payload.recv;
                const buf_id =
                    cqe.flags >> std.os.linux.IORING_CQE_BUFFER_SHIFT;

                if (0 > cqe.res) {
                    // Error occurred - always release the buffer first
                    aio.release_buf(buf_id);

                    debug.print(
                        "recv error on fd {d}: {d}\n",
                        .{ msg.client_fd, -cqe.res },
                    );

                    // If multishot is done (no MORE flag), close socket
                    if ((cqe.flags & std.os.linux.IORING_CQE_F_MORE) == 0) {
                        posix.close(msg.client_fd);
                    }
                } else if (cqe.res == 0) {
                    // Orderly shutdown by client
                    aio.release_buf(buf_id);

                    // If multishot is done (no MORE flag), close socket
                    if ((cqe.flags & std.os.linux.IORING_CQE_F_MORE) == 0) {
                        posix.close(msg.client_fd);
                    }
                } else {
                    // Received actual data! Echo it back
                    const len: usize = @intCast(cqe.res);

                    try aio.send(msg.client_fd, len, os_msg.send(buf_id));
                }
            },
            .send => {
                const msg = user_data.payload.send;
                // This is a send completion - return buffer
                aio.release_buf(msg.buf_id);
            },
        }
    }
}
test {
    @import("std").testing.refAllDecls(@This());
}

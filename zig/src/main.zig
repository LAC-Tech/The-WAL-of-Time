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

const core = @import("core.zig");
const os = @import("os.zig");
const linux = @import("linux.zig");

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const state = try core.State.init(allocator);
    defer state.deinit(allocator);

    var aio = try linux.AsyncIO.init(state.buffers);
    defer aio.deinit();

    const server_fd = try linux.initServerFd();
    debug.print("Listening on port {d}\n", .{config.port});

    try aio.accept(server_fd, os.UserData.accept());

    while (true) {
        _ = try aio.submit();
        const res = try aio.waitForRes();
        const user_data = res.user_data;

        switch (user_data.syscall) {
            .accept => {
                const client_fd = res.syscall_result;

                try aio.recv(os.UserData.recv(client_fd));

                if (res.restart_needed) {
                    debug.print("accept multishot ended, restarting\n", .{});
                    try aio.accept(server_fd, os.UserData.accept());
                }
            },
            .recv => {
                const client_fd = user_data.msg.recv.client_fd;

                if (res.syscall_result > 0) {
                    const len: usize = @intCast(res.syscall_result);
                    const buf = state.buffers[res.buf_id][0..len];
                    const msg = os.UserData.send(res.buf_id);

                    try aio.send(client_fd, buf, msg);

                    if (res.restart_needed) {
                        try aio.recv(os.UserData.recv(client_fd));
                    }
                } else if (res.syscall_result == 0) {
                    aio.release_buf(res.buf_id, state.buffers);
                    debug.print(
                        "client fd {d} disconnected\n",
                        .{client_fd},
                    );

                    if (res.restart_needed) {
                        posix.close(client_fd);
                    }
                } else {
                    aio.release_buf(res.buf_id, state.buffers);
                    const err_code = -res.syscall_result;
                    debug.print(
                        "recv error on fd {d}: {d}\n",
                        .{ client_fd, err_code },
                    );

                    if (res.restart_needed) {
                        posix.close(client_fd);
                    }
                }
            },
            .send => {
                const buf_id = user_data.msg.send.buf_id;
                aio.release_buf(buf_id, state.buffers);
            },
        }
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}

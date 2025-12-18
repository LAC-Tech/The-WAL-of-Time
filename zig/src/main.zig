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

const os = @import("os.zig");
const linux = @import("linux.zig");

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var aio = try linux.AsyncIO.init(allocator);
    defer aio.deinit(allocator);

    const server_fd = try linux.initServerFd();
    debug.print("Listening on port {d}\n", .{config.port});

    try aio.accept(server_fd, os.UserData.accept());

    while (true) {
        _ = try aio.submit();
        const res = try aio.waitForRes();

        switch (res.user_data.syscall) {
            .accept => {
                const client_fd = res.syscall_res;

                try aio.recv(os.UserData.recv(client_fd));

                if (res.restart_needed) {
                    debug.print("accept multishot ended, restarting\n", .{});
                    try aio.accept(
                        server_fd,
                        os.UserData.accept(),
                    );
                }
            },

            .recv => {
                if (res.syscall_res > 0) {
                    const len: usize = @intCast(res.syscall_res);
                    try aio.send(
                        res.user_data.msg.recv.client_fd,
                        len,
                        os.UserData.send(res.buf_id),
                    );

                    if (res.restart_needed) {
                        try aio.recv(
                            os.UserData.recv(res.user_data.msg.recv.client_fd),
                        );
                    }
                } else if (res.syscall_res == 0) {
                    aio.release_buf(res.buf_id);
                    debug.print(
                        "client fd {d} disconnected\n",
                        .{res.user_data.msg.recv.client_fd},
                    );

                    if (res.restart_needed) {
                        posix.close(res.user_data.msg.recv.client_fd);
                    }
                } else {
                    aio.release_buf(res.buf_id);
                    const err_code = -res.syscall_res;
                    debug.print(
                        "recv error on fd {d}: {d}\n",
                        .{ res.user_data.msg.recv.client_fd, err_code },
                    );

                    if (res.restart_needed) {
                        posix.close(res.user_data.msg.recv.client_fd);
                    }
                }
            },

            .send => {
                aio.release_buf(res.user_data.msg.send.buf_id);
            },
        }
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}

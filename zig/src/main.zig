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
        const cqe = try aio.waitForReq();

        switch (linux.resFromCqe(cqe)) {
            .accept_data => |res| {
                try aio.recv(os.UserData.recv(res.client_fd));

                if (res.restart_needed) {
                    debug.print("accept multishot ended, restarting\n", .{});
                    try aio.accept(
                        server_fd,
                        os.UserData.accept(),
                    );
                }
            },

            .recv => |res| {
                switch (res.result) {
                    .data => |len| {
                        try aio.send(
                            res.client_fd,
                            len,
                            os.UserData.send(res.buf_id),
                        );

                        if (res.restart_needed) {
                            try aio.recv(
                                os.UserData.recv(res.client_fd),
                            );
                        }
                    },

                    .error_code => |err_code| {
                        aio.release_buf(res.buf_id);
                        debug.print(
                            "recv error on fd {d}: {d}\n",
                            .{ res.client_fd, err_code },
                        );

                        if (res.restart_needed) {
                            posix.close(res.client_fd);
                        }
                    },

                    .disconnect => {
                        aio.release_buf(res.buf_id);
                        debug.print(
                            "client fd {d} disconnected\n",
                            .{res.client_fd},
                        );

                        if (res.restart_needed) {
                            posix.close(res.client_fd);
                        }
                    },
                }
            },

            .send_complete => |data| {
                aio.release_buf(data.buf_id);
            },
        }
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}

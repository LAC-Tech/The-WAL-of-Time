const std = @import("std");
const io = std.io;
const mem = std.mem;
const os = std.os;
const posix = std.posix;

const config = struct {
    const max_input: usize = 256;
};

pub fn main() !void {
    const stdout = io.getStdOut().writer();
    const stdin = io.getStdIn().reader();
    var input_buf: [config.max_input]u8 = .{0} ** config.max_input;

    while (true) {
        try stdout.print("> ", .{});
        const input = try stdin.readUntilDelimiter(&input_buf, '\n');

        if (mem.eql(u8, input, "q")) {
            break;
        }
        try stdout.print("{s}\n", .{input});
    }
}

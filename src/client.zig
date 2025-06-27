const std = @import("std");

const debug = std.debug;
const io = std.io;
const fmt = std.fmt;
const mem = std.mem;
const net = std.net;
const process = std.process;

const usage = "Usage: <program> <address> <port>\n";

pub fn main() !void {
    var args = process.args();
    _ = args.skip();

    const addr_str = args.next() orelse {
        debug.print("{s}", .{usage});
        process.exit(1);
    };
    const port_str = args.next() orelse {
        debug.print("{s}", .{usage});
        process.exit(1);
    };

    const addr = try net.Address.parseIp(
        addr_str,
        try fmt.parseInt(u16, port_str, 10),
    );
    const stream = try net.tcpConnectToAddress(addr);
    defer stream.close();

    var bw = io.bufferedWriter(stream.writer());
    const writer = bw.writer();
    const stdin = io.getStdIn().reader();
    var buf: [1024]u8 = undefined;

    while (true) {
        debug.print("Enter message (or 'quit' to exit): ", .{});
        const input = try stdin.readUntilDelimiterOrEof(&buf, '\n') orelse break;
        if (mem.eql(u8, input, "quit")) break;

        try writer.writeAll(input);
        try writer.writeByte('\n');
        try bw.flush();

        var read_buf: [1024]u8 = undefined;
        const read_len = try stream.read(&read_buf);
        if (read_len == 0) break;
        debug.print("Server response: {s}\n", .{read_buf[0..read_len]});
    }
}

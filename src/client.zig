const std = @import("std");
const io = std.io;
const os = std.os;
const posix = std.posix;

const esc = "\x1B[";
const set_scroll_region = esc ++ "5;20r";
const move_cursor_top = esc ++ "5H";
const reset_scroll_region = esc ++ "r";
const clear_screen = esc ++ "2J";

pub fn main() !void {
    const stdout = io.getStdOut().writer();
    const stdin = io.getStdIn().reader();

    _ = try stdout.write(clear_screen);
    _ = try stdout.write(set_scroll_region);
    _ = try stdout.write(move_cursor_top);

    var i: usize = 0;
    while (i < 30) : (i += 1) {
        _ = try stdout.print("Line {}\n", .{i});
    }

    _ = try stdout.write(reset_scroll_region);
    _ = try stdin.readByte();
}

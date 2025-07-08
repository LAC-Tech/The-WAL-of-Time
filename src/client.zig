const std = @import("std");
const c = @cImport({
    @cInclude("ncurses.h");
});

const visible_lines: u32 = 14;
const total_lines: u32 = 30;

pub fn main() !void {
    _ = c.initscr();
    defer _ = c.endwin();
    _ = c.cbreak();
    _ = c.noecho();
    _ = c.keypad(c.stdscr, true);

    const pad = c.newpad(total_lines, 80) orelse unreachable;

    // Fill pad with content
    for (0..total_lines) |i| {
        _ = c.mvwprintw(pad, @intCast(i), 1, "Line %d", i);
    }

    var scroll_offset: u32 = 0;
    _ = c.prefresh(pad, @intCast(scroll_offset), 0, 5, 0, @intCast(5 + visible_lines), 79);

    while (true) {
        switch (c.getch()) {
            'q' => break,
            'j' => {
                if (scroll_offset + visible_lines < total_lines) {
                    scroll_offset += 1;
                    _ = c.prefresh(pad, @intCast(scroll_offset), 0, 5, 0, @intCast(5 + visible_lines), 79);
                }
            },
            'k' => {
                if (scroll_offset > 0) {
                    scroll_offset -= 1;
                    _ = c.prefresh(pad, @intCast(scroll_offset), 0, 5, 0, @intCast(5 + visible_lines), 79);
                }
            },
            else => {},
        }
    }
}

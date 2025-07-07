const std = @import("std");
const c = @cImport({
    @cInclude("ncurses.h");
});

const visible_lines: u32 = 14;
const total_lines: u32 = 30;

fn drawContent(win: *c.WINDOW, scroll_offset: u32) void {
    _ = c.wclear(win);
    _ = c.box(win, 0, 0);

    for (0..visible_lines) |i| {
        if (scroll_offset + i >= total_lines) break;
        _ = c.mvwprintw(win, @intCast(i + 1), 1, "Line %d", scroll_offset + i);
    }

    _ = c.wrefresh(win);
}

pub fn main() !void {
    _ = c.initscr();
    _ = c.refresh();
    defer _ = c.endwin();

    _ = c.cbreak();
    _ = c.noecho();
    _ = c.keypad(c.stdscr, true);

    const win = c.newwin(16, 80, 5, 0) orelse unreachable;

    var scroll_offset: u32 = 0;

    drawContent(win, scroll_offset);

    while (true) {
        const key = c.getch();
        switch (key) {
            'q' => break,
            'j' => {
                if (scroll_offset + visible_lines < total_lines) {
                    scroll_offset += 1;
                    drawContent(win, scroll_offset);
                }
            },
            'k' => {
                if (scroll_offset > 0) {
                    scroll_offset -= 1;
                    drawContent(win, scroll_offset);
                }
            },
            else => {},
        }
    }
}

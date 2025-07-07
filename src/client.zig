const std = @import("std");
const c = @cImport({
    @cInclude("ncurses.h");
});

fn drawContent(win: *c.WINDOW, scroll_offset: i32, total_lines: i32, visible_lines: i32) void {
    _ = c.wclear(win);
    _ = c.box(win, 0, 0);

    var i: i32 = 0;
    while (i < visible_lines and (scroll_offset + i) < total_lines) : (i += 1) {
        _ = c.mvwprintw(win, i + 1, 1, "Line %d", scroll_offset + i);
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

    var scroll_offset: i32 = 0;
    const total_lines: i32 = 30;
    const visible_lines: i32 = 14;

    drawContent(win, scroll_offset, total_lines, visible_lines);

    while (true) {
        const key = c.getch();
        switch (key) {
            'q' => break,
            'j' => {
                if (scroll_offset + visible_lines < total_lines) {
                    scroll_offset += 1;
                    drawContent(win, scroll_offset, total_lines, visible_lines);
                }
            },
            'k' => {
                if (scroll_offset > 0) {
                    scroll_offset -= 1;
                    drawContent(win, scroll_offset, total_lines, visible_lines);
                }
            },
            else => {},
        }
    }
}

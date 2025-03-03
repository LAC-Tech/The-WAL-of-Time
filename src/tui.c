#include "tui.h"
#include <locale.h>
#include <ncurses.h>
#include <stdio.h>
#include <stdlib.h>
#include <termios.h>
#include <unistd.h>

void tui_init(tui* tui) {
    setlocale(LC_ALL, "");
    initscr();
    raw();
    noecho();
    keypad(stdscr, TRUE); // Enable special keys
    getmaxyx(stdscr, tui->height, tui->width);

    tui->win = stdscr; // Use stdscr as main window
    tui->title_win = newwin(1, tui->width, 0, 0);
    tui->stats_win = newwin(8, tui->width, 1, 0);

    // Title styling
    wattron(tui->title_win, A_BOLD);
    wcolor_set(tui->title_win, 1, NULL); // White on black (pair 1)
    wbkgd(tui->title_win, COLOR_PAIR(1));
    mvwprintw(tui->title_win, 0, 1, " Deterministic Simulation Tester ");

    // Stats styling and border
    wcolor_set(tui->stats_win, 2, NULL); // Black on white (pair 2)
    wbkgd(tui->stats_win, COLOR_PAIR(2));
    wborder(tui->stats_win, ACS_VLINE, ACS_VLINE, ACS_HLINE, ACS_HLINE, 
            ACS_ULCORNER, ACS_URCORNER, ACS_LLCORNER, ACS_LRCORNER);


    wattron(tui->stats_win, A_BOLD);
    mvwprintw(tui->stats_win, 1, 1, "User Stats");
    wattroff(tui->stats_win, A_BOLD);
    mvwprintw(tui->stats_win, 2, 1, "Streams Created: ");
    mvwprintw(tui->stats_win, 3, 1, "Streams Name Duplicates: ");
    mvwprintw(tui->stats_win, 4, 1, "Pending Stream Name Limit Reached: ");
    wattron(tui->stats_win, A_BOLD);
    mvwprintw(tui->stats_win, 5, 1, "OS Stats");
    wattroff(tui->stats_win, A_BOLD);
    mvwprintw(tui->stats_win, 6, 1, "Files Created:");
}

void tui_deinit(tui* ctx) {
    delwin(ctx->title_win);
    delwin(ctx->stats_win);
    endwin();
}

bool tui_tick(tui* tui, os_stats* os_stats, usr_stats* usr_stats, uint64_t time_in_ms) {
    nodelay(stdscr, TRUE); // Non-blocking input
    int key = getch();     // Check for input
    nodelay(stdscr, FALSE); // Switch back to blocking for pause

    if (key == 'q') {
        return false;
    } else if (key == ' ') {
        refresh();
        tcflush(0, TCIFLUSH);  // Flush input buffer (stdin FD = 0)
        curs_set(0);
        getch();               // Block until any key is pressed
        curs_set(1);
        refresh();
        return true;
    }

    // Time display
    uint64_t seconds_total = time_in_ms / 1000;
    uint64_t hours = seconds_total / 3600;
    uint64_t minutes = (seconds_total % 3600) / 60;
    hours = hours % 24;
    mvwprintw(tui->title_win, 0, tui->width - 8, " %02lu:%02lu ", hours, minutes);
    wrefresh(tui->title_win);

    // Stats display
    int x_offset = 64;
    mvwprintw(
            tui->stats_win, 
            2, 
            x_offset, 
            "%08lx",
            usr_stats->streams_created);
    mvwprintw(
            tui->stats_win,
            3,
            x_offset,
            "%08lx",
            usr_stats->stream_name_duplicates);
    mvwprintw(
            tui->stats_win, 
            4, 
            x_offset, 
            "%08lx",
            usr_stats->stream_name_reservation_limit_exceeded);
    mvwprintw(tui->stats_win, 6, x_offset, "%08lx", os_stats->files_created);
    wrefresh(tui->stats_win);
    wrefresh(tui->title_win);

    return true;
}

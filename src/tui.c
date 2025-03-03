#include "tui.h"
#include <locale.h>
#include <stdio.h>
#include <termios.h>
#include <unistd.h>

void tui_init(tui* ctx) {
    setlocale(LC_ALL, "");
    initscr();
    raw();
    noecho();
    keypad(stdscr, TRUE); // Enable special keys
    getmaxyx(stdscr, ctx->height, ctx->width);

    ctx->win = stdscr; // Use stdscr as main window
    ctx->title_win = newwin(1, ctx->width, 0, 0);
    ctx->stats_win = newwin(8, ctx->width, 1, 0);

    // Title styling
    wattron(ctx->title_win, A_BOLD);
    wcolor_set(ctx->title_win, 1, NULL); // White on black (pair 1)
    wbkgd(ctx->title_win, COLOR_PAIR(1));
    mvwprintw(ctx->title_win, 0, 1, " Deterministic Simulation Tester ");
    wrefresh(ctx->title_win);

    // Stats styling and border
    wcolor_set(ctx->stats_win, 2, NULL); // Black on white (pair 2)
    wbkgd(ctx->stats_win, COLOR_PAIR(2));
    wborder(ctx->stats_win, ACS_VLINE, ACS_VLINE, ACS_HLINE, ACS_HLINE, 
            ACS_ULCORNER, ACS_URCORNER, ACS_LLCORNER, ACS_LRCORNER);
    wrefresh(ctx->stats_win);

    // Initialize color pairs
    start_color();
    init_pair(1, COLOR_WHITE, COLOR_BLACK); // Title: white on black
    init_pair(2, COLOR_BLACK, COLOR_WHITE); // Stats: black on white
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
        printw("Paused\n");    // Print to stdscr
        refresh();
        tcflush(0, TCIFLUSH);  // Flush input buffer (stdin FD = 0)
        getch();               // Block until any key is pressed
        printw("Un-Paused\n");
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
    int center = tui->width / 2 - 10;
    mvwprintw(tui->stats_win, 1, center, "User Stats");
    mvwprintw(
            tui->stats_win,
            2,
            center,
            "* Streams Created = %lu", usr_stats->streams_created);
    mvwprintw(
            tui->stats_win,
            3, center,
            "* Streams Name Duplicates = %lu",
            usr_stats->stream_name_duplicates);
    mvwprintw(
            tui->stats_win, 
            4, 
            center, 
            "* Stream Name Reservation Limited Exceeded = %lu",
            usr_stats->stream_name_reservation_limit_exceeded);
    mvwprintw(tui->stats_win, 5, center, "OS Stats");
    mvwprintw(
            tui->stats_win,
            6,
            center,
            "Files created = %lu",
            os_stats->files_created);
    wrefresh(tui->stats_win);

    return true;
}

/*
 * Visual display for the Deterministic Simulation Tester
 * Should take in raw data, and how it's displayed (including messages) is kept
 * in here.
 *
 * Q: Why not use notcurses direclty in zig via @cImport?
 * A: The header file is too gnarly for zig to handle, hence this shim in C.
 */

#ifndef TUI_H
#define TUI_H	

#include <stdint.h>
#include <sys/types.h>

#include <ncurses.h>

typedef struct {
    WINDOW* win;
    WINDOW* title_win;
    WINDOW* stats_win;
    int width;
    int height;
} tui;

typedef struct {
    uint64_t files_created;
} os_stats;

typedef struct {
    uint64_t topics_created;
    uint64_t topic_name_duplicates;
    uint64_t topic_name_reservation_limit_exceeded;
} usr_stats;

void tui_init(tui* ctx);
void tui_deinit(tui* ctx); 

// Renders and reads key presses. Result of keypress is returned.
bool tui_tick (
        tui* ctx,
        os_stats* os_stats,
        usr_stats* usr_stats,
        uint64_t time_in_ms);

#endif // TUI_H

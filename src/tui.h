/*
 * Visual display for the Deterministic Simulation Tester
 * Should take in raw data, and how it's displayed (including messages) is kept
 * in here.
 */

#ifndef TUI_H
#define TUI_H	

#include <stdint.h>
#include <notcurses/notcurses.h>

typedef struct {
	struct notcurses* nc;
	struct ncplane* stdplane;
	struct ncplane* titleplane; 
	unsigned int width;
	unsigned int height;
} tui;

typedef struct {
    uint64_t os_files_created;
} stats;

void tui_init(tui* ctx);
void tui_deinit(tui* ctx); 
void tui_sim_render(tui* ctx, stats* stats, uint64_t time_in_ms);

#endif // TUI_H

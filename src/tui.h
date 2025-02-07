#ifndef TUI_H
#define TUI_H

#include <notcurses/notcurses.h>

typedef struct {
	struct notcurses* nc;
	struct ncplane* stdplane;
	struct ncplane* titleplane; 
	unsigned int width;
	unsigned int height;
} tui_context;

void tui_context_init(tui_context* ctx);
void tui_context_deinit(tui_context* ctx); 

#endif // TUI_H

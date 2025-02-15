#include <locale.h>
#include <notcurses/notcurses.h>

typedef struct {
	struct notcurses* nc;
	struct ncplane* stdplane;
	struct ncplane* titleplane; 
	unsigned int width;
	unsigned int height;
} tui_context;

void tui_context_init(tui_context* ctx) {
    setlocale(LC_ALL, "");
    notcurses_options ncopt = {0};

    struct notcurses* nc = notcurses_init(&ncopt, stdout);
    struct ncplane* stdplane = notcurses_stdplane(nc);
    notcurses_term_dim_yx(nc, &ctx->height, &ctx->width);

    struct ncplane_options opts = {
        .y = 0,
        .x = 0,
        .rows = 1,
        .cols = ctx->width,
        .userptr = NULL,
        .name = "topplane",
        .flags = 0
    };

    struct ncplane* titleplane = ncplane_create(stdplane, &opts);

    *ctx = (tui_context){
        .nc = nc,
        .stdplane = stdplane,
        .titleplane = titleplane,
        .width = ctx->width,
        .height = ctx->height
    };

    char* text = "Deterministic Simulation Tester";

    //ncplane_set_styles(ctx->titleplane, NCSTYLE_BOLD);
	ncplane_set_fg_rgb(ctx->titleplane, 0x000000);
	ncplane_set_bg_rgb(ctx->titleplane, 0xFFFFFF); 
    ncplane_putstr_aligned(ctx->titleplane, 0, NCALIGN_CENTER, text);

    notcurses_render(nc);
}

void tui_context_deinit(tui_context* ctx) {
	notcurses_stop(ctx->nc);
}

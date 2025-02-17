#include "tui.h"
#include <locale.h>
#include <notcurses/notcurses.h>
#include <stdint.h>

void tui_init(tui* ctx) {
    setlocale(LC_ALL, "");
    notcurses_options ncopt = {0};

    struct notcurses* nc = notcurses_core_init(&ncopt, stdout);
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

    *ctx = (tui){
        .nc = nc,
        .stdplane = stdplane,
        .titleplane = titleplane,
        .width = ctx->width,
        .height = ctx->height
    };

    char* text = " Deterministic Simulation Tester ";

    ncplane_set_styles(ctx->titleplane, NCSTYLE_BOLD);
    ncplane_set_fg_rgb(ctx->titleplane, 0xFFFFFF);
    ncplane_set_bg_rgb(ctx->titleplane, 0x000000); 
    ncplane_putstr_aligned(ctx->titleplane, 0, NCALIGN_CENTER, text);

    ncplane_perimeter_rounded(ctx->stdplane, 0, 0, 0);

    ncplane_set_fg_rgb(ctx->stdplane, 0x000000);
    ncplane_set_bg_rgb(ctx->stdplane, 0xFFFFFF); 

    notcurses_render(nc);
}

void tui_deinit(tui* ctx) {
    notcurses_stop(ctx->nc);
}

void tui_render_stats(tui* ctx, stats* stats) {
    ncplane_printf_aligned(
            ctx->stdplane, 
            ctx->height / 2, 
            NCALIGN_CENTER,
            "Files created = %ju\n",
            stats->os_files_created);
    
    notcurses_render(ctx->nc);
}

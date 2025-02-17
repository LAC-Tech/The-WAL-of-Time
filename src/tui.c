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

void tui_sim_render(tui* ctx, stats* stats, uint64_t time_in_ms) {
    uint64_t seconds_total = time_in_ms / 1000;
    uint64_t hours = seconds_total / 3600;
    uint64_t minutes = (seconds_total % 3600) / 60;
    uint64_t seconds = seconds_total % 60;

    // Ensure hours stay within 24-hour format (0-23)
    hours = hours % 24;

    ncplane_printf_aligned(
        ctx->stdplane,
        ctx->height / 2,
        NCALIGN_CENTER,
        "Files created = %ju, Time = %02ju:%02ju:%02ju",
        stats->os_files_created,
        hours, minutes, seconds
    );

    notcurses_render(ctx->nc);
}

#include "tui.h"
#include <locale.h>
#include <notcurses/notcurses.h>
#include <stdbool.h>
#include <stdint.h>

void tui_init(tui* ctx) {
    setlocale(LC_ALL, "");
    // no notcurses stats on exit
    notcurses_options ncopt = {.flags = NCOPTION_SUPPRESS_BANNERS};

    struct notcurses* nc = notcurses_core_init(&ncopt, stdout);
    struct ncplane* stdplane = notcurses_stdplane(nc);
    notcurses_term_dim_yx(nc, &ctx->height, &ctx->width);

    struct ncplane* titleplane = ncplane_create(
            stdplane, 
            &(struct ncplane_options){
                .y = 0,
                .x = 0,
                .rows = 1,
                .cols = ctx->width,
                .userptr = NULL,
                .name = "titleplane",
                .flags = 0
            });

    struct ncplane* statsplane = ncplane_create(
            stdplane, 
            &(struct ncplane_options){
                .y = 1,
                .x = 0,
                .rows = 8,
                .cols = ctx->width,
                .userptr = NULL,
                .name = "statsplane",
                .flags = 0
            });

    *ctx = (tui){
        .nc = nc,
        .titleplane = titleplane,
        .statsplane = statsplane,
        .width = ctx->width,
        .height = ctx->height,
        .paused = false,
    };

    char* text = " Deterministic Simulation Tester ";

    ncplane_set_styles(ctx->titleplane, NCSTYLE_BOLD);
    ncplane_set_fg_rgb(ctx->titleplane, 0xFFFFFF);
    ncplane_set_bg_rgb(ctx->titleplane, 0x000000); 
    ncplane_putstr_yx(ctx->titleplane, 0, 1, text);

    ncplane_perimeter_rounded(ctx->statsplane, 0, 0, 0);

    ncplane_set_fg_rgb(ctx->statsplane, 0x000000);
    ncplane_set_bg_rgb(ctx->statsplane, 0xFFFFFF); 

    notcurses_render(nc);
}

void tui_deinit(tui* ctx) {
    notcurses_stop(ctx->nc);
}

// Returns "true" if we can tick some more;
bool tui_tick(
        tui* tui,
        os_stats* os_stats,
        usr_stats* usr_stats,
        uint64_t time_in_ms
) {
    struct ncinput ni;

    if (tui->paused) {
        printf("Paused\n"); // Does this print?
        while (tui->paused) {
            notcurses_get_blocking(tui->nc, &ni);
            tui->paused = false;
            return true;
        }
    }

    uint32_t key = notcurses_get_nblock(tui->nc, &ni);
    if (key == 'q') {
        return false; 
    } else if (key == ' ') {
        tui->paused = true;
        return true;
    }

    uint64_t seconds_total = time_in_ms / 1000;
    uint64_t hours = seconds_total / 3600;
    uint64_t minutes = (seconds_total % 3600) / 60;

    // Ensure hours stay within 24-hour format (0-23)
    hours = hours % 24;

    ncplane_printf_yx(
        tui->titleplane,
        0,
        tui->width - 8, // Just like on our computers!!!
        " %02ju:%02ju ",
        hours, minutes
    );

    ncplane_printf_aligned(tui->statsplane, 1, NCALIGN_CENTER, "User Stats");

    ncplane_printf_aligned(
        tui->statsplane,
        2,
        NCALIGN_CENTER,
        "* Streams Created = %ju",
        usr_stats->streams_created
    );
    ncplane_printf_aligned(
        tui->statsplane,
        3,
        NCALIGN_CENTER,
        "* Streams Name Duplicates = %ju",
        usr_stats->stream_name_duplicates
    );
    ncplane_printf_aligned(
        tui->statsplane,
        4,
        NCALIGN_CENTER,
        "* Stream Name Reservation Limited Exceeded = %ju",
        usr_stats->stream_name_reservation_limit_exceeded
    );
    ncplane_printf_aligned(tui->statsplane, 5, NCALIGN_CENTER, "OS Stats");

    ncplane_printf_aligned(
        tui->statsplane,
        6,
        NCALIGN_CENTER,
        "Files created = %ju",
        os_stats->files_created
    );

    notcurses_render(tui->nc);
    return true;
}

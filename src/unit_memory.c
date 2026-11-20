/*
 * unit_memory.c - Memory unit: reorganize, remove outliers, summarize.
 *
 * Memory-bound by design: the working set (2 x 16 MB at the default size) is
 * much larger than the Pi's caches, and every stage streams through all of it.
 *   Stage 1  reorganize: collection order -> one contiguous series per room
 *   Stage 2  robust statistics: median and MAD per room from 0.05 C histograms
 *   Stage 3  clean + summarize: replace outliers with the last good reading
 *            (keeps the series evenly spaced in time) and build per-window
 *            min/max/mean/stddev records for off-line analysis
 */
#include <math.h>
#include <string.h>
#include "critter.h"

static void reorganize(critter_data_t *d, int first, int end)
{
    for (size_t t = 0; t < SAMPLES_PER_ROOM; t++) {
        const float *row = d->raw + t * NUM_ROOMS;
        for (int r = first; r < end; r++)
            d->clean[(size_t)r * SAMPLES_PER_ROOM + t] = row[r];
    }
}

/* Index of the histogram bin that holds the element of the given rank. */
static int quantile_bin(const uint32_t *hist, uint32_t rank)
{
    uint32_t seen = 0;
    for (int b = 0; b < HIST_BINS; b++) {
        seen += hist[b];
        if (seen > rank)
            return b;
    }
    return HIST_BINS - 1;
}

static void clean_and_summarize(critter_data_t *d, int first, int end)
{
    uint32_t hist[HIST_BINS];

    for (int r = first; r < end; r++) {
        float *x = d->clean + (size_t)r * SAMPLES_PER_ROOM;

        /* Stage 2a: median from a histogram of the readings */
        memset(hist, 0, sizeof hist);
        for (size_t t = 0; t < SAMPLES_PER_ROOM; t++)
            hist[temp_to_bin(x[t])]++;
        const float median = bin_to_temp(quantile_bin(hist, SAMPLES_PER_ROOM / 2));

        /* Stage 2b: median absolute deviation from a histogram of |x - median| */
        memset(hist, 0, sizeof hist);
        for (size_t t = 0; t < SAMPLES_PER_ROOM; t++)
            hist[dev_to_bin(fabsf(x[t] - median))]++;
        const float mad = bin_to_dev(quantile_bin(hist, SAMPLES_PER_ROOM / 2));

        float limit = OUTLIER_K * 1.4826f * mad;   /* ~ K standard deviations */
        if (limit < OUTLIER_MIN_C)
            limit = OUTLIER_MIN_C;

        /* Stage 3: replace outliers and summarize each window */
        window_summary_t *ws = d->summary + (size_t)r * NUM_WINDOWS;
        float last_good   = median;
        uint32_t outliers = 0;

        for (int w = 0; w < NUM_WINDOWS; w++) {
            float *xw = x + (size_t)w * SUMMARY_WINDOW;
            run_stats_t st;
            stats_reset(&st);
            for (int i = 0; i < SUMMARY_WINDOW; i++) {
                float v = xw[i];
                if (fabsf(v - median) > limit) {
                    xw[i] = last_good;
                    outliers++;
                } else {
                    last_good = v;
                    stats_add(&st, v);
                }
            }
            stats_finish(&st, &ws[w]);
        }

        d->stats[r].median   = median;
        d->stats[r].mad      = mad;
        d->stats[r].outliers = outliers;
    }
}

void memory_unit_run(critter_data_t *d)
{
    run_over_rooms(reorganize, d);
    run_over_rooms(clean_and_summarize, d);
}

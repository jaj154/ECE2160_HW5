/*
 * util.c - Small helpers called from the hot loops of the memory and compute
 * units. Kept in their own file deliberately: without LTO the compiler cannot
 * inline them into those loops, so every call costs a branch-and-link and
 * blocks optimization of the surrounding loop. With -flto they inline freely.
 */
#include <math.h>
#include "critter.h"

uint32_t rng_next(uint32_t *state)          /* xorshift32 */
{
    uint32_t x = *state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return *state = x;
}

float rng_float(uint32_t *state)
{
    return (float)(rng_next(state) >> 8) * (1.0f / 16777216.0f);
}

float rng_gauss(uint32_t *state)
{
    /* Sum of four uniforms (Irwin-Hall), scaled to unit variance. */
    float s = rng_float(state) + rng_float(state) + rng_float(state) + rng_float(state);
    return (s - 2.0f) * 1.7320508f;
}

int temp_to_bin(float c)
{
    if (!(c > (float)HIST_MIN_C))          /* also catches NaN */
        return 0;
    if (c >= (float)HIST_MAX_C)
        return HIST_BINS - 1;
    return (int)((c - (float)HIST_MIN_C) * HIST_PER_C);
}

float bin_to_temp(int bin)
{
    return (float)HIST_MIN_C + ((float)bin + 0.5f) / HIST_PER_C;
}

int dev_to_bin(float dev)
{
    if (!(dev < (float)HIST_BINS / HIST_PER_C))
        return HIST_BINS - 1;
    return (int)(dev * HIST_PER_C);
}

float bin_to_dev(int bin)
{
    return ((float)bin + 0.5f) / HIST_PER_C;
}

void stats_reset(run_stats_t *s)
{
    s->sum = 0.0;
    s->sumsq = 0.0;
    s->min = INFINITY;
    s->max = -INFINITY;
    s->n = 0;
}

void stats_add(run_stats_t *s, float x)
{
    s->sum   += x;
    s->sumsq += (double)x * x;
    if (x < s->min) s->min = x;
    if (x > s->max) s->max = x;
    s->n++;
}

void stats_finish(const run_stats_t *s, window_summary_t *out)
{
    if (s->n == 0) {
        *out = (window_summary_t){0};
        return;
    }
    double mean = s->sum / s->n;
    double var  = s->sumsq / s->n - mean * mean;
    out->min    = s->min;
    out->max    = s->max;
    out->mean   = (float)mean;
    out->stddev = (float)sqrt(var > 0.0 ? var : 0.0);
    out->count  = s->n;
}

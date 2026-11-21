/*
 * dataset.c - Build the multi-room deployment from the real sensor trace.
 *
 * The Critter monitors a distributed set of machine rooms, but a single Pi
 * only has one sensor. The real readings from the I/O unit supply the
 * baseline temperature and real sensor noise; on top of that each room gets
 * its own setpoint offset, an HVAC on/off cycle, and random glitches (the
 * outliers the memory unit must remove). A few rooms model faults:
 *   room % 8 == 3  failing HVAC  - the room slowly warms by 5 C
 *   room % 8 == 5  short-cycling - very short HVAC cycles
 *
 * Readings are stored in collection order (all rooms for time t, then t+1),
 * the way they would arrive from the field. This step is not timed.
 * The -s option selects a different random deployment.
 */
#include <math.h>
#include "critter.h"

void dataset_build(critter_data_t *d)
{
    const float *tr = d->trace;
    const size_t n  = d->trace_len;
    double mean = 0.0;

    for (size_t i = 0; i < n; i++)
        mean += tr[i];
    mean /= (double)n;

    for (int r = 0; r < NUM_ROOMS; r++) {
        /* Seed 0 reproduces the original dataset; other seeds give a
         * different deployment (used to train PGO on separate data). */
        uint32_t rng = 0x9E3779B9u ^ ((uint32_t)r * 0x85EBCA6Bu) ^ (d->seed * 0xC2B2AE35u);
        if (rng == 0)
            rng = 1;

        float offset = -2.0f + 6.0f * rng_float(&rng);    /* setpoint offset (C) */
        float amp    =  0.4f + 1.1f * rng_float(&rng);    /* HVAC swing (C)      */
        float period = (r % 8 == 5) ? 120.0f + 80.0f * rng_float(&rng)
                                    : 400.0f + 1200.0f * rng_float(&rng);
        float drift  = (r % 8 == 3) ? 5.0f : 0.0f;
        size_t phase = rng_next(&rng) % (2 * n);

        for (size_t t = 0; t < SAMPLES_PER_ROOM; t++) {
            /* Real sensor noise, replayed forwards then backwards (no seams). */
            size_t k    = (t + phase) % (2 * n);
            float noise = tr[k < n ? k : 2 * n - 1 - k] - (float)mean;

            /* HVAC cycle: triangle wave (cooling on -> temp falls, off -> rises). */
            float c    = fmodf((float)t, period) / period;
            float hvac = amp * (2.0f * fabsf(2.0f * c - 1.0f) - 1.0f);

            float v = (float)mean + offset + noise + hvac
                    + drift * (float)t / (float)SAMPLES_PER_ROOM;

            if (rng_float(&rng) < GLITCH_RATE) {
                float spike = 10.0f + 30.0f * rng_float(&rng);
                v += (rng_next(&rng) & 1u) ? spike : -spike;
            }
            d->raw[t * NUM_ROOMS + (size_t)r] = v;
        }
    }
}

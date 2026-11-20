/*
 * sensor_sim.c - Simulated temperature sensor for testing without the HAT.
 *
 * Produces HTS221-like values (1/64 C steps, small noise, slow wander).
 * There is no bus delay, so I/O-unit timings from this build are NOT
 * meaningful; use it only to check that everything builds and runs.
 */
#include <math.h>
#include "critter.h"
#include "sensor.h"

static uint32_t rng;
static unsigned long tick;

int sensor_open(void)
{
    rng  = 12345u;
    tick = 0;
    return 0;
}

int sensor_read_celsius(float *celsius)
{
    tick++;
    float v = 22.5f + 0.05f * sinf((float)tick * 0.001f)
                    + 0.03f * (rng_float(&rng) - 0.5f);
    *celsius = roundf(v * 64.0f) / 64.0f;
    return 0;
}

void sensor_close(void) {}

const char *sensor_name(void)
{
    return "simulated (no hardware)";
}

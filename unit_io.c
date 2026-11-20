/*
 * unit_io.c - I/O unit: read temperature values from the sensor at a high rate.
 *
 * I/O-bound by design: almost all of the wall-clock time is spent waiting on
 * the I2C bus inside the kernel, so compare its wall time with its CPU time.
 */
#include <math.h>
#include <stdio.h>
#include "critter.h"
#include "sensor.h"

int io_unit_run(critter_data_t *d, io_report_t *report)
{
    io_report_t rep = {0};
    float prev = NAN;
    size_t n = 0;

    while (n < IO_SAMPLES) {
        float t;
        rep.reads++;

        if (sensor_read_celsius(&t) != 0) {
            if (++rep.errors > IO_MAX_ERRORS) {
                fprintf(stderr, "I/O unit: too many bus errors (%u)\n", rep.errors);
                return -1;
            }
            continue;
        }
        if (t < SENSOR_MIN_C || t > SENSOR_MAX_C) {
            if (++rep.rejected > IO_MAX_ERRORS) {
                fprintf(stderr, "I/O unit: too many implausible readings (%u)\n", rep.rejected);
                return -1;
            }
            continue;
        }
        if (t != prev)
            rep.updates++;
        prev = t;
        d->trace[n++] = t;
    }

    d->trace_len = n;
    *report = rep;
    return 0;
}

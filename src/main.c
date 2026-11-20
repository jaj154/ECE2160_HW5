/*
 * main.c - Critter optimization study driver.
 *
 * Runs the three Critter units in order and times each one separately
 * (wall-clock and process CPU time):
 *   1. I/O unit      - polls the real temperature sensor as fast as possible
 *   2. Memory unit   - reorganizes, removes outliers and summarizes
 *   3. Compute unit  - detects HVAC cycles, fits a model, forecasts alarms
 *
 * Usage: critter_<variant> [-q] [-v]
 *   -q  print only the machine-readable RESULT line (scripts, PGO training)
 *   -v  also print the per-room HVAC report
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "critter.h"
#include "sensor.h"

typedef struct {
    double wall0, cpu0;
    double wall_ms, cpu_ms;
} stopwatch_t;

static double clock_ms(clockid_t id)
{
    struct timespec ts;
    clock_gettime(id, &ts);
    return (double)ts.tv_sec * 1e3 + (double)ts.tv_nsec / 1e6;
}

static void sw_start(stopwatch_t *s)
{
    s->wall0 = clock_ms(CLOCK_MONOTONIC);
    s->cpu0  = clock_ms(CLOCK_PROCESS_CPUTIME_ID);
}

static void sw_stop(stopwatch_t *s)
{
    s->wall_ms = clock_ms(CLOCK_MONOTONIC) - s->wall0;
    s->cpu_ms  = clock_ms(CLOCK_PROCESS_CPUTIME_ID) - s->cpu0;
}

static void *xalloc(size_t bytes)
{
    void *p = NULL;
    if (posix_memalign(&p, 64, bytes) != 0) {
        fprintf(stderr, "out of memory (%zu bytes)\n", bytes);
        exit(1);
    }
    memset(p, 0, bytes);    /* fault the pages in now, outside the timed regions */
    return p;
}

static const char *status_name(int s)
{
    switch (s) {
    case HVAC_SHORT_CYCLING: return "SHORT-CYCLING";
    case HVAC_WARMING:       return "WARMING";
    default:                 return "ok";
    }
}

static void print_room_report(const critter_data_t *d)
{
    printf("\nroom  median(C)  outliers  cycle(min)  trend(C/h)  P(alarm)  alarm in(min)  status\n");
    for (int r = 0; r < NUM_ROOMS; r++) {
        const room_prediction_t *p = &d->pred[r];
        char alarm_in[16] = "-";
        if (p->alarm_in_s >= 0.0)
            snprintf(alarm_in, sizeof alarm_in, "%.1f", p->alarm_in_s / 60.0);
        printf("%4d  %9.2f  %8u  %10.1f  %10.3f  %8.2f  %13s  %s\n",
               r, d->stats[r].median, d->stats[r].outliers, p->cycle_period_s / 60.0,
               p->trend_c_per_h, p->alarm_prob, alarm_in, status_name(p->status));
    }
}

int main(int argc, char **argv)
{
    int quiet = 0, verbose = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-q"))
            quiet = 1;
        else if (!strcmp(argv[i], "-v"))
            verbose = 1;
        else {
            fprintf(stderr, "usage: %s [-q] [-v]\n", argv[0]);
            return 2;
        }
    }

    critter_data_t d = {0};
    d.trace   = xalloc(IO_SAMPLES * sizeof *d.trace);
    d.raw     = xalloc((size_t)NUM_ROOMS * SAMPLES_PER_ROOM * sizeof *d.raw);
    d.clean   = xalloc((size_t)NUM_ROOMS * SAMPLES_PER_ROOM * sizeof *d.clean);
    d.summary = xalloc((size_t)NUM_ROOMS * NUM_WINDOWS * sizeof *d.summary);
    d.stats   = xalloc(NUM_ROOMS * sizeof *d.stats);
    d.pred    = xalloc(NUM_ROOMS * sizeof *d.pred);

    /* Sensor bring-up (power-on, calibration) is setup, not part of the unit. */
    if (sensor_open() != 0)
        return 1;

    stopwatch_t t_io, t_mem, t_cmp;
    io_report_t io;

    sw_start(&t_io);
    int rc = io_unit_run(&d, &io);
    sw_stop(&t_io);
    sensor_close();
    if (rc != 0)
        return 1;

    dataset_build(&d);                 /* expand to all rooms (not timed) */

    sw_start(&t_mem);
    memory_unit_run(&d);
    sw_stop(&t_mem);

    sw_start(&t_cmp);
    compute_unit_run(&d);
    sw_stop(&t_cmp);

    /* Checksums: keep the compiler from discarding work, and let you confirm
     * that every build variant computes (nearly) the same answer. Low-order
     * digits can differ between -O0 and -O2 because of fused multiply-add. */
    double mem_sum = 0.0, cmp_sum = 0.0;
    uint32_t outliers = 0;
    int flagged = 0;
    for (size_t i = 0; i < (size_t)NUM_ROOMS * NUM_WINDOWS; i++)
        mem_sum += (double)d.summary[i].mean * d.summary[i].count;
    for (int r = 0; r < NUM_ROOMS; r++) {
        outliers += d.stats[r].outliers;
        cmp_sum  += d.pred[r].cycle_period_s + d.pred[r].residual_rms + d.pred[r].alarm_prob;
        flagged  += d.pred[r].status != HVAC_OK;
    }

    const double total = t_io.wall_ms + t_mem.wall_ms + t_cmp.wall_ms;

    if (!quiet) {
        printf("Critter optimization study   build=%s   threads=%d\n", VARIANT, worker_count());
        printf("sensor: %s\n", sensor_name());
        printf("workload: %d sensor reads; %d rooms x %d readings\n\n",
               IO_SAMPLES, NUM_ROOMS, SAMPLES_PER_ROOM);
        printf("%-8s %11s %11s   %s\n", "unit", "wall (ms)", "cpu (ms)", "notes");
        printf("%-8s %11.2f %11.2f   %u reads, %u new sensor values, %u errors, %u rejected\n",
               "I/O", t_io.wall_ms, t_io.cpu_ms, io.reads, io.updates, io.errors, io.rejected);
        printf("%-8s %11.2f %11.2f   %u outliers replaced, %d summary records\n",
               "Memory", t_mem.wall_ms, t_mem.cpu_ms, outliers, NUM_ROOMS * NUM_WINDOWS);
        printf("%-8s %11.2f %11.2f   %d of %d rooms flagged\n",
               "Compute", t_cmp.wall_ms, t_cmp.cpu_ms, flagged, NUM_ROOMS);
        printf("%-8s %11.2f\n\n", "Total", total);
        printf("checksums: memory=%.6e  compute=%.6e\n", mem_sum, cmp_sum);
    }
    if (verbose)
        print_room_report(&d);

    printf("RESULT,%s,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f\n", VARIANT,
           t_io.wall_ms, t_io.cpu_ms, t_mem.wall_ms, t_mem.cpu_ms,
           t_cmp.wall_ms, t_cmp.cpu_ms, total);

    free(d.trace);
    free(d.raw);
    free(d.clean);
    free(d.summary);
    free(d.stats);
    free(d.pred);
    return 0;
}

#!/usr/bin/env bash
# One-time update for the paper feedback. It adds:
#   - hardware performance counters per unit (critter_<variant> -p)
#   - a dataset seed option (critter_<variant> -s N)
#   - PGO builds trained on a different dataset (o2_pgo_xseed, o2_pgo_lto_xseed)
#   - collect_extra.sh: platform details, build time, binary size,
#     GCC vectorization/inlining reports, counters, and the PGO retraining runs
# then runs collect_extra.sh and pushes the results to GitHub.
#
# Run on the Pi, from the repository:   bash apply_update.sh
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")"

SCRIPT=$(find . -name run_experiments.sh -not -path './.git/*' | head -n 1)
[ -n "$SCRIPT" ] || { echo "run_experiments.sh not found in this repository"; exit 1; }
cd "$(dirname "$SCRIPT")"
[ -f src/unit_compute.c ] || { echo "expected src/unit_compute.c next to run_experiments.sh"; exit 1; }

echo "== Writing updated project files"
cat > src/critter.h <<'__CRITTER_EOF__'
/*
 * critter.h - Shared configuration and data structures for the Critter
 *             compiler-optimization study.
 *
 * The Critter is split into three units with deliberately different behavior:
 *   I/O unit      (unit_io.c)      - I/O-bound: polls the real temperature sensor
 *   Memory unit   (unit_memory.c)  - memory-bound: reorganize, de-outlier, summarize
 *   Compute unit  (unit_compute.c) - CPU-bound: HVAC cycle detection and forecasting
 */
#ifndef CRITTER_H
#define CRITTER_H

#include <stddef.h>
#include <stdint.h>

#ifndef VARIANT
#define VARIANT "unnamed"
#endif

/* ------------------------------------------------------------------------
 * Workload size. Compile-time constants so every build variant does exactly
 * the same work. Override with e.g.
 *     make clean && make EXTRA="-DSAMPLES_PER_ROOM=131072"
 * ------------------------------------------------------------------------ */
#ifndef IO_SAMPLES
#define IO_SAMPLES        2000    /* real sensor reads taken by the I/O unit   */
#endif
#ifndef NUM_ROOMS
#define NUM_ROOMS         64      /* machine rooms in the deployment           */
#endif
#ifndef SAMPLES_PER_ROOM
#define SAMPLES_PER_ROOM  65536   /* logged readings per room (~18 h at 1 Hz)  */
#endif
#ifndef SUMMARY_WINDOW
#define SUMMARY_WINDOW    1024    /* readings per summary record               */
#endif
#ifndef DECIMATE
#define DECIMATE          4       /* compute unit works on 4-reading averages  */
#endif
#ifndef MAX_LAG
#define MAX_LAG           512     /* longest HVAC cycle searched (decimated)   */
#endif
#ifndef AR_ORDER
#define AR_ORDER          16      /* autoregressive model order                */
#endif
#ifndef FORECAST_STEPS
#define FORECAST_STEPS    2048    /* forecast horizon (decimated samples)      */
#endif
#ifndef MC_PATHS
#define MC_PATHS          64      /* Monte Carlo futures simulated per room    */
#endif
#ifndef MAX_THREADS
#define MAX_THREADS       16
#endif

#define SAMPLE_PERIOD_S   1.0     /* seconds represented by one logged reading */
#define NUM_WINDOWS       (SAMPLES_PER_ROOM / SUMMARY_WINDOW)
#define DEC_LEN           (SAMPLES_PER_ROOM / DECIMATE)

#if SAMPLES_PER_ROOM % SUMMARY_WINDOW != 0 || SAMPLES_PER_ROOM % DECIMATE != 0
#error "SAMPLES_PER_ROOM must be a multiple of SUMMARY_WINDOW and DECIMATE"
#endif
#if MAX_LAG >= DEC_LEN || AR_ORDER > MAX_LAG
#error "need AR_ORDER <= MAX_LAG < SAMPLES_PER_ROOM / DECIMATE"
#endif

/* I/O unit: plausibility limits (HTS221 operating range) */
#define SENSOR_MIN_C      (-40.0f)
#define SENSOR_MAX_C      (120.0f)
#define IO_MAX_ERRORS     (IO_SAMPLES / 10)

/* Dataset model: fraction of readings that are sensor/transmission glitches */
#define GLITCH_RATE       0.002f

/* Memory unit: robust outlier rejection using 0.05 C histograms */
#define HIST_MIN_C        (-40)
#define HIST_MAX_C        85
#define HIST_PER_C        20
#define HIST_BINS         ((HIST_MAX_C - HIST_MIN_C) * HIST_PER_C)
#define OUTLIER_K         5.0f    /* reject |x - median| > K * 1.4826 * MAD     */
#define OUTLIER_MIN_C     1.0f    /* never reject readings this close to median */

/* Compute unit: HVAC classification */
#define ALARM_DELTA_C        2.5   /* alarm when room exceeds its median + this   */
#define TREND_ALARM_C_PER_H  0.1   /* sustained warming rate considered a fault   */
#define SHORT_CYCLE_S        300.0 /* HVAC cycles shorter than this = short-cycling */

/* ------------------------------------------------------------------------ */

typedef struct {
    float    min, max, mean, stddev;
    uint32_t count;               /* readings that survived outlier rejection */
} window_summary_t;

typedef struct {
    float    median, mad;
    uint32_t outliers;
} room_stats_t;

enum { HVAC_OK = 0, HVAC_SHORT_CYCLING, HVAC_WARMING };

typedef struct {
    double coef[AR_ORDER];        /* AR model coefficients                     */
    double residual_rms;          /* one-step prediction error (C)             */
    double trend_c_per_h;         /* long-term warming/cooling rate            */
    double cycle_period_s;        /* dominant HVAC cycle, 0 if none found      */
    double cycle_strength;        /* normalized autocorrelation at that period */
    double alarm_prob;            /* fraction of forecasts that hit the alarm  */
    double alarm_in_s;            /* mean time to alarm, -1 if never           */
    double forecast_end_c;        /* mean forecast at end of horizon           */
    int    status;                /* HVAC_* classification                     */
} room_prediction_t;

typedef struct {
    uint32_t seed;                /* dataset seed (-s option); 0 = default     */
    float  *trace;                /* IO_SAMPLES real readings (I/O unit)       */
    size_t  trace_len;
    float  *raw;                  /* collection order: raw[t*NUM_ROOMS + room] */
    float  *clean;                /* per-room order: clean[room*SAMPLES_PER_ROOM + t] */
    window_summary_t  *summary;   /* NUM_ROOMS * NUM_WINDOWS                   */
    room_stats_t      *stats;     /* NUM_ROOMS                                 */
    room_prediction_t *pred;      /* NUM_ROOMS                                 */
} critter_data_t;

typedef struct {
    uint32_t reads;               /* bus transactions attempted                */
    uint32_t errors;              /* failed transactions                       */
    uint32_t rejected;            /* implausible values discarded              */
    uint32_t updates;             /* readings that differed from the previous  */
} io_report_t;

/* The three units */
int  io_unit_run(critter_data_t *d, io_report_t *report);
void memory_unit_run(critter_data_t *d);
void compute_unit_run(critter_data_t *d);

/* dataset.c - expands the real trace into a multi-room deployment (untimed) */
void dataset_build(critter_data_t *d);

/* parallel.c - runs fn over all rooms, split across cores if CRITTER_THREADS */
typedef void (*room_task_fn)(critter_data_t *d, int first_room, int end_room);
void run_over_rooms(room_task_fn fn, critter_data_t *d);
int  worker_count(void);

/* util.c - small helpers used in hot loops of the other files. They live in
 * their own translation unit on purpose: only LTO can inline them across files. */
typedef struct {
    double   sum, sumsq;
    float    min, max;
    uint32_t n;
} run_stats_t;

uint32_t rng_next(uint32_t *state);
float    rng_float(uint32_t *state);       /* uniform [0, 1)              */
float    rng_gauss(uint32_t *state);       /* approx. standard normal     */
int      temp_to_bin(float celsius);
float    bin_to_temp(int bin);
int      dev_to_bin(float deviation);
float    bin_to_dev(int bin);
void     stats_reset(run_stats_t *s);
void     stats_add(run_stats_t *s, float x);
void     stats_finish(const run_stats_t *s, window_summary_t *out);

#endif /* CRITTER_H */
__CRITTER_EOF__

cat > src/dataset.c <<'__CRITTER_EOF__'
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
__CRITTER_EOF__

cat > src/main.c <<'__CRITTER_EOF__'
/*
 * main.c - Critter optimization study driver.
 *
 * Runs the three Critter units in order and times each one separately
 * (wall-clock and process CPU time):
 *   1. I/O unit      - polls the real temperature sensor as fast as possible
 *   2. Memory unit   - reorganizes, removes outliers and summarizes
 *   3. Compute unit  - detects HVAC cycles, fits a model, forecasts alarms
 *
 * Usage: critter_<variant> [-q] [-v] [-p] [-s seed]
 *   -q       print only the machine-readable RESULT/PMU lines (scripts, PGO training)
 *   -v       also print the per-room HVAC report
 *   -p       also count hardware events per unit (cycles, instructions, ...)
 *   -s seed  generate a different random deployment (default 0)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "critter.h"
#include "sensor.h"
#include "pmu.h"

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
    int quiet = 0, verbose = 0, counters = 0;
    uint32_t seed = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-q"))
            quiet = 1;
        else if (!strcmp(argv[i], "-v"))
            verbose = 1;
        else if (!strcmp(argv[i], "-p"))
            counters = 1;
        else if (!strcmp(argv[i], "-s") && i + 1 < argc)
            seed = (uint32_t)strtoul(argv[++i], NULL, 0);
        else {
            fprintf(stderr, "usage: %s [-q] [-v] [-p] [-s seed]\n", argv[0]);
            return 2;
        }
    }

    if (counters && pmu_open() != 0) {
        fprintf(stderr, "hardware counters unavailable (%s)\n", pmu_error());
        counters = 0;
    }

    critter_data_t d = {0};
    d.seed    = seed;
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
    pmu_sample_t c_io = {0}, c_mem = {0}, c_cmp = {0};

    if (counters) pmu_start();
    sw_start(&t_io);
    int rc = io_unit_run(&d, &io);
    sw_stop(&t_io);
    if (counters) pmu_stop(&c_io);
    sensor_close();
    if (rc != 0)
        return 1;

    dataset_build(&d);                 /* expand to all rooms (not timed) */

    if (counters) pmu_start();
    sw_start(&t_mem);
    memory_unit_run(&d);
    sw_stop(&t_mem);
    if (counters) pmu_stop(&c_mem);

    if (counters) pmu_start();
    sw_start(&t_cmp);
    compute_unit_run(&d);
    sw_stop(&t_cmp);
    if (counters) pmu_stop(&c_cmp);
    if (counters) pmu_close();

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
        printf("Critter optimization study   build=%s   threads=%d   seed=%u\n",
               VARIANT, worker_count(), seed);
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
    if (counters) {
        /* PMU,variant,unit,cycles,instructions,branch_misses,cache_refs,cache_misses,scaled */
        const char *names[3] = { "io", "memory", "compute" };
        const pmu_sample_t *c[3] = { &c_io, &c_mem, &c_cmp };
        for (int u = 0; u < 3; u++) {
            printf("PMU,%s,%s", VARIANT, names[u]);
            for (int e = 0; e < PMU_NEVENTS; e++) {
                if (c[u]->valid)
                    printf(",%llu", (unsigned long long)c[u]->value[e]);
                else
                    printf(",NA");
            }
            printf(",%d\n", c[u]->scaled);
        }
    }

    free(d.trace);
    free(d.raw);
    free(d.clean);
    free(d.summary);
    free(d.stats);
    free(d.pred);
    return 0;
}
__CRITTER_EOF__

cat > src/pmu.h <<'__CRITTER_EOF__'
/*
 * pmu.h - Optional hardware performance counters (Linux perf_event_open).
 *
 * Enabled at run time with the -p option. Counts user-space events only, so it
 * works with the default kernel.perf_event_paranoid setting of 2. On Arm cores
 * the generic cache events map to L1 data-cache accesses and refills.
 */
#ifndef PMU_H
#define PMU_H

#include <stdint.h>

#define PMU_NEVENTS 5

typedef struct {
    uint64_t value[PMU_NEVENTS];
    int      valid;     /* 0 if the counters could not be read          */
    int      scaled;    /* 1 if the kernel multiplexed and we scaled    */
} pmu_sample_t;

int         pmu_open(void);                 /* 0 if counters are available */
void        pmu_start(void);
void        pmu_stop(pmu_sample_t *out);
void        pmu_close(void);
const char *pmu_event_name(int i);
const char *pmu_error(void);

#endif /* PMU_H */
__CRITTER_EOF__

cat > src/pmu.c <<'__CRITTER_EOF__'
/*
 * pmu.c - Hardware performance counters around each Critter unit.
 *
 * Uses the perf_event_open system call directly, so no extra tools are needed.
 * inherit=1 makes the counters include worker threads created by the unit.
 */
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <linux/perf_event.h>
#include "pmu.h"

static const struct {
    uint32_t    type;
    uint64_t    config;
    const char *name;
} EVENTS[PMU_NEVENTS] = {
    { PERF_TYPE_HARDWARE, PERF_COUNT_HW_CPU_CYCLES,       "cycles"        },
    { PERF_TYPE_HARDWARE, PERF_COUNT_HW_INSTRUCTIONS,     "instructions"  },
    { PERF_TYPE_HARDWARE, PERF_COUNT_HW_BRANCH_MISSES,    "branch_misses" },
    { PERF_TYPE_HARDWARE, PERF_COUNT_HW_CACHE_REFERENCES, "cache_refs"    },
    { PERF_TYPE_HARDWARE, PERF_COUNT_HW_CACHE_MISSES,     "cache_misses"  },
};

static int  fds[PMU_NEVENTS] = { -1, -1, -1, -1, -1 };
static char errbuf[160] = "not opened";

static int open_event(uint32_t type, uint64_t config)
{
    struct perf_event_attr a;
    memset(&a, 0, sizeof a);
    a.size           = sizeof a;
    a.type           = type;
    a.config         = config;
    a.disabled       = 1;
    a.exclude_kernel = 1;
    a.exclude_hv     = 1;
    a.inherit        = 1;
    a.read_format    = PERF_FORMAT_TOTAL_TIME_ENABLED | PERF_FORMAT_TOTAL_TIME_RUNNING;
    return (int)syscall(SYS_perf_event_open, &a, 0, -1, -1, 0);
}

int pmu_open(void)
{
    for (int i = 0; i < PMU_NEVENTS; i++) {
        fds[i] = open_event(EVENTS[i].type, EVENTS[i].config);
        if (fds[i] < 0) {
            int e = errno;
            snprintf(errbuf, sizeof errbuf, "%s: %s%s", EVENTS[i].name, strerror(e),
                     (e == EACCES || e == EPERM)
                         ? " - try: sudo sysctl -w kernel.perf_event_paranoid=2"
                         : " - this kernel/CPU exposes no hardware counters");
            pmu_close();
            return -1;
        }
    }
    return 0;
}

void pmu_start(void)
{
    for (int i = 0; i < PMU_NEVENTS; i++)
        ioctl(fds[i], PERF_EVENT_IOC_RESET, 0);
    for (int i = 0; i < PMU_NEVENTS; i++)
        ioctl(fds[i], PERF_EVENT_IOC_ENABLE, 0);
}

void pmu_stop(pmu_sample_t *out)
{
    for (int i = 0; i < PMU_NEVENTS; i++)
        ioctl(fds[i], PERF_EVENT_IOC_DISABLE, 0);

    out->valid  = 1;
    out->scaled = 0;
    for (int i = 0; i < PMU_NEVENTS; i++) {
        uint64_t buf[3];   /* value, time enabled, time running */
        if (read(fds[i], buf, sizeof buf) != (ssize_t)sizeof buf || buf[2] == 0) {
            out->value[i] = 0;
            out->valid = 0;
        } else if (buf[2] < buf[1]) {
            out->value[i] = (uint64_t)((double)buf[0] * (double)buf[1] / (double)buf[2]);
            out->scaled = 1;
        } else {
            out->value[i] = buf[0];
        }
    }
}

void pmu_close(void)
{
    for (int i = 0; i < PMU_NEVENTS; i++) {
        if (fds[i] >= 0)
            close(fds[i]);
        fds[i] = -1;
    }
}

const char *pmu_event_name(int i) { return EVENTS[i].name; }
const char *pmu_error(void)       { return errbuf; }
__CRITTER_EOF__

cat > Makefile <<'__CRITTER_EOF__'
# Critter compiler-optimization study
#
#   make                 build all variants (PGO targets run a training pass)
#   make o2              build one variant
#   make SENSOR=sim      build against the simulated sensor (no HAT needed)
#   make clean           remove build/  (do this after changing SENSOR or EXTRA)
#
# Optional knobs (keep empty for the baseline study):
#   ARCH="-mcpu=native"                  tune for the exact Pi CPU
#   EXTRA="-DSAMPLES_PER_ROOM=131072"    change the workload size

ifeq ($(origin CC),default)
CC     := gcc
endif
SENSOR ?= sensehat
ARCH   ?=
EXTRA  ?=
BUILD  := build

SRCS   := main.c unit_io.c unit_memory.c unit_compute.c dataset.c util.c parallel.c \
          pmu.c sensor_$(SENSOR).c
HDRS   := $(wildcard src/*.h)
COMMON := -std=gnu11 -Wall -Wextra -pthread $(ARCH) $(EXTRA)
LDLIBS := -lm

VARIANTS := o0 o2 o2_lto o2_pgo o2_pgo_lto o2_threads o2_pgo_xseed o2_pgo_lto_xseed

.PHONY: all clean variant $(VARIANTS)
.NOTPARALLEL:

all: $(VARIANTS)

# ---- single-step variants ------------------------------------------------
o0:
	@$(MAKE) --no-print-directory variant V=$@ VFLAGS="-O0"
o2:
	@$(MAKE) --no-print-directory variant V=$@ VFLAGS="-O2"
o2_lto:
	@$(MAKE) --no-print-directory variant V=$@ VFLAGS="-O2 -flto=auto"
o2_threads:
	@$(MAKE) --no-print-directory variant V=$@ VFLAGS="-O2 -DCRITTER_THREADS"

# ---- profile-guided variants (three steps) -------------------------------
# 1. build with -fprofile-generate (instrumented)
#    (-fprofile-update=single: these builds are single-threaded, and the
#    default with -pthread is slow atomic counter updates)
# 2. run it: writes one .gcda profile per object file into build/<variant>/
#    ($(3) is the dataset seed for the training run; the _xseed variants
#    train on a different deployment than the one the benchmarks measure)
# 3. delete the objects (keep the .gcda) and rebuild with -fprofile-use
#    into the same paths so GCC finds the matching profiles
define pgo_build
	@echo "== $(1): PGO step 1/3 - instrumented build"
	@rm -rf $(BUILD)/$(1) $(BUILD)/critter_$(1) $(BUILD)/critter_$(1)_train
	@$(MAKE) --no-print-directory variant V=$(1) VFLAGS="$(2) -fprofile-generate -fprofile-update=single"
	@mv $(BUILD)/critter_$(1) $(BUILD)/critter_$(1)_train
	@echo "== $(1): PGO step 2/3 - training run (dataset seed $(3))"
	@t0=$$(date +%s.%N); ./$(BUILD)/critter_$(1)_train -q -s $(3) > /dev/null; t1=$$(date +%s.%N); \
	  awk -v a=$$t0 -v b=$$t1 -v v=$(1) 'BEGIN { printf "TRAINTIME,%s,%.3f\n", v, b - a }'
	@echo "== $(1): PGO step 3/3 - optimized rebuild using the profile"
	@rm -f $(BUILD)/$(1)/*.o
	@$(MAKE) --no-print-directory variant V=$(1) VFLAGS="$(2) -fprofile-use -fprofile-correction"
endef

o2_pgo:
	$(call pgo_build,$@,-O2,0)
o2_pgo_lto:
	$(call pgo_build,$@,-O2 -flto=auto,0)
o2_pgo_xseed:
	$(call pgo_build,$@,-O2,7)
o2_pgo_lto_xseed:
	$(call pgo_build,$@,-O2 -flto=auto,7)

# ---- generic rules for one variant (invoked recursively with V and VFLAGS)
ifdef V
OBJDIR := $(BUILD)/$(V)
OBJS   := $(addprefix $(OBJDIR)/,$(SRCS:.c=.o))

variant: $(BUILD)/critter_$(V)

$(BUILD)/critter_$(V): $(OBJS)
	$(CC) $(VFLAGS) $(COMMON) $^ -o $@ $(LDLIBS)

$(OBJDIR)/%.o: src/%.c $(HDRS)
	@mkdir -p $(OBJDIR)
	$(CC) $(VFLAGS) $(COMMON) -DVARIANT='"$(V)"' -c $< -o $@
endif

clean:
	rm -rf $(BUILD)
__CRITTER_EOF__

cat > collect_extra.sh <<'__CRITTER_EOF__'
#!/usr/bin/env bash
# Collects the additional data for the paper (takes about 10-15 minutes):
#   1. platform details
#   2. build time and binary size for each variant
#   3. GCC optimization reports (vectorization, loop, inlining)
#   4. hardware performance counters per unit
#   5. PGO retrained on a different dataset (timing session)
# Results go to results/extra_<time>/.
#
#   bash collect_extra.sh
#   BUILD_REPS=1 PMU_RUNS=1 RUNS=2 bash collect_extra.sh     (quick test)
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")"

SENSOR=${SENSOR:-sensehat}
BUILD_REPS=${BUILD_REPS:-3}
PMU_RUNS=${PMU_RUNS:-3}
RUNS=${RUNS:-5}
COMMON="-std=gnu11 -Wall -Wextra -pthread"
BUILD_VARIANTS="o0 o2 o2_lto o2_pgo o2_pgo_lto o2_threads"
PMU_VARIANTS="o0 o2 o2_lto o2_pgo o2_pgo_lto"
RETRAIN_VARIANTS="o2 o2_pgo o2_pgo_xseed o2_pgo_lto o2_pgo_lto_xseed"

OUT=results/extra_$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUT/optinfo"

# ---------------------------------------------------------------- 1. platform
echo "== 1/5 Platform details"
i2c=/sys/class/i2c-adapter/i2c-1/of_node/clock-frequency
{
    echo "model:     $(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo unknown)"
    echo "cpu:       $(lscpu | awk -F: '/Model name/ { sub(/^ +/, "", $2); print $2; exit }')"
    echo "cores:     $(nproc)"
    echo "ram:       $(free -h | awk '/^Mem:/ { print $2 }')"
    echo "os:        $(. /etc/os-release && echo "$PRETTY_NAME")"
    echo "kernel:    $(uname -r) ($(uname -m))"
    echo "userland:  $(getconf LONG_BIT)-bit"
    echo "gcc:       $(gcc --version | head -n 1)"
    echo "governor:  $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
    echo "max_freq:  $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || echo unknown) kHz"
    if [ -r "$i2c" ]; then
        echo "i2c1_clock: $(od -An -tu4 --endian=big "$i2c" | tr -d ' ') Hz"
    else
        echo "i2c1_clock: unknown"
    fi
    echo "perf_event_paranoid: $(cat /proc/sys/kernel/perf_event_paranoid)"
} | tee "$OUT/platform.txt"

# ------------------------------------------------- 2. build time, binary size
echo "== 2/5 Build time and binary size ($BUILD_REPS clean builds per variant)"
echo "variant,rep,total_build_s,training_run_s" > "$OUT/build_time.csv"
for ((r = 1; r <= BUILD_REPS; r++)); do
    for v in $BUILD_VARIANTS; do
        rm -rf "build/$v" "build/critter_$v" "build/critter_${v}_train"
        t0=$(date +%s.%N)
        log=$(make --no-print-directory SENSOR="$SENSOR" "$v" 2>&1) || { echo "$log"; exit 1; }
        t1=$(date +%s.%N)
        train=$(echo "$log" | awk -F, '/^TRAINTIME,/ { print $3 }')
        awk -v v="$v" -v r="$r" -v a="$t0" -v b="$t1" -v t="${train:-0}" \
            'BEGIN { printf "%s,%d,%.3f,%.3f\n", v, r, b - a, t }' | tee -a "$OUT/build_time.csv"
    done
done
echo "variant,text_bytes,data_bytes,bss_bytes,file_bytes" > "$OUT/binary_size.csv"
for v in $BUILD_VARIANTS; do
    read -r text data bss _ < <(size "build/critter_$v" | tail -n 1)
    echo "$v,$text,$data,$bss,$(stat -c %s "build/critter_$v")" | tee -a "$OUT/binary_size.csv"
done

# ------------------------------------------------------ 3. optimization reports
echo "== 3/5 GCC optimization reports"
OI="-fopt-info-vec-loop-inline-optimized"
for f in unit_compute unit_memory; do
    gcc -O2 $COMMON $OI -c "src/$f.c" -o /tmp/critter_optinfo.o 2> "$OUT/optinfo/o2_$f.txt"
    # Recompile in place so GCC finds build/o2_pgo/$f.gcda; the object it writes is identical.
    gcc -O2 -fprofile-use -fprofile-correction $COMMON $OI -c "src/$f.c" -o "build/o2_pgo/$f.o" \
        2> "$OUT/optinfo/o2_pgo_$f.txt"
done
# LTO optimizes at link time, so its reports come from relinking the existing objects.
gcc -O2 -flto=auto $COMMON $OI build/o2_lto/*.o -o /tmp/critter_optinfo_lto -lm \
    2> "$OUT/optinfo/o2_lto_link.txt"
gcc -O2 -flto=auto -fprofile-use -fprofile-correction $COMMON $OI build/o2_pgo_lto/*.o \
    -o /tmp/critter_optinfo_pgo_lto -lm 2> "$OUT/optinfo/o2_pgo_lto_link.txt"
{
    for f in "$OUT"/optinfo/o2*.txt; do
        echo "### $(basename "$f")"
        grep -E "(unit_compute|unit_memory|util)\.c:.*(vectorized|unrolled|peeled|versioned)|Inlined (rng_|temp_to_bin|dev_to_bin|stats_|bin_to)[^ ]* into (predict_room|clean_and_summarize)" "$f" \
            | sed -E -e 's/ which now has.*//' -e 's#/[0-9]+##g' | sort | uniq -c || true
        echo
    done
} > "$OUT/optinfo/summary.txt"
echo "   wrote $OUT/optinfo/summary.txt"

# ---------------------------------------------------- 4. performance counters
echo "== 4/5 Hardware performance counters ($PMU_RUNS runs per variant)"
if [ "$(cat /proc/sys/kernel/perf_event_paranoid)" -gt 2 ]; then
    echo "   lowering kernel.perf_event_paranoid to 2 until the next reboot (needs sudo)"
    sudo sysctl -w kernel.perf_event_paranoid=2 > /dev/null
fi
echo "variant,run,unit,cycles,instructions,branch_misses,cache_refs,cache_misses,scaled" > "$OUT/pmu.csv"
for ((r = 1; r <= PMU_RUNS; r++)); do
    for v in $PMU_VARIANTS; do
        "./build/critter_$v" -q -p | awk -F, -v r="$r" \
            '/^PMU,/ { printf "%s,%d", $2, r; for (i = 3; i <= NF; i++) printf ",%s", $i; printf "\n" }' \
            >> "$OUT/pmu.csv"
    done
    echo "   round $r/$PMU_RUNS done"
done
if [ "$(wc -l < "$OUT/pmu.csv")" -le 1 ]; then
    echo "   WARNING: no counter data was recorded (see the message above); continuing."
fi

# ----------------------------------------------- 5. PGO trained on other data
echo "== 5/5 PGO trained on a different dataset ($RUNS interleaved runs)"
VARIANTS="$RETRAIN_VARIANTS" RUNS="$RUNS" SENSOR="$SENSOR" bash run_experiments.sh | tee "$OUT/pgo_retrain_log.txt"
mv "$(ls -t results/raw_*.csv | head -n 1)" "$OUT/pgo_retrain_raw.csv"
mv "$(ls -t results/summary_*.csv | head -n 1)" "$OUT/pgo_retrain_summary.csv"

echo
echo "All extra results are in $OUT"
__CRITTER_EOF__

chmod +x collect_extra.sh run_experiments.sh

if ! grep -q "collect_extra.sh" README.md 2>/dev/null; then
    cat >> README.md <<'__CRITTER_EOF__'

## Extra measurements (paper feedback)

`bash collect_extra.sh` records platform details, clean-build time and binary
size per variant, GCC optimization reports (`-fopt-info-vec-loop-inline-optimized`)
for -O2, PGO and LTO, hardware performance counters per unit (`-p` option,
via `perf_event_open`), and a timing session comparing PGO trained on the
measured dataset with PGO trained on a different one (`o2_pgo_xseed`,
`o2_pgo_lto_xseed`, trained with `-s 7`). Output: `results/extra_<time>/`.
__CRITTER_EOF__
fi

git add src Makefile collect_extra.sh README.md
git commit -q -m "Add hardware counters, dataset seed, cross-seed PGO builds, extra data collection" || true
make clean > /dev/null

echo "== Running the extra experiments (about 10-15 minutes)"
bash collect_extra.sh

git add results
git commit -q -m "Extra results for paper feedback"
git push
echo "Done: results pushed to GitHub."

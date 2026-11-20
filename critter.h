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

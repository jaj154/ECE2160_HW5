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

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

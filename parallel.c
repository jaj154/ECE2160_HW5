/*
 * parallel.c - Optional multi-core execution.
 *
 * Rooms are independent, so the memory and compute units split the rooms
 * into one contiguous block per core. Built only with -DCRITTER_THREADS;
 * otherwise everything runs on one core. The I/O unit is never split: there
 * is one sensor on one I2C bus, so extra cores cannot make it faster.
 */
#include <stdio.h>
#include <unistd.h>
#include "critter.h"

#ifdef CRITTER_THREADS
#include <pthread.h>

typedef struct {
    room_task_fn    fn;
    critter_data_t *d;
    int             first, end;
} job_t;

static void *worker(void *arg)
{
    job_t *j = arg;
    j->fn(j->d, j->first, j->end);
    return NULL;
}

int worker_count(void)
{
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    if (n < 1) n = 1;
    if (n > MAX_THREADS) n = MAX_THREADS;
    if (n > NUM_ROOMS) n = NUM_ROOMS;
    return (int)n;
}

void run_over_rooms(room_task_fn fn, critter_data_t *d)
{
    const int nt = worker_count();
    pthread_t tid[MAX_THREADS];
    job_t     job[MAX_THREADS];
    int       started[MAX_THREADS] = {0};

    for (int i = 0; i < nt; i++)
        job[i] = (job_t){ fn, d, NUM_ROOMS * i / nt, NUM_ROOMS * (i + 1) / nt };

    for (int i = 1; i < nt; i++)                 /* main thread takes block 0 */
        started[i] = pthread_create(&tid[i], NULL, worker, &job[i]) == 0;

    fn(d, job[0].first, job[0].end);

    for (int i = 1; i < nt; i++) {
        if (started[i])
            pthread_join(tid[i], NULL);
        else
            fn(d, job[i].first, job[i].end);     /* thread failed: run inline */
    }
}

#else  /* single core */

int worker_count(void)
{
    return 1;
}

void run_over_rooms(room_task_fn fn, critter_data_t *d)
{
    fn(d, 0, NUM_ROOMS);
}

#endif

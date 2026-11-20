/*
 * unit_compute.c - Compute unit: predict HVAC behavior for every room.
 *
 * CPU-bound by design: per room the data (~130 KB) fits in cache and the time
 * goes into floating-point loops.
 *   1. Decimate (4-reading average) and remove the linear trend (warming rate)
 *   2. Autocorrelation up to MAX_LAG  -> dominant HVAC on/off cycle period
 *   3. AR(AR_ORDER) model via Levinson-Durbin, plus its residual error
 *   4. Monte Carlo forecast (MC_PATHS random futures) -> probability that the
 *      room exceeds its alarm temperature within the horizon, and when
 *   5. Classify: OK / SHORT-CYCLING / WARMING
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "critter.h"

static void autocorrelation(const double *restrict y, int n, double *restrict acf)
{
    memset(acf, 0, (MAX_LAG + 1) * sizeof *acf);
    for (int i = 0; i < n; i++) {
        const double yi = y[i];
        const int kmax  = (n - 1 - i < MAX_LAG) ? n - 1 - i : MAX_LAG;
        for (int k = 0; k <= kmax; k++)
            acf[k] += yi * y[i + k];
    }
}

/* Strongest repeat after the first zero crossing = HVAC cycle length. */
static void find_cycle(const double *acf, double *period, double *strength)
{
    *period = 0.0;
    *strength = 0.0;
    if (acf[0] <= 0.0)
        return;

    int k = 1;
    while (k <= MAX_LAG && acf[k] > 0.0)
        k++;

    int best = -1;
    double best_val = 0.0;
    for (; k <= MAX_LAG; k++) {
        if (acf[k] > best_val) {
            best_val = acf[k];
            best = k;
        }
    }
    if (best > 0 && best_val / acf[0] > 0.2) {
        *period = best;
        *strength = best_val / acf[0];
    }
}

/* Yule-Walker AR fit (Levinson-Durbin): y[t] ~ sum a[j] * y[t-1-j].
 * Using the biased autocorrelation guarantees a stable model. */
static void levinson(const double *r, double *a)
{
    double tmp[AR_ORDER];
    double err = r[0];

    for (int j = 0; j < AR_ORDER; j++)
        a[j] = 0.0;

    for (int i = 0; i < AR_ORDER && err > 0.0; i++) {
        double acc = r[i + 1];
        for (int j = 0; j < i; j++)
            acc -= a[j] * r[i - j];
        double k = acc / err;
        for (int j = 0; j < i; j++)
            tmp[j] = a[j] - k * a[i - 1 - j];
        for (int j = 0; j < i; j++)
            a[j] = tmp[j];
        a[i] = k;
        err *= 1.0 - k * k;
    }
}

static void predict_room(critter_data_t *d, int room, double *y, double *acf)
{
    const float *x = d->clean + (size_t)room * SAMPLES_PER_ROOM;
    room_prediction_t *p = &d->pred[room];
    const int n = DEC_LEN;
    const double samples_to_s = DECIMATE * SAMPLE_PERIOD_S;

    /* 1. Decimate, then fit and remove a linear trend */
    double st = 0, sy = 0, stt = 0, sty = 0;
    for (int i = 0; i < n; i++) {
        double s = 0.0;
        for (int k = 0; k < DECIMATE; k++)
            s += x[i * DECIMATE + k];
        y[i] = s / DECIMATE;
        st  += i;
        sy  += y[i];
        stt += (double)i * i;
        sty += i * y[i];
    }
    const double slope = (n * sty - st * sy) / (n * stt - st * st);
    const double icept = (sy - slope * st) / n;
    for (int i = 0; i < n; i++)
        y[i] -= icept + slope * i;
    p->trend_c_per_h = slope * 3600.0 / samples_to_s;

    /* 2. HVAC cycle from the autocorrelation */
    autocorrelation(y, n, acf);
    double period, strength;
    find_cycle(acf, &period, &strength);
    p->cycle_period_s = period * samples_to_s;
    p->cycle_strength = strength;

    /* 3. AR model and its one-step residual error */
    levinson(acf, p->coef);
    double sse = 0.0;
    for (int t = AR_ORDER; t < n; t++) {
        double pred = 0.0;
        for (int j = 0; j < AR_ORDER; j++)
            pred += p->coef[j] * y[t - 1 - j];
        double e = y[t] - pred;
        sse += e * e;
    }
    p->residual_rms = sqrt(sse / (n - AR_ORDER));

    /* 4. Monte Carlo forecast: trend + AR model driven by random residuals */
    const double alarm = d->stats[room].median + ALARM_DELTA_C;
    const double sigma = p->residual_rms;
    uint32_t seed = 0xC0FFEEu + (uint32_t)room * 7919u;
    int crossed = 0;
    double cross_sum = 0.0, end_sum = 0.0;

    for (int m = 0; m < MC_PATHS; m++) {
        double win[AR_ORDER];                  /* win[0] = most recent value */
        for (int j = 0; j < AR_ORDER; j++)
            win[j] = y[n - 1 - j];

        int hit = -1;
        double f = 0.0;
        for (int h = 1; h <= FORECAST_STEPS; h++) {
            double v = 0.0;
            for (int j = 0; j < AR_ORDER; j++)
                v += p->coef[j] * win[j];
            v += sigma * rng_gauss(&seed);
            for (int j = AR_ORDER - 1; j > 0; j--)
                win[j] = win[j - 1];
            win[0] = v;

            f = icept + slope * (n - 1 + h) + v;
            if (hit < 0 && f > alarm)
                hit = h;
        }
        end_sum += f;
        if (hit >= 0) {
            crossed++;
            cross_sum += hit;
        }
    }
    p->alarm_prob     = (double)crossed / MC_PATHS;
    p->alarm_in_s     = crossed ? cross_sum / crossed * samples_to_s : -1.0;
    p->forecast_end_c = end_sum / MC_PATHS;

    /* 5. Classification */
    if (p->trend_c_per_h > TREND_ALARM_C_PER_H || p->alarm_prob >= 0.5)
        p->status = HVAC_WARMING;
    else if (p->cycle_period_s > 0.0 && p->cycle_period_s < SHORT_CYCLE_S)
        p->status = HVAC_SHORT_CYCLING;
    else
        p->status = HVAC_OK;
}

static void predict_rooms(critter_data_t *d, int first, int end)
{
    double *y   = malloc(DEC_LEN * sizeof *y);
    double *acf = malloc((MAX_LAG + 1) * sizeof *acf);
    if (!y || !acf) {
        fprintf(stderr, "compute unit: out of memory\n");
        exit(1);
    }
    for (int r = first; r < end; r++)
        predict_room(d, r, y, acf);
    free(y);
    free(acf);
}

void compute_unit_run(critter_data_t *d)
{
    run_over_rooms(predict_rooms, d);
}

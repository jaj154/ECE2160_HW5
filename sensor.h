/*
 * sensor.h - Temperature sensor interface used by the I/O unit.
 *
 * Implementations:
 *   sensor_sensehat.c  HTS221 on the Raspberry Pi Sense HAT (default)
 *   sensor_sim.c       simulated sensor for testing without hardware
 * Select with:  make SENSOR=sensehat   or   make SENSOR=sim
 */
#ifndef SENSOR_H
#define SENSOR_H

int         sensor_open(void);                    /* 0 on success       */
int         sensor_read_celsius(float *celsius);  /* 0 on success       */
void        sensor_close(void);
const char *sensor_name(void);

#endif /* SENSOR_H */

/*
 * sensor_sensehat.c - HTS221 temperature sensor on the Raspberry Pi Sense HAT.
 *
 * Talks to the chip directly through /dev/i2c-1 (address 0x5F) using combined
 * write-then-read transactions (I2C_RDWR): one system call and one bus
 * transaction per reading. No external libraries are needed.
 *
 * Note: the HTS221 produces new conversions at 12.5 Hz at most. The I/O unit
 * polls far faster than that, so many consecutive reads return the same value;
 * io_report_t.updates counts how many reads actually saw a new value.
 *
 * To use a different HAT or sensor, write a file that implements the four
 * functions in sensor.h and build with SENSOR=<name>.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>
#include "sensor.h"

#define I2C_BUS           "/dev/i2c-1"
#define HTS221_ADDR       0x5F

#define REG_WHO_AM_I      0x0F
#define WHO_AM_I_HTS221   0xBC
#define REG_CTRL_REG1     0x20
#define REG_TEMP_OUT_L    0x2A
#define REG_T0_DEGC_X8    0x32    /* 0x32..0x35: T0/T1 degC x8 and their MSBs */
#define REG_T0_OUT_L      0x3C    /* 0x3C..0x3F: T0_OUT, T1_OUT              */
#define AUTO_INCREMENT    0x80    /* set in register address for multi-byte  */

#define CTRL1_PD          0x80    /* power on                                */
#define CTRL1_BDU         0x04    /* block data update (LSB/MSB consistent)  */
#define CTRL1_ODR_12_5HZ  0x03    /* fastest continuous conversion rate      */

static int     fd = -1;
static uint8_t saved_ctrl1;
static float   t0_degc;
static float   degc_per_count;
static int16_t t0_out;

static int hts_read(uint8_t reg, uint8_t *buf, uint16_t len)
{
    uint8_t addr = (len > 1) ? (uint8_t)(reg | AUTO_INCREMENT) : reg;
    struct i2c_msg msgs[2] = {
        { .addr = HTS221_ADDR, .flags = 0,        .len = 1,   .buf = &addr },
        { .addr = HTS221_ADDR, .flags = I2C_M_RD, .len = len, .buf = buf   },
    };
    struct i2c_rdwr_ioctl_data xfer = { .msgs = msgs, .nmsgs = 2 };
    return ioctl(fd, I2C_RDWR, &xfer) == 2 ? 0 : -1;
}

static int hts_write(uint8_t reg, uint8_t value)
{
    uint8_t buf[2] = { reg, value };
    struct i2c_msg msg = { .addr = HTS221_ADDR, .flags = 0, .len = 2, .buf = buf };
    struct i2c_rdwr_ioctl_data xfer = { .msgs = &msg, .nmsgs = 1 };
    return ioctl(fd, I2C_RDWR, &xfer) == 1 ? 0 : -1;
}

static void fail_close(void)
{
    close(fd);
    fd = -1;
}

int sensor_open(void)
{
    uint8_t who = 0, cal[4], out[4];

    fd = open(I2C_BUS, O_RDWR);
    if (fd < 0) {
        fprintf(stderr,
                "sensor: cannot open %s: %s\n"
                "  Enable I2C (sudo raspi-config > Interface Options > I2C)\n"
                "  and make sure your user is in the 'i2c' group.\n",
                I2C_BUS, strerror(errno));
        return -1;
    }

    if (hts_read(REG_WHO_AM_I, &who, 1) != 0 || who != WHO_AM_I_HTS221) {
        fprintf(stderr,
                "sensor: no HTS221 found at 0x%02X on %s (WHO_AM_I=0x%02X)\n"
                "  Check that the Sense HAT is seated; 'i2cdetect -y 1' should list 5f.\n",
                HTS221_ADDR, I2C_BUS, who);
        fail_close();
        return -1;
    }

    if (hts_read(REG_CTRL_REG1, &saved_ctrl1, 1) != 0 ||
        hts_write(REG_CTRL_REG1, CTRL1_PD | CTRL1_BDU | CTRL1_ODR_12_5HZ) != 0 ||
        hts_read(REG_T0_DEGC_X8, cal, 4) != 0 ||
        hts_read(REG_T0_OUT_L, out, 4) != 0) {
        fprintf(stderr, "sensor: HTS221 configuration failed: %s\n", strerror(errno));
        fail_close();
        return -1;
    }

    /* Factory calibration: two reference points (HTS221 datasheet, sec. 8). */
    float   t0 = (float)(((cal[3] & 0x03) << 8) | cal[0]) / 8.0f;
    float   t1 = (float)(((cal[3] & 0x0C) << 6) | cal[1]) / 8.0f;
    int16_t o0 = (int16_t)((out[1] << 8) | out[0]);
    int16_t o1 = (int16_t)((out[3] << 8) | out[2]);
    if (o1 == o0) {
        fprintf(stderr, "sensor: HTS221 calibration data is invalid\n");
        fail_close();
        return -1;
    }
    t0_degc        = t0;
    t0_out         = o0;
    degc_per_count = (t1 - t0) / (float)(o1 - o0);

    usleep(200000);   /* first conversion after power-on takes ~80 ms */
    return 0;
}

int sensor_read_celsius(float *celsius)
{
    uint8_t b[2];
    if (hts_read(REG_TEMP_OUT_L, b, 2) != 0)
        return -1;
    int16_t raw = (int16_t)((b[1] << 8) | b[0]);
    *celsius = t0_degc + (float)(raw - t0_out) * degc_per_count;
    return 0;
}

void sensor_close(void)
{
    if (fd >= 0) {
        hts_write(REG_CTRL_REG1, saved_ctrl1);   /* leave the chip as we found it */
        close(fd);
        fd = -1;
    }
}

const char *sensor_name(void)
{
    return "Sense HAT HTS221 (I2C 0x5F)";
}

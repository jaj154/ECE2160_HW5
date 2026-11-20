# Critter: compiler-optimization study (Raspberry Pi, C)

Three Critter units, each timed separately, built six ways so you can compare
no optimization, `-O2`, PGO, LTO, and an optional multi-core version.

## Files

| File | Purpose |
|---|---|
| `src/unit_io.c` | **I/O unit** – polls the Sense HAT temperature sensor as fast as the I2C bus allows |
| `src/unit_memory.c` | **Memory unit** – reorganizes data per room, removes outliers (median/MAD), builds summary records |
| `src/unit_compute.c` | **Compute unit** – autocorrelation (HVAC cycle), AR model, Monte Carlo alarm forecast |
| `src/dataset.c` | Expands the real readings into a 64-room deployment (not timed) |
| `src/util.c` | Small helpers used in hot loops of other files (an intentional LTO target) |
| `src/parallel.c` | Splits rooms across cores when built with `-DCRITTER_THREADS` |
| `src/sensor_sensehat.c` | HTS221 driver over `/dev/i2c-1` (no libraries needed) |
| `src/sensor_sim.c` | Simulated sensor for testing without hardware |
| `src/main.c` | Driver: runs and times the three units, prints results |
| `Makefile` | Builds every variant, including the 3-step PGO builds |
| `run_experiments.sh` | Builds, runs all variants interleaved, writes CSVs and a summary table |

## Hardware setup (once)

The code assumes the official **Raspberry Pi Sense HAT** (HTS221 sensor at I2C address 0x5F).

```bash
sudo raspi-config          # Interface Options -> I2C -> Enable, then reboot
sudo apt install i2c-tools # optional, for checking
i2cdetect -y 1             # should show 5f (plus 1c, 46, 5c, 6a on a Sense HAT)
```

Your user must be in the `i2c` group (the default user on Raspberry Pi OS is).
If you use a different HAT, replace `src/sensor_sensehat.c` with a file that
implements the four functions in `src/sensor.h` and build with `SENSOR=<name>`.

## Build and run

```bash
make                      # builds all six variants into build/
./build/critter_o2 -v     # one run, with the per-room HVAC report
./run_experiments.sh      # full study: 5 interleaved runs per variant
RUNS=10 COOLDOWN=5 ./run_experiments.sh
```

Results go to `results/raw_<time>.csv` (every run) and `results/summary_<time>.csv`
(mean, std dev and speedup vs `-O0` per unit). Both import directly into Excel.

| Variant | Flags | What it tests |
|---|---|---|
| `o0` | `-O0` | baseline, no optimization |
| `o2` | `-O2` | full static optimization |
| `o2_lto` | `-O2 -flto=auto` | link-time optimization (cross-file inlining) |
| `o2_pgo` | `-O2` + `-fprofile-generate` → train → `-fprofile-use` | profile-guided optimization |
| `o2_pgo_lto` | both of the above | PGO and LTO together |
| `o2_threads` | `-O2 -DCRITTER_THREADS` | optional multi-core (memory and compute units) |

The PGO steps are visible in the `make` output: an instrumented build, a
training run (which reads the sensor), then a rebuild that uses the `.gcda`
profiles left in `build/o2_pgo/` or `build/o2_pgo_lto/`.

Run `make clean` after changing `SENSOR`, `ARCH` or `EXTRA`.

## Getting trustworthy numbers

Set the CPU governor to `performance` (the script warns if it isn't):
`echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor`.
The script interleaves variants within each round so heat and background
activity affect all of them equally, and it reports `vcgencmd get_throttled`
at the end; if the Pi throttled, add cooling or raise `COOLDOWN` and rerun.
Each unit reports both wall-clock and CPU time, which is useful for showing
where time goes (waiting on the bus vs. computing).

Things worth noting in a write-up: the PGO profile is trained on the same
workload that is measured, which is the best case for PGO; the Sense HAT sits
directly above the CPU, so its readings run warm and rise during long runs
(this does not affect timing); and `-O0` vs `-O2` checksums can differ in the
last digits because `-O2` uses fused multiply-add.

## Workload size

Defaults (in `src/critter.h`): 2000 sensor reads, 64 rooms × 65536 readings
(two 16 MB arrays, far larger than the Pi's caches). To change them:

```bash
make clean && make EXTRA="-DSAMPLES_PER_ROOM=131072 -DIO_SAMPLES=4000"
```

The `-O0` compute unit is the slowest part of a run. If the full study takes
too long on your Pi model, lower `SAMPLES_PER_ROOM` (e.g. 32768); if timings
are too short to separate from noise, raise it.

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

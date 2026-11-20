#!/usr/bin/env bash
# Builds every variant, runs them interleaved, and summarizes the timings.
#
#   ./run_experiments.sh                       5 runs of each variant
#   RUNS=10 COOLDOWN=5 ./run_experiments.sh    more runs, longer pauses
#   VARIANTS="o0 o2" ./run_experiments.sh      subset of variants
#   SENSOR=sim ./run_experiments.sh            no hardware (I/O times meaningless)
#
# Output: results/raw_<time>.csv (every run) and results/summary_<time>.csv
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")"

RUNS=${RUNS:-5}
COOLDOWN=${COOLDOWN:-2}
SENSOR=${SENSOR:-sensehat}
VARIANTS=${VARIANTS:-"o0 o2 o2_lto o2_pgo o2_pgo_lto o2_threads"}

gov=/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
if [[ -r $gov && $(cat "$gov") != performance ]]; then
    echo "WARNING: CPU governor is '$(cat "$gov")'. For stable timings run:"
    echo "  echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor"
    echo
fi

make SENSOR="$SENSOR" $VARIANTS

mkdir -p results
stamp=$(date +%Y%m%d_%H%M%S)
raw=results/raw_$stamp.csv
summary=results/summary_$stamp.csv
echo "variant,run,io_wall_ms,io_cpu_ms,mem_wall_ms,mem_cpu_ms,cmp_wall_ms,cmp_cpu_ms,total_wall_ms" > "$raw"

has_vc=0
command -v vcgencmd > /dev/null 2>&1 && has_vc=1
[[ $has_vc == 1 ]] && echo "Before: $(vcgencmd measure_temp)"

# Interleave variants within each round so slow drift (heat, background
# load) affects every variant equally instead of biasing one of them.
for ((r = 1; r <= RUNS; r++)); do
    for v in $VARIANTS; do
        out=$("./build/critter_$v" -q) || { echo "critter_$v failed" >&2; exit 1; }
        echo "$v,$r,${out#RESULT,$v,}" >> "$raw"
        printf 'round %d/%d  %-11s total %9.1f ms\n' "$r" "$RUNS" "$v" "${out##*,}"
        sleep "$COOLDOWN"
    done
done

if [[ $has_vc == 1 ]]; then
    thr=$(vcgencmd get_throttled)
    echo "After:  $(vcgencmd measure_temp)  $thr"
    [[ $thr == "throttled=0x0" ]] || echo "WARNING: the Pi has throttled since boot (heat or power). Timings may be skewed; add cooling or raise COOLDOWN, reboot, and rerun."
fi

awk -F, -v base=o0 -v out="$summary" '
function mean(v, c)        { return s[v, c] / n[v] }
function sdev(v, c,  m, d) { if (n[v] < 2) return 0; m = mean(v, c)
                             d = (q[v, c] - n[v] * m * m) / (n[v] - 1); return d > 0 ? sqrt(d) : 0 }
NR == 1 { next }
{
    v = $1
    if (!(v in n)) order[++nv] = v
    n[v]++
    for (c = 3; c <= 9; c++) { s[v, c] += $c; q[v, c] += $c * $c }
}
END {
    split("3 5 7 9", col, " "); split("I/O Memory Compute Total", lab, " ")
    printf "\nWall-clock ms per unit: mean, std dev, speedup vs %s  (%d runs each)\n\n", base, n[order[1]]
    printf "%-12s", "variant"
    for (i = 1; i <= 4; i++) printf "  %-27s", lab[i]
    printf "\n"
    print "variant,unit,mean_ms,sd_ms,speedup_vs_" base > out
    for (k = 1; k <= nv; k++) {
        v = order[k]; printf "%-12s", v
        for (i = 1; i <= 4; i++) {
            c = col[i]; m = mean(v, c); b = (base in n) ? mean(base, c) : m
            sp = (m > 0) ? b / m : 0
            printf "  %9.1f +-%7.1f %5.2fx ", m, sdev(v, c), sp
            printf "%s,%s,%.3f,%.3f,%.3f\n", v, lab[i], m, sdev(v, c), sp > out
        }
        printf "\n"
    }
}' "$raw"

echo
echo "Raw data: $raw"
echo "Summary:  $summary"

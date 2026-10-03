#!/usr/bin/env bash
# Drive a host's CPU and GPU to a controlled, reproducible load and capture a
# 1 Hz thermal profile, or diff two such captures.
#
# Driven by `task thermal:bench` / `task thermal:compare` from a checkout, and
# by `nix run github:ianepreston/nixos#thermal-bench` on a host without one
# (amos1). Packaged as `packages.<system>.thermal-bench` in
# modules/flake/packages.nix, which pins stress-ng and a CUDA gpu-burn through
# flake.lock so both halves of a comparison run the same tools. See #757.
#
# Usage:
#   thermal-bench --label <name> --ambient <degC> [--duration <s>]
#                 [--phases idle,cpu,gpu,combined] [--out <dir>]
#                 [--cpu-load matrix|none] [--gpu-load gpu-burn|none]
#                 [--notes <text>]
#   thermal-bench --compare <run-dir-a> <run-dir-b> [--force]
#
# ## Why this exists
#
# It is not monitoring. It produces two artifacts either side of a hardware
# change (terra's NIC in the GPU's air path, amos1's CPU cooler swap) that are
# actually comparable. The observability stack can't do that: terra is outside
# it on purpose, and amos1's 30 s scrape never sees a saturating, controlled
# load — its history is whatever Jellyfin happened to do.
#
# ## What a capture does
#
# Runs the phases in order, sampling every second throughout:
#
#   idle      120 s, fixed. Fan floor and ambient sanity check. The RTX 5080
#             idles at 0 % fan, so this phase is never the comparison.
#   cpu       `stress-ng --matrix 0` — AVX-heavy, hotter than the realistic
#             worst case (a from-source nixos-upgrade, #636). Worst-case
#             hotter is the right load for a headroom question.
#   gpu       `gpu_burn` — a GEMM load that holds the enforced power limit
#             (terra: 360 W, sw_power_cap active throughout), so two runs
#             dissipate the same power. llama.cpp generation is
#             memory-bound and doesn't, which is why it is not offered.
#   combined  Both at once. CPU and GPU compete for the same case air; this
#             is the phase a case-airflow change shows up in.
#
# A phase whose stressor isn't available (no NVIDIA GPU, `--gpu-load none`)
# is skipped and recorded as skipped in meta.json.
#
# 600 s per load phase is enough: on terra (2026-10-03) `combined` reaches its
# CPU plateau at ~160 s and the GPU is already at plateau from the `gpu` phase.
# If a later run's "time to plateau" lands in the last third of a phase,
# raise the default here and say why.
#
# Start from a rested machine. The 120 s idle phase does not undo a previous
# run's heat: two back-to-back runs on terra agreed on GPU °C/W to 0.1 % but on
# the `cpu` phase only to 3.3 %, because the second started warm. Leave the
# host idle for a while before a run that matters.
#
# Output lands in <out>/<host>-<label>-<UTC timestamp>/:
#
#   meta.json     host, board/BIOS, CPU, GPUs (VBIOS, driver, power limit),
#                 the build's flake rev, the phase plan, ambient, notes, the
#                 sampled column set and the sensors that were *absent*.
#   samples.csv   one row per second per phase.
#   counters.json NVIDIA clocks_event_reasons counters (µs) per phase and
#                 across the run. The cleanest throttling evidence there is.
#   summary.json  per-phase statistics, which --compare reads.
#   summary.md    the same, for a human.
#   stressors.log stress-ng / gpu_burn output.
#
# ## Summary statistics
#
# Over the last third of each phase (after the plateau):
#
#   power        confirms the two runs did the same work
#   ΔT           mean temperature minus the hand-entered ambient
#   ΔT/power     °C/W, the thermal-resistance proxy — invariant to ambient
#                and workload power. The headline.
#   fan          GPU fan % and any hwmon fan rpm. A cooler holding the same
#                ΔT at a higher fan duty has regressed.
#   clocks       the user-visible consequence
#   plateau time first second at which the 10 s trailing mean is within
#                1 °C of the plateau — the thermal time constant
#
# Raw peak temperature is deliberately absent: it moves with room temperature
# and with how much power the workload drew.
#
# ## Ambient is a required, hand-entered number
#
# No sensor on these hosts is a usable room reference — amos1's it87 case
# channel swung 3-53 °C over 30 days, terra's acpitz reads 16.8 °C — and an
# unreliable automatic value is worse than a deliberate one. Read a room
# thermometer.
#
# ## Root
#
# CPU package power (RAPL energy_uj) is root-only. As root it is sampled; as
# anyone else the column is omitted with a warning and recorded as absent.
# Because it changes the column set, --compare refuses a root run against a
# non-root one — take both halves the same way (`task thermal:bench` always
# uses sudo). Under sudo the default --out is the invoking user's home and the
# run directory is chowned back to them.
#
# ## --compare
#
# Prints both runs' statistics side by side with deltas. Judges nothing,
# except that it refuses (exit 1, overridable with --force) when the runs are
# not comparable: different column sets, different phase durations, or a load
# phase whose mean power differs by more than 5 %. Note that last one can be
# the *result* — a card that thermally throttles draws less than its limit —
# so with --force read the throttle counters before dismissing it.
#
# ## Known blind spots
#
# terra has no fan tachometer readable at all (gigabyte_wmi exposes six
# unlabelled temps and no fan*_input); the GPU's own fan % is its only fan
# signal. The RTX 5080 exposes no memory/hotspot temperature. Both are
# recorded in meta.json's `absent` list rather than discovered mid-comparison.
#
# A capture is only as clean as the host is quiet: stop anything that would
# load the CPU or GPU (llama-server requests, Jellyfin transcodes,
# nixos-upgrade) before starting.

set -euo pipefail

readonly IDLE_DURATION=120
readonly POWER_TOLERANCE_PCT=5
readonly REV="${THERMAL_BENCH_REV:-unknown}"

die() {
  echo "thermal-bench: $*" >&2
  exit 1
}
warn() { echo "thermal-bench: WARNING: $*" >&2; }
log() { echo "thermal-bench: $*" >&2; }

usage() {
  sed -n '/^# Usage:/,/^# ## Why/{/^# ## Why/d;s/^# \{0,1\}//;p}' "$0" >&2 || true
  exit "${1:-1}"
}

# --- formatting helpers (pure bash: these run every second) ----------------

# milli <int> -> "<int/1000>.<3 decimals>" into the variable named by $2.
# Locals are underscored so they can't shadow the caller's target variable.
milli() {
  local _mv=$1 _ms=""
  if ((_mv < 0)); then
    _ms="-"
    _mv=$((-_mv))
  fi
  printf -v "$2" '%s%d.%03d' "$_ms" $((_mv / 1000)) $((_mv % 1000))
}

now_us() {
  local t=${EPOCHREALTIME/./}
  echo "$t"
}

sanitize() {
  local s=${1,,}
  s=${s//[^a-z0-9]/_}
  while [[ $s == *__* ]]; do s=${s//__/_}; done
  s=${s#_}
  s=${s%_}
  echo "$s"
}

# --- sensor discovery ------------------------------------------------------

# Parallel arrays: column name, sysfs file, kind (temp|fan).
HW_COLS=()
HW_FILES=()
HW_KINDS=()
CPU_TEMP_FILE=""
CPU_TEMP_SOURCE=""
RAPL_FILE=""
RAPL_MAX=0
CPUFREQ_FILES=()
GPU_COUNT=0
ABSENT=()

discover_hwmon() {
  local dir name dev key f base label kind suffix
  declare -A seen=()
  for dir in /sys/class/hwmon/hwmon*; do
    [[ -r $dir/name ]] || continue
    name=$(<"$dir/name")
    seen[$name]=$((${seen[$name]:-0} + 1))
  done
  for dir in /sys/class/hwmon/hwmon*; do
    [[ -r $dir/name ]] || continue
    name=$(<"$dir/name")
    key=$(sanitize "$name")
    # hwmonN numbering is not stable across boots, so disambiguate repeated
    # chips (terra's two spd5118 DIMMs) by their device path, which is.
    if ((${seen[$name]} > 1)); then
      dev=$(readlink -f "$dir/device" 2>/dev/null || echo "$dir")
      key+="_$(sanitize "${dev##*/}")"
    fi
    for f in "$dir"/temp*_input "$dir"/fan*_input; do
      [[ -r $f ]] || continue
      # A sensor that errors on read (common for unpopulated fan headers)
      # would error every second; leave it out.
      cat "$f" >/dev/null 2>&1 || continue
      base=${f##*/}
      base=${base%_input}
      kind=${base%%[0-9]*}
      label=$base
      if [[ -r $dir/${base}_label ]]; then
        label=$(<"$dir/${base}_label")
      fi
      if [[ $kind == temp ]]; then suffix=c; else suffix=rpm; fi
      HW_COLS+=("${key}_$(sanitize "$label")_${suffix}")
      HW_FILES+=("$f")
      HW_KINDS+=("$kind")
      if [[ $name == k10temp && $label == Tctl ]]; then
        CPU_TEMP_FILE=$f
        CPU_TEMP_SOURCE="k10temp Tctl"
      elif [[ $name == coretemp && $label == "Package id 0" && -z $CPU_TEMP_FILE ]]; then
        CPU_TEMP_FILE=$f
        CPU_TEMP_SOURCE="coretemp Package id 0"
      fi
    done
  done
  if [[ -z $CPU_TEMP_FILE ]]; then
    ABSENT+=("cpu_temp: no k10temp Tctl or coretemp package sensor")
  fi
  local k have_fan=0
  for k in "${HW_KINDS[@]}"; do [[ $k == fan ]] && have_fan=1; done
  if ((!have_fan)); then
    ABSENT+=("fan_rpm: no hwmon fan*_input on this host")
  fi
}

discover_rapl() {
  local f=/sys/class/powercap/intel-rapl:0/energy_uj
  if [[ ! -e $f ]]; then
    ABSENT+=("pkg_power_w: no RAPL powercap domain")
  elif ! cat "$f" >/dev/null 2>&1; then
    ABSENT+=("pkg_power_w: RAPL energy_uj is root-only")
    warn "not running as root: CPU package power will NOT be sampled, and"
    warn "this run will not --compare against a root run. Use sudo for both."
  else
    RAPL_FILE=$f
    RAPL_MAX=$(<"${f%/*}/max_energy_range_uj")
  fi
}

discover_cpufreq() {
  local f
  for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do
    [[ -r $f ]] && CPUFREQ_FILES+=("$f")
  done
  if ((${#CPUFREQ_FILES[@]} == 0)); then
    ABSENT+=("cpu_freq_mhz: no cpufreq scaling_cur_freq")
  fi
}

readonly GPU_QUERY=temperature.gpu,temperature.gpu.tlimit,fan.speed,power.draw,clocks.sm,utilization.gpu,pcie.link.gen.current,pcie.link.width.current,clocks_throttle_reasons.active
readonly GPU_FIELDS=(temp_c tlimit_c fan_pct power_w sm_mhz util_pct pcie_gen pcie_width throttle_hex)
readonly GPU_COUNTERS=clocks_event_reasons_counters.hw_thermal_slowdown,clocks_event_reasons_counters.sw_thermal_slowdown,clocks_event_reasons_counters.sw_power_cap

discover_gpu() {
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    ABSENT+=("gpu: no nvidia-smi")
    return
  fi
  GPU_COUNT=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | grep -c . || true)
  if ((GPU_COUNT == 0)); then
    ABSENT+=("gpu: nvidia-smi reports no GPUs")
    return
  fi
  # Fields a card reports as N/A at idle are absent for good (the RTX 3070
  # has no tlimit; neither card has a memory temperature). Record which.
  local i line field
  local -a vals
  for ((i = 0; i < GPU_COUNT; i++)); do
    line=$(nvidia-smi -i "$i" --query-gpu="$GPU_QUERY" --format=csv,noheader,nounits)
    IFS=',' read -ra vals <<<"$line"
    for field in "${!GPU_FIELDS[@]}"; do
      if [[ ${vals[$field]} == *N/A* ]]; then
        ABSENT+=("gpu${i}_${GPU_FIELDS[$field]}: nvidia-smi reports N/A")
      fi
    done
    line=$(nvidia-smi -i "$i" --query-gpu=temperature.memory --format=csv,noheader,nounits)
    if [[ $line == *N/A* ]]; then
      ABSENT+=("gpu${i}_memory_temp_c: nvidia-smi reports N/A")
    fi
  done
}

# --- sampling --------------------------------------------------------------

PREV_STAT_TOTAL=0
PREV_STAT_IDLE=0
PREV_ENERGY=0
PREV_T_US=0

read_stat() {
  local _cpu user nice system idle iowait irq softirq steal _rest
  read -r _cpu user nice system idle iowait irq softirq steal _rest </proc/stat
  STAT_TOTAL=$((user + nice + system + idle + iowait + irq + softirq + steal))
  STAT_IDLE=$((idle + iowait))
}

prime_sampler() {
  read_stat
  PREV_STAT_TOTAL=$STAT_TOTAL
  PREV_STAT_IDLE=$STAT_IDLE
  [[ -n $RAPL_FILE ]] && PREV_ENERGY=$(<"$RAPL_FILE")
  PREV_T_US=$(now_us)
}

header() {
  local cols=(t_s phase cpu_temp_c cpu_busy_frac cpu_freq_mhz)
  [[ -n $RAPL_FILE ]] && cols+=(pkg_power_w)
  local i f
  for ((i = 0; i < GPU_COUNT; i++)); do
    for f in "${GPU_FIELDS[@]}"; do cols+=("gpu${i}_$f"); done
  done
  cols+=("${HW_COLS[@]}")
  local IFS=,
  echo "${cols[*]}"
}

# One CSV row on stdout for second $1 of phase $2.
sample() {
  local t=$1 phase=$2 v out t_us
  local -a row=("$t" "$phase")

  if [[ -n $CPU_TEMP_FILE ]]; then
    milli "$(<"$CPU_TEMP_FILE")" v
    row+=("$v")
  else
    row+=("")
  fi

  read_stat
  local dt=$((STAT_TOTAL - PREV_STAT_TOTAL)) di=$((STAT_IDLE - PREV_STAT_IDLE))
  if ((dt > 0)); then milli $(((dt - di) * 1000 / dt)) v; else v=""; fi
  row+=("$v")
  PREV_STAT_TOTAL=$STAT_TOTAL
  PREV_STAT_IDLE=$STAT_IDLE

  if ((${#CPUFREQ_FILES[@]})); then
    local sum=0 f
    for f in "${CPUFREQ_FILES[@]}"; do sum=$((sum + $(<"$f"))); done
    row+=("$((sum / ${#CPUFREQ_FILES[@]} / 1000))")
  else
    row+=("")
  fi

  t_us=$(now_us)
  if [[ -n $RAPL_FILE ]]; then
    local e de
    e=$(<"$RAPL_FILE")
    de=$((e - PREV_ENERGY))
    ((de < 0)) && de=$((de + RAPL_MAX))
    # µJ / µs = W; scale by 1000 for three decimals.
    milli $((de * 1000 / (t_us - PREV_T_US))) v
    row+=("$v")
    PREV_ENERGY=$e
  fi
  PREV_T_US=$t_us

  if ((GPU_COUNT)); then
    local line
    local -a vals
    local -i n=0 j
    while IFS= read -r line; do
      IFS=',' read -ra vals <<<"${line// /}"
      # A driver hiccup can return an error line instead of the fields;
      # pad or truncate so later columns never shift.
      for ((j = 0; j < ${#GPU_FIELDS[@]}; j++)); do
        v=${vals[$j]:-}
        [[ $v == *N/A* || ${#vals[@]} -ne ${#GPU_FIELDS[@]} ]] && v=""
        row+=("$v")
      done
      n+=1
    done < <(nvidia-smi --query-gpu="$GPU_QUERY" --format=csv,noheader,nounits 2>/dev/null || true)
    for (( ; n < GPU_COUNT; n++)); do
      for ((j = 0; j < ${#GPU_FIELDS[@]}; j++)); do row+=(""); done
    done
  fi

  local i
  for i in "${!HW_FILES[@]}"; do
    v=$(<"${HW_FILES[$i]}")
    if [[ ${HW_KINDS[$i]} == temp ]]; then milli "$v" v; fi
    row+=("$v")
  done

  local IFS=,
  out="${row[*]}"
  echo "$out"
}

read_counters() {
  # -> JSON array, one object per GPU, values in µs.
  if ((!GPU_COUNT)); then
    echo '[]'
    return
  fi
  nvidia-smi --query-gpu="$GPU_COUNTERS" --format=csv,noheader,nounits |
    jq -R -s 'split("\n") | map(select(length > 0) | split(",") | map(gsub(" "; "") | tonumber? // null)
      | {hw_thermal_slowdown_us: .[0], sw_thermal_slowdown_us: .[1], sw_power_cap_us: .[2]})'
}

# --- stressors -------------------------------------------------------------

STRESS_PIDS=()

start_stressors() {
  local phase=$1 seconds=$2 log=$3
  # setsid: each stressor leads its own process group, so stop_stressors
  # takes down stress-ng's workers and gpu_burn's per-GPU children too. The
  # stressor's own timeout is a backstop if this script is SIGKILLed.
  if [[ $phase == cpu || $phase == combined ]]; then
    setsid stress-ng --matrix 0 --timeout "$((seconds + 10))s" >>"$log" 2>&1 &
    STRESS_PIDS+=("$!")
  fi
  if [[ $phase == gpu || $phase == combined ]]; then
    (cd "${TMPDIR:-/tmp}" && exec setsid gpu_burn "$((seconds + 10))") >>"$log" 2>&1 &
    STRESS_PIDS+=("$!")
  fi
}

stop_stressors() {
  local p
  for p in "${STRESS_PIDS[@]}"; do
    kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true
  done
  for p in "${STRESS_PIDS[@]}"; do wait "$p" 2>/dev/null || true; done
  STRESS_PIDS=()
}

# --- summary ---------------------------------------------------------------

# samples.csv + meta.json + counters.json -> summary.json
summarize() {
  local dir=$1
  jq -R -s \
    --slurpfile meta "$dir/meta.json" \
    --slurpfile counters "$dir/counters.json" '
    def mean: map(select(. != null)) | if length == 0 then null else add / length end;
    def r(n): if . == null then null else (. * pow(10; n) | round) / pow(10; n) end;
    # First second at which the 10 s trailing mean of `xs` is within 1 degC
    # of `plateau`.
    def plateau_s(xs; plateau):
      if plateau == null then null else
        [range(0; xs | length) as $i
          | (xs[([0, $i - 9] | max):$i + 1] | mean) as $m
          | select($m != null and (($m - plateau) | fabs) <= 1) | $i] | first // null
      end;

    $meta[0] as $meta
    | $meta.ambient_c as $amb
    | split("\n") | map(select(length > 0) | split(",")) as $lines
    | $lines[0] as $cols
    | ($lines[1:] | map([$cols, .] | transpose
        | map({key: .[0], value: (.[1] | if . == "" then null else (tonumber? // .) end)})
        | from_entries)) as $rows
    | ($cols | map(select(test("_rpm$")))) as $fancols
    | {
        run: ($meta.host + " " + $meta.label + " " + $meta.started_utc),
        ambient_c: $amb,
        window: "last third of each phase",
        phases: [
          $meta.phases[] | .name as $p | .duration_s as $dur
          | ($rows | map(select(.phase == $p))) as $all
          | ($all | map(select(.t_s >= ($dur * 2 / 3 | floor)))) as $w
          | {
              name: $p,
              duration_s: $dur,
              cpu: (
                ($w | map(.cpu_temp_c) | mean) as $t
                | ($w | map(.pkg_power_w) | mean) as $pw
                | {
                    temp_c: ($t | r(1)),
                    delta_t_c: (if $t == null then null else ($t - $amb) | r(1) end),
                    power_w: ($pw | r(1)),
                    c_per_w: (if $t == null or $pw == null or $pw <= 0 then null
                              else (($t - $amb) / $pw) | r(4) end),
                    freq_mhz: ($w | map(.cpu_freq_mhz) | mean | r(0)),
                    busy_frac: ($w | map(.cpu_busy_frac) | mean | r(3)),
                    plateau_s: plateau_s($all | map(.cpu_temp_c); $t)
                  }
              ),
              gpus: [
                range(0; $meta.gpu_count) as $g
                | ("gpu\($g)_") as $k
                | ($w | map(.[$k + "temp_c"]) | mean) as $t
                | ($w | map(.[$k + "power_w"]) | mean) as $pw
                | {
                    index: $g,
                    temp_c: ($t | r(1)),
                    delta_t_c: (if $t == null then null else ($t - $amb) | r(1) end),
                    power_w: ($pw | r(1)),
                    c_per_w: (if $t == null or $pw == null or $pw <= 0 then null
                              else (($t - $amb) / $pw) | r(4) end),
                    fan_pct: ($w | map(.[$k + "fan_pct"]) | mean | r(1)),
                    sm_mhz: ($w | map(.[$k + "sm_mhz"]) | mean | r(0)),
                    util_pct: ($w | map(.[$k + "util_pct"]) | mean | r(1)),
                    plateau_s: plateau_s($all | map(.[$k + "temp_c"]); $t),
                    throttle_us: ($counters[0].phases[$p][$g] // null)
                  }
              ],
              fans_rpm: ($fancols | map(. as $c | {key: $c, value: ($w | map(.[$c]) | mean | r(0))})
                         | from_entries)
            }
        ],
        throttle_us_total: $counters[0].delta
      }
  ' "$dir/samples.csv"
}

render_md() {
  jq -r '
    def f: if . == null then "n/a" else tostring end;
    "# thermal-bench: \(.run)\n",
    "Ambient \(.ambient_c) °C (hand-entered). Statistics are means over the \(.window).\n",
    (.phases[] |
      "## \(.name) (\(.duration_s) s)\n",
      "| Metric | Value |",
      "| --- | --- |",
      "| CPU power (W) | \(.cpu.power_w | f) |",
      "| CPU temp (°C) | \(.cpu.temp_c | f) |",
      "| CPU ΔT (°C) | \(.cpu.delta_t_c | f) |",
      "| **CPU ΔT/power (°C/W)** | **\(.cpu.c_per_w | f)** |",
      "| CPU freq (MHz) | \(.cpu.freq_mhz | f) |",
      "| CPU busy | \(.cpu.busy_frac | f) |",
      "| CPU time to plateau (s) | \(.cpu.plateau_s | f) |",
      (.gpus[] |
        "| GPU\(.index) power (W) | \(.power_w | f) |",
        "| GPU\(.index) temp (°C) | \(.temp_c | f) |",
        "| GPU\(.index) ΔT (°C) | \(.delta_t_c | f) |",
        "| **GPU\(.index) ΔT/power (°C/W)** | **\(.c_per_w | f)** |",
        "| GPU\(.index) fan (%) | \(.fan_pct | f) |",
        "| GPU\(.index) SM clock (MHz) | \(.sm_mhz | f) |",
        "| GPU\(.index) utilisation (%) | \(.util_pct | f) |",
        "| GPU\(.index) time to plateau (s) | \(.plateau_s | f) |",
        (.throttle_us // {} | to_entries[] | "| GPU throttle Δ \(.key) | \(.value) |")),
      (.fans_rpm | to_entries[] | "| \(.key) | \(.value | f) |"),
      ""),
    (if (.throttle_us_total | length) > 0 then
      "## Throttle counters, whole run (µs)\n",
      "| GPU | hw thermal | sw thermal | sw power cap |",
      "| --- | --- | --- | --- |",
      (.throttle_us_total | to_entries[] |
        "| \(.key) | \(.value.hw_thermal_slowdown_us | f) | \(.value.sw_thermal_slowdown_us | f) | \(.value.sw_power_cap_us | f) |")
    else empty end)
  ' "$1"
}

# --- compare ---------------------------------------------------------------

compare() {
  local a=$1 b=$2 force=$3 f
  for f in meta.json summary.json; do
    [[ -r $a/$f ]] || die "$a/$f not found"
    [[ -r $b/$f ]] || die "$b/$f not found"
  done
  local problems
  problems=$(jq -n -r \
    --slurpfile ma "$a/meta.json" --slurpfile mb "$b/meta.json" \
    --slurpfile sa "$a/summary.json" --slurpfile sb "$b/summary.json" \
    --argjson tol "$POWER_TOLERANCE_PCT" '
    $ma[0] as $ma | $mb[0] as $mb | $sa[0] as $sa | $sb[0] as $sb
    | def pct(x; y): if x == null or y == null or x == 0 then null else ((y - x) / x * 100 | fabs) end;
    [
      (if $ma.host != $mb.host then "different hosts: \($ma.host) vs \($mb.host)" else empty end),
      (($ma.columns - $mb.columns) as $o | ($mb.columns - $ma.columns) as $n
        | if ($o | length) + ($n | length) > 0 then
            "different sensor sets — only in A: \($o | join(" ") | if . == "" then "(none)" else . end); only in B: \($n | join(" ") | if . == "" then "(none)" else . end)"
          else empty end),
      ($ma.phases[] as $pa | $mb.phases[] | select(.name == $pa.name and .duration_s != $pa.duration_s)
        | "phase \(.name): duration \($pa.duration_s) s vs \(.duration_s) s"),
      ($sa.phases[] as $pa | $sb.phases[] | select(.name == $pa.name) as $pb
        | (if ($pa.name == "cpu" or $pa.name == "combined")
             and (pct($pa.cpu.power_w; $pb.cpu.power_w) // 0) > $tol then
             "phase \($pa.name): CPU power \($pa.cpu.power_w) W vs \($pb.cpu.power_w) W (> \($tol) % apart)"
           else empty end),
          ($pa.gpus[] as $ga | $pb.gpus[] | select(.index == $ga.index)
            | select(($pa.name == "gpu" or $pa.name == "combined")
                     and (pct($ga.power_w; .power_w) // 0) > $tol)
            | "phase \($pa.name): GPU\(.index) power \($ga.power_w) W vs \(.power_w) W (> \($tol) % apart)")
      )
    ] | .[]')
  if [[ -n $problems ]]; then
    echo "These runs are not comparable:" >&2
    while IFS= read -r f; do echo "  - $f" >&2; done <<<"$problems"
    if [[ $force != 1 ]]; then
      echo "Refusing. Pass --force to print the comparison anyway." >&2
      exit 1
    fi
    echo "--force given; comparing anyway. Read the deltas with that in mind." >&2
  fi

  jq -n -r \
    --slurpfile sa "$a/summary.json" --slurpfile sb "$b/summary.json" '
    $sa[0] as $sa | $sb[0] as $sb
    | def f: if . == null then "n/a" else tostring end;
    def row(name; x; y):
      "| \(name) | \(x | f) | \(y | f) | "
      + (if x == null or y == null then "n/a | n/a"
         else "\(((y - x) * 10000 | round) / 10000) | "
              + (if x == 0 then "n/a" else "\(((y - x) / x * 1000 | round) / 10) %" end)
         end) + " |";
    def metrics:
      [["CPU power (W)", .cpu.power_w], ["CPU ΔT (°C)", .cpu.delta_t_c],
       ["**CPU ΔT/power (°C/W)**", .cpu.c_per_w], ["CPU freq (MHz)", .cpu.freq_mhz],
       ["CPU time to plateau (s)", .cpu.plateau_s]]
      + [.gpus[] | . as $g
         | ["GPU\($g.index) power (W)", $g.power_w], ["GPU\($g.index) ΔT (°C)", $g.delta_t_c],
           ["**GPU\($g.index) ΔT/power (°C/W)**", $g.c_per_w], ["GPU\($g.index) fan (%)", $g.fan_pct],
           ["GPU\($g.index) SM clock (MHz)", $g.sm_mhz],
           ["GPU\($g.index) time to plateau (s)", $g.plateau_s],
           (($g.throttle_us // {}) | to_entries[] | ["GPU\($g.index) throttle Δ \(.key)", .value])]
      + [.fans_rpm | to_entries[] | [.key, .value]];
    "# thermal-bench compare\n",
    "- A: \($sa.run) (ambient \($sa.ambient_c) °C)",
    "- B: \($sb.run) (ambient \($sb.ambient_c) °C)\n",
    ($sa.phases[] as $pa | $sb.phases[] | select(.name == $pa.name) as $pb
      | "## \($pa.name)\n",
        "| Metric | A | B | B − A | Δ % |",
        "| --- | --- | --- | --- | --- |",
        (($pa | metrics) as $ma | ($pb | metrics) as $mb
          | $ma[] as $x | ($mb[] | select(.[0] == $x[0])) as $y
          | row($x[0]; $x[1]; $y[1])),
        "")
  '
}

# --- main ------------------------------------------------------------------

main() {
  local label="" ambient="" duration=600 phases="idle,cpu,gpu,combined" out=""
  local cpu_load=matrix gpu_load=gpu-burn notes="" compare_a="" compare_b="" force=0

  while (($#)); do
    case $1 in
      --label)
        label=${2:?}
        shift 2
        ;;
      --ambient)
        ambient=${2:?}
        shift 2
        ;;
      --duration)
        duration=${2:?}
        shift 2
        ;;
      --phases)
        phases=${2:?}
        shift 2
        ;;
      --out)
        out=${2:?}
        shift 2
        ;;
      --cpu-load)
        cpu_load=${2:?}
        shift 2
        ;;
      --gpu-load)
        gpu_load=${2:?}
        shift 2
        ;;
      --notes)
        notes=${2:?}
        shift 2
        ;;
      --compare)
        compare_a=${2:?}
        compare_b=${3:?--compare takes two run directories}
        shift 3
        ;;
      --force)
        force=1
        shift
        ;;
      -h | --help) usage 0 ;;
      *) die "unknown argument: $1 (see --help)" ;;
    esac
  done

  if [[ -n $compare_a ]]; then
    compare "$compare_a" "$compare_b" "$force"
    return
  fi

  [[ -n $label ]] || die "--label is required"
  [[ $label =~ ^[A-Za-z0-9._-]+$ ]] || die "--label may only contain letters, digits, . _ -"
  [[ -n $ambient ]] || die "--ambient is required: read a room thermometer (°C). No sensor here is a usable reference."
  [[ $ambient =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || die "--ambient must be a number in °C"
  if ! [[ $duration =~ ^[0-9]+$ ]] || ((duration < 30)); then
    die "--duration must be an integer >= 30"
  fi
  [[ $cpu_load == matrix || $cpu_load == none ]] || die "--cpu-load must be matrix or none"
  [[ $gpu_load == gpu-burn || $gpu_load == none ]] || die "--gpu-load must be gpu-burn or none"

  local host user_home owner=""
  host=$(hostname)
  user_home=$HOME
  if ((EUID == 0)) && [[ -n ${SUDO_USER:-} ]]; then
    user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    owner=$SUDO_USER
  fi
  out=${out:-$user_home/thermal-bench}

  discover_hwmon
  discover_rapl
  discover_cpufreq
  discover_gpu

  # Resolve the phase plan against what this host can actually load.
  local -a plan=() skipped=()
  local p reason
  IFS=',' read -ra req <<<"$phases"
  for p in "${req[@]}"; do
    reason=""
    case $p in
      idle) ;;
      cpu) [[ $cpu_load == none ]] && reason="--cpu-load none" ;;
      gpu)
        if [[ $gpu_load == none ]]; then
          reason="--gpu-load none"
        elif ((!GPU_COUNT)); then reason="no NVIDIA GPU"; fi
        ;;
      combined)
        if [[ $cpu_load == none ]]; then
          reason="--cpu-load none"
        elif [[ $gpu_load == none ]]; then
          reason="--gpu-load none"
        elif ((!GPU_COUNT)); then reason="no NVIDIA GPU"; fi
        ;;
      *) die "unknown phase: $p (idle, cpu, gpu, combined)" ;;
    esac
    if [[ -n $reason ]]; then
      skipped+=("$p: $reason")
      warn "skipping phase $p ($reason)"
    else
      plan+=("$p")
    fi
  done
  ((${#plan[@]})) || die "no phases left to run"

  local started dir
  started=$(date -u +%Y%m%dT%H%MZ)
  dir=$out/$host-$label-$started
  mkdir -p "$dir"
  log "writing to $dir"

  local -a columns
  IFS=',' read -ra columns <<<"$(header)"

  # meta.json
  local gpus='[]'
  if ((GPU_COUNT)); then
    gpus=$(nvidia-smi --query-gpu=index,name,vbios_version,driver_version,enforced.power.limit \
      --format=csv,noheader,nounits | jq -R -s 'split("\n") | map(select(length > 0)
        | split(", ") | {index: (.[0] | tonumber), name: .[1], vbios: .[2], driver: .[3],
                         enforced_power_limit_w: (.[4] | tonumber? // null)})')
  fi
  local plan_json
  plan_json=$(for p in "${plan[@]}"; do
    if [[ $p == idle ]]; then echo "$p $IDLE_DURATION"; else echo "$p $duration"; fi
  done | jq -R -s 'split("\n") | map(select(length > 0) | split(" ")
    | {name: .[0], duration_s: (.[1] | tonumber)})')
  dmi() { cat "/sys/class/dmi/id/$1" 2>/dev/null || echo unknown; }
  lines_json() { jq -R -s 'split("\n") | map(select(length > 0))'; }
  jq -n \
    --arg host "$host" --arg label "$label" --arg started "$started" \
    --arg kernel "$(uname -r)" --arg rev "$REV" \
    --arg board_vendor "$(dmi board_vendor)" --arg board_name "$(dmi board_name)" \
    --arg bios "$(dmi bios_version)" \
    --arg cpu "$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1)" \
    --arg cpu_temp_source "$CPU_TEMP_SOURCE" \
    --argjson ambient "$ambient" --arg notes "$notes" \
    --argjson root "$([[ -n $RAPL_FILE ]] && echo true || echo false)" \
    --arg cpu_load "$cpu_load" --arg gpu_load "$gpu_load" \
    --arg stress_ng "$(stress-ng --version 2>/dev/null | head -1)" \
    --arg gpu_burn "$(command -v gpu_burn || echo none)" \
    --argjson gpus "$gpus" --argjson phases "$plan_json" \
    --argjson skipped "$(printf '%s\n' "${skipped[@]}" | lines_json)" \
    --argjson columns "$(printf '%s\n' "${columns[@]}" | lines_json)" \
    --argjson absent "$(printf '%s\n' "${ABSENT[@]}" | lines_json)" \
    '{
      host: $host, label: $label, started_utc: $started, kernel: $kernel,
      flake_rev: $rev,
      board: {vendor: $board_vendor, name: $board_name, bios: $bios},
      cpu: $cpu, cpu_temp_source: $cpu_temp_source,
      gpu_count: ($gpus | length), gpus: $gpus,
      ambient_c: $ambient, ambient_source: "--ambient, hand-entered",
      notes: $notes, pkg_power_sampled: $root,
      loads: {cpu: $cpu_load, gpu: $gpu_load},
      tools: {stress_ng: $stress_ng, gpu_burn: $gpu_burn},
      phases: $phases, skipped_phases: $skipped,
      columns: $columns, absent: $absent
    }' >"$dir/meta.json"

  if ((${#ABSENT[@]})); then
    log "absent on this host (recorded in meta.json):"
    printf '  - %s\n' "${ABSENT[@]}" >&2
  fi

  trap 'stop_stressors; exit 130' INT TERM
  trap 'stop_stressors' EXIT

  local before counters_phases='{}' c0 c1 seconds t next_us sleep_us
  before=$(read_counters)
  header >"$dir/samples.csv"
  prime_sampler
  for p in "${plan[@]}"; do
    if [[ $p == idle ]]; then seconds=$IDLE_DURATION; else seconds=$duration; fi
    log "phase $p: ${seconds} s"
    c0=$(read_counters)
    start_stressors "$p" "$seconds" "$dir/stressors.log"
    next_us=$(now_us)
    for ((t = 0; t < seconds; t++)); do
      next_us=$((next_us + 1000000))
      sample "$t" "$p" >>"$dir/samples.csv"
      sleep_us=$((next_us - $(now_us)))
      if ((sleep_us > 0)); then
        sleep "$(printf '%d.%06d' $((sleep_us / 1000000)) $((sleep_us % 1000000)))"
      fi
    done
    stop_stressors
    c1=$(read_counters)
    counters_phases=$(jq -n --argjson acc "$counters_phases" --arg p "$p" \
      --argjson a "$c0" --argjson b "$c1" \
      '$acc + {($p): [range(0; $a | length) as $i
        | $a[$i] | to_entries | map({key, value: ($b[$i][.key] - .value)}) | from_entries]}')
  done
  trap - INT TERM EXIT

  jq -n --argjson a "$before" --argjson b "$(read_counters)" --argjson phases "$counters_phases" \
    '{before: $a, after: $b, phases: $phases,
      delta: [range(0; $a | length) as $i
        | $a[$i] | to_entries | map({key, value: ($b[$i][.key] - .value)}) | from_entries]}' \
    >"$dir/counters.json"

  summarize "$dir" >"$dir/summary.json"
  render_md "$dir/summary.json" >"$dir/summary.md"
  [[ -n $owner ]] && chown -R "$owner:" "$dir"

  cat "$dir/summary.md"
  log "done: $dir"
}

main "$@"

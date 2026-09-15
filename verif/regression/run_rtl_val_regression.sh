#!/usr/bin/env bash
# run_rtl_val_regression.sh -- builds and runs the ASSEMBLED RTL PIPELINE
# (verif/sim_trace/run_trace_report.sv) against all 8 official course
# configs (val_configs.csv), for both real traces (gcc1, perl1), and
# compares BOTH the final summary (Dynamic Instruction Count / Cycles /
# IPC) AND the full per-instruction FE{}...RT{} report against the
# golden model's own val*.txt answer key.
#
# Each config's full per-instruction report is saved as its own clean
# file (same format as golden/vectors/val*.txt) at:
#   logs/val_rtl_reports/<config_name>_report.txt
#
# Usage: ./run_rtl_val_regression.sh [config_name ...]
#   No arguments: runs all 8 configs (val1..val8).
#   With arguments: runs only the named configs, e.g.
#     ./run_rtl_val_regression.sh val1 val2
#   (useful for a quick check without waiting for the larger configs)
set -u
cd "$(dirname "$0")"

RTL_ROOT="../.."
RTL_FILES="rtl/ooo_pkg.sv rtl/pipe_reg.sv rtl/sched_reg.sv rtl/rmt.sv rtl/rob.sv rtl/issue_queue.sv rtl/exec_units.sv rtl/ooo_pipeline.sv"
RUN_TRACE_TB="verif/sim_trace/run_trace_report.sv"
VECTORS_DIR="golden/vectors"
CONFIGS_CSV="verif/regression/val_configs.csv"
WORKDIR="/tmp/ooo_rtl_val_regression"
REPORTS_DIR="logs/val_rtl_reports"
TIMEOUT_SECS=1800   # 30 min ceiling per config -- the larger ROB/IQ configs (val7/val8) are slower to elaborate and simulate

mkdir -p "$WORKDIR"
cd "$RTL_ROOT"
mkdir -p "$REPORTS_DIR"

FAIL=0
ONLY_THESE=("$@")

want_config () {
  local name="$1"
  if [ ${#ONLY_THESE[@]} -eq 0 ]; then return 0; fi
  for x in "${ONLY_THESE[@]}"; do [ "$x" = "$name" ] && return 0; done
  return 1
}

# Extract "Dynamic Instruction Count", "Cycles", "Instructions Per Cycle (IPC)"
# from a report file (works on both golden's and the RTL runner's output,
# same format) into three shell variables via a tiny inline python parse.
extract_summary () {
  python3 - "$1" <<'PYEOF'
import re, sys
text = open(sys.argv[1]).read()
def grab(key):
    m = re.search(re.escape(key) + r'\s*=\s*([\d.]+)', text)
    return m.group(1) if m else "MISSING"
print(grab("Dynamic Instruction Count"), grab("Cycles"), grab("Instructions Per Cycle (IPC)"))
PYEOF
}

while IFS=',' read -r name rob iq width trace expected; do
  [[ "$name" =~ ^#.*$ || -z "$name" ]] && continue
  want_config "$name" || continue

  echo "=== $name (ROB_SIZE=$rob IQ_SIZE=$iq WIDTH=$width trace=$trace) ==="
  mdir="${WORKDIR}/obj_dir_${name}"
  rm -rf "$mdir"

  if ! verilator --binary -j 0 --timing -Wno-fatal -Irtl \
        -GWIDTH="$width" -GROB_SIZE="$rob" -GIQ_SIZE="$iq" \
        --Mdir "$mdir" \
        $RTL_FILES "$RUN_TRACE_TB" \
        --top-module run_trace_report -o "vrun_${name}" \
        > "${WORKDIR}/${name}.compile.log" 2>&1; then
    echo "  COMPILE FAILED (see ${WORKDIR}/${name}.compile.log)"
    FAIL=1
    echo
    continue
  fi

  if ! timeout "$TIMEOUT_SECS" "${mdir}/vrun_${name}" \
        +trace="${VECTORS_DIR}/${trace}" \
        > "${WORKDIR}/${name}.run.log" 2>&1; then
    echo "  RUN TIMED OUT OR CRASHED after ${TIMEOUT_SECS}s (see ${WORKDIR}/${name}.run.log)"
    tail -5 "${WORKDIR}/${name}.run.log"
    FAIL=1
    echo
    continue
  fi

  # Save a clean, val*.txt-format copy of this config's full per-
  # instruction report (instruction lines + summary, no simulator noise)
  grep -E "^[0-9]|^#" "${WORKDIR}/${name}.run.log" > "${REPORTS_DIR}/${name}_report.txt"

  read -r rtl_count rtl_cycles rtl_ipc <<< "$(extract_summary "${WORKDIR}/${name}.run.log")"
  read -r gold_count gold_cycles gold_ipc <<< "$(extract_summary "${VECTORS_DIR}/${expected}")"

  echo "  golden : count=$gold_count cycles=$gold_cycles ipc=$gold_ipc"
  echo "  RTL    : count=$rtl_count cycles=$rtl_cycles ipc=$rtl_ipc"

  ok=1
  if [ "$rtl_count" != "$gold_count" ]; then
    echo "  MISMATCH: instruction count differs"
    ok=0
  fi
  if [ "$rtl_cycles" = "$gold_cycles" ]; then
    echo "  -> EXACT cycle match (summary)"
  else
    pct=$(python3 -c "print(f'{100*(int('$rtl_cycles')-int('$gold_cycles'))/int('$gold_cycles'):.2f}')" 2>/dev/null || echo "?")
    echo "  -> cycle count differs: RTL=$rtl_cycles golden=$gold_cycles (${pct}% off)"
    ok=0
  fi

  # Full per-instruction field-by-field diff, not just the summary
  grep -E "^[0-9]" "${WORKDIR}/${name}.run.log" > /tmp/rtl_full_lines.txt
  grep -E "^[0-9]" "${VECTORS_DIR}/${expected}" > /tmp/gold_full_lines.txt
  full_diff_out=$(python3 verif/regression/compare_rtl_vs_golden_report.py /tmp/rtl_full_lines.txt /tmp/gold_full_lines.txt 2>&1)
  if echo "$full_diff_out" | grep -q "ALL FIELDS MATCH"; then
    echo "  -> ALL FIELDS MATCH (full per-instruction report, all 9 stages)"
  else
    echo "  -> per-instruction report has mismatches:"
    echo "$full_diff_out" | sed 's/^/     /'
    ok=0
  fi
  echo "  full report saved: ${REPORTS_DIR}/${name}_report.txt"

  if [ "$ok" -eq 1 ]; then
    echo "  -> PASS (exact match)"
  else
    echo "  -> FAIL (see notes above)"
    FAIL=1
  fi
  echo
done < "$CONFIGS_CSV"

if [ "$FAIL" -eq 0 ]; then
  echo "ALL RTL VS GOLDEN VAL CONFIGS MATCHED EXACTLY (summary + full per-instruction report)"
else
  echo "SOME CONFIGS DID NOT MATCH EXACTLY -- see per-config detail above"
fi
exit "$FAIL"

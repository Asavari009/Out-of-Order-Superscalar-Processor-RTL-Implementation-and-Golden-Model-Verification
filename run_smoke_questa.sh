#!/usr/bin/env bash
# run_smoke_questa.sh -- Questa-native equivalent of run_smoke.sh. Same
# 7 testbenches, same pass/fail criteria (each testbench prints
# "ALL PASS" on success), but compiled/run via vlog/vsim instead of
# Verilator. Kept as a SEPARATE script rather than folded into
# run_smoke.sh, since the two tools' command-line conventions are
# different enough that merging them would make both harder to read.
#
# UNTESTED ON REAL QUESTA as of writing -- this project's Verilator flow
# is proven; this script has not been run against an actual QuestaSim
# install. Expect to need to fix real issues the first time it runs, the
# same way several rounds of Verilator-specific fixes were needed
# earlier in this project. Start with just `vlib work && vlog ... &&
# vsim -c work.tb_rob -do "run -all; quit -f"` by hand first (see
# docs/README.md) before trusting this automated script.
set -u
cd "$(dirname "$0")"

WORKDIR="/tmp/ooo_rtl_smoke_questa"
mkdir -p "$WORKDIR"
LOGDIR="logs"
mkdir -p "$LOGDIR"

RTL_FILES="rtl/ooo_pkg.sv rtl/pipe_reg.sv rtl/sched_reg.sv rtl/rmt.sv rtl/rob.sv rtl/issue_queue.sv rtl/exec_units.sv rtl/ooo_pipeline.sv"

FAIL=0

# Fresh work library once per run
rm -rf work
vlib work

run_tb () {
  local rtl_files="$1" tb_file="$2" top="$3"
  echo "=== $top ==="

  if ! vlog -sv -work work $rtl_files "$tb_file" \
        > "${WORKDIR}/${top}.compile.log" 2>&1; then
    echo "  COMPILE FAILED (see ${WORKDIR}/${top}.compile.log)"
    tail -20 "${WORKDIR}/${top}.compile.log"
    FAIL=1
    echo
    return
  fi

  if ! vsim -c -work work "work.${top}" -do "run -all; quit -f" \
        > "${WORKDIR}/${top}.run.log" 2>&1; then
    echo "  SIM CRASHED (see ${WORKDIR}/${top}.run.log)"
    tail -20 "${WORKDIR}/${top}.run.log"
    FAIL=1
    echo
    return
  fi

  cat "${WORKDIR}/${top}.run.log"
  if grep -q "ALL PASS" "${WORKDIR}/${top}.run.log"; then
    echo "  -> PASS"
  else
    echo "  -> FAIL (see ${WORKDIR}/${top}.run.log)"
    FAIL=1
  fi
  echo
}

run_tb "$RTL_FILES" verif/tb_smoke/tb_rob.sv       tb_rob
run_tb "$RTL_FILES" verif/tb_smoke/tb_rmt.sv       tb_rmt
run_tb "$RTL_FILES" verif/tb_smoke/tb_iq.sv        tb_iq
run_tb "$RTL_FILES" verif/tb_smoke/tb_exu.sv       tb_exu
run_tb "$RTL_FILES" verif/tb_smoke/tb_pipe_reg.sv  tb_pipe_reg
run_tb "$RTL_FILES" verif/tb_smoke/tb_sched_reg.sv tb_sched_reg
run_tb "$RTL_FILES" verif/tb_smoke/tb_pipeline_basic.sv tb_pipeline_basic

if [ "$FAIL" -eq 0 ]; then
  echo "ALL SMOKE TESTS PASSED (Questa)"
else
  echo "SOME SMOKE TESTS FAILED -- see logs above"
fi
exit "$FAIL"

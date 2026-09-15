#!/usr/bin/env bash
# run_smoke.sh -- builds and runs every RTL smoke test with Verilator,
# plus the golden C++ model, and reports pass/fail for each.
#
# WHY VERILATOR, NOT ICARUS: an earlier version of this script used
# Icarus Verilog. During development we found Icarus 12.0 has a real bug
# where array-typed output ports driven from internal register arrays
# sometimes never propagate values through the module boundary (stuck at
# X forever, confirmed via hierarchical probing that the internal state
# was correct). We also found -- in BOTH Icarus and Verilator -- that
# single-bit unpacked-array PORTS (`logic foo[N]`) don't reliably trigger
# always_comb re-evaluation when an element changes after elaboration.
# All RTL in this project now uses packed vectors for boolean per-lane
# signals specifically to route around that second issue (see the
# port-style rule documented in rtl/ooo_pkg.sv). Verilator is the more
# robust, actively-maintained tool for what's left, so it's the standard
# local checker now. This is still NOT the real verification target --
# see "How to run and verify" in docs/README.md for Questa/VCS/Xcelium.
#
# Install Verilator if you don't have it: `sudo apt-get install verilator`
# (Debian/Ubuntu) or `brew install verilator` (macOS). If you don't have
# sudo, see docs/README.md for the no-sudo build-from-source path (same
# idea as building Icarus from source, just a different repo).
set -u
cd "$(dirname "$0")"

FAIL=0
WORKDIR="/tmp/ooo_rtl_smoke"
mkdir -p "$WORKDIR"

run_tb () {
  local rtl_mod="$1" tb_mod="$2"
  local mdir="${WORKDIR}/obj_dir_${tb_mod}"
  echo "=== $tb_mod (DUT: $rtl_mod) ==="
  rm -rf "$mdir"
  if ! verilator --binary -j 0 --timing -Wno-fatal --Mdir "$mdir" -Irtl \
        rtl/ooo_pkg.sv "rtl/${rtl_mod}.sv" "verif/tb_smoke/${tb_mod}.sv" \
        --top-module "$tb_mod" -o "v${tb_mod}" \
        > "${WORKDIR}/${tb_mod}.compile.log" 2>&1; then
    echo "  COMPILE FAILED (see ${WORKDIR}/${tb_mod}.compile.log)"
    FAIL=1
    return
  fi
  if ! timeout 20 "${mdir}/v${tb_mod}" > "${WORKDIR}/${tb_mod}.run.log" 2>&1; then
    echo "  RUN TIMED OUT / CRASHED (see ${WORKDIR}/${tb_mod}.run.log)"
    FAIL=1
    return
  fi
  cat "${WORKDIR}/${tb_mod}.run.log"
  if grep -q "ALL PASS" "${WORKDIR}/${tb_mod}.run.log"; then
    echo "  -> PASS"
  else
    echo "  -> FAIL (see ${WORKDIR}/${tb_mod}.run.log)"
    FAIL=1
  fi
  echo
}

# Same as run_tb, but for tests needing multiple RTL files (e.g. the
# assembled top-level pipeline, which needs every module it wires
# together, not just one DUT).
run_tb_multi () {
  local tb_mod="$1"; shift
  local rtl_mods=("$@")
  local mdir="${WORKDIR}/obj_dir_${tb_mod}"
  local rtl_files=()
  for m in "${rtl_mods[@]}"; do rtl_files+=("rtl/${m}.sv"); done
  echo "=== $tb_mod (DUT: ${rtl_mods[*]}) ==="
  rm -rf "$mdir"
  if ! verilator --binary -j 0 --timing -Wno-fatal --Mdir "$mdir" -Irtl \
        rtl/ooo_pkg.sv "${rtl_files[@]}" "verif/tb_smoke/${tb_mod}.sv" \
        --top-module "$tb_mod" -o "v${tb_mod}" \
        > "${WORKDIR}/${tb_mod}.compile.log" 2>&1; then
    echo "  COMPILE FAILED (see ${WORKDIR}/${tb_mod}.compile.log)"
    FAIL=1
    return
  fi
  if ! timeout 20 "${mdir}/v${tb_mod}" > "${WORKDIR}/${tb_mod}.run.log" 2>&1; then
    echo "  RUN TIMED OUT / CRASHED (see ${WORKDIR}/${tb_mod}.run.log)"
    FAIL=1
    return
  fi
  cat "${WORKDIR}/${tb_mod}.run.log"
  if grep -q "ALL PASS" "${WORKDIR}/${tb_mod}.run.log"; then
    echo "  -> PASS"
  else
    echo "  -> FAIL (see ${WORKDIR}/${tb_mod}.run.log)"
    FAIL=1
  fi
  echo
}

run_tb rob          tb_rob
run_tb rmt           tb_rmt
run_tb issue_queue   tb_iq
run_tb exec_units    tb_exu
run_tb pipe_reg      tb_pipe_reg
run_tb sched_reg     tb_sched_reg
run_tb_multi tb_pipeline_basic pipe_reg sched_reg rmt rob issue_queue exec_units ooo_pipeline

echo "=== golden C++ model ==="
( cd golden && make -s clean && make -s ) || { echo "  BUILD FAILED"; FAIL=1; }
if [ -x golden/sim ]; then
  printf '100 0 1 2 3\n104 1 4 1 3\n108 2 -1 4 7\n10c 0 5 4 2\n110 0 6 5 1\n' > "${WORKDIR}/tiny_trace.txt"
  golden/sim 8 8 2 "${WORKDIR}/tiny_trace.txt" > "${WORKDIR}/golden_tiny.log"
  echo "  -> ran OK, output in ${WORKDIR}/golden_tiny.log"
fi
echo

if [ "$FAIL" -eq 0 ]; then
  echo "ALL SMOKE TESTS PASSED"
else
  echo "SOME SMOKE TESTS FAILED -- see logs above"
fi
exit "$FAIL"

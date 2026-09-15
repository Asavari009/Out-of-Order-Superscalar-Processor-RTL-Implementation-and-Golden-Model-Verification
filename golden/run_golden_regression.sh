#!/usr/bin/env bash
# run_golden_regression.sh -- confirms golden/sim_proc.cc reproduces the
# course's official val1..val8 validation outputs exactly. This is a
# sanity check on the ORACLE itself (not the RTL) -- run this once to
# trust the golden model, then every future RTL scoreboard diff against
# it inherits that trust.
#
# Configs (ROB_SIZE, IQ_SIZE, WIDTH, trace) extracted from each val*.txt's
# own "Simulator Command" footer:
#   val1: 16   8  1 gcc1     val5:  64 16 4 perl1
#   val2: 16   8  2 gcc1     val6: 128 16 5 perl1
#   val3: 60  15  3 gcc1     val7: 256 64 5 perl1
#   val4: 64  16  8 gcc1     val8: 512 64 7 perl1
set -u
cd "$(dirname "$0")"

make -s clean && make -s
if [ ! -x ./sim ]; then
  echo "BUILD FAILED"
  exit 1
fi

cd vectors
FAIL=0

check () {
  local name="$1" rob="$2" iq="$3" width="$4" trace="$5"
  ../sim "$rob" "$iq" "$width" "$trace" > "/tmp/golden_${name}.out"
  if diff -q "/tmp/golden_${name}.out" "${name}.txt" > /dev/null; then
    echo "PASS: $name (ROB=$rob IQ=$iq WIDTH=$width $trace)"
  else
    echo "FAIL: $name (ROB=$rob IQ=$iq WIDTH=$width $trace) -- see /tmp/golden_${name}.out"
    FAIL=1
  fi
}

check val1  16   8 1 val_trace_gcc1
check val2  16   8 2 val_trace_gcc1
check val3  60  15 3 val_trace_gcc1
check val4  64  16 8 val_trace_gcc1
check val5  64  16 4 val_trace_perl1
check val6 128  16 5 val_trace_perl1
check val7 256  64 5 val_trace_perl1
check val8 512  64 7 val_trace_perl1

echo
if [ "$FAIL" -eq 0 ]; then
  echo "GOLDEN MODEL MATCHES ALL 8 OFFICIAL VALIDATION OUTPUTS"
else
  echo "GOLDEN MODEL DIVERGED FROM OFFICIAL OUTPUT -- investigate before trusting it as an oracle"
fi
exit "$FAIL"

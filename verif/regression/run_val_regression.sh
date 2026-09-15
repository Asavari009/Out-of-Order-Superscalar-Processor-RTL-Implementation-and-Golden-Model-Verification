#!/usr/bin/env bash
# run_val_regression.sh -- runs a simulator binary against all 8 official
# val configs (from val_configs.csv, the single source of truth) and
# compares each output against the golden expected file with
# compare_report.py.
#
# TODAY: point this at golden/sim itself, as a self-check that the
#   harness (config manifest + comparator) is wired correctly. This is
#   expected to pass 8/8 trivially (it's diffing the golden model against
#   its own known-correct output) -- the value here is proving the HARNESS
#   works before there's any RTL to actually test with it.
#
# ONCE ooo_pipeline.sv + a way to run it exist: point SIM_CMD at whatever
#   produces the report-line output from the RTL (e.g. a Questa/VCS batch
#   run piped to a file, or a wrapper script around one), and every line
#   below works unchanged -- that's the point of building this now.
#
# Usage:
#   ./run_val_regression.sh                      # defaults to golden/sim
#   SIM_CMD=/path/to/other/sim ./run_val_regression.sh
set -u
cd "$(dirname "$0")"

VECTORS_DIR="../../golden/vectors"
CONFIGS="val_configs.csv"
SIM_CMD="${SIM_CMD:-../../golden/sim}"

if [ ! -x "$SIM_CMD" ]; then
  echo "SIM_CMD ($SIM_CMD) is not an executable. Build it first, or set"
  echo "SIM_CMD=/path/to/your/simulator ./run_val_regression.sh"
  exit 1
fi

FAIL=0
mkdir -p /tmp/val_regression_out

while IFS=',' read -r name rob iq width trace expected; do
  [[ "$name" =~ ^#.*$ || -z "$name" ]] && continue   # skip comments/blank lines
  out="/tmp/val_regression_out/${name}.out"
  "$SIM_CMD" "$rob" "$iq" "$width" "${VECTORS_DIR}/${trace}" > "$out" 2>/dev/null
  echo "=== $name (ROB=$rob IQ=$iq WIDTH=$width trace=$trace) ==="
  if python3 compare_report.py "$out" "${VECTORS_DIR}/${expected}"; then
    :
  else
    FAIL=1
  fi
  echo
done < "$CONFIGS"

if [ "$FAIL" -eq 0 ]; then
  echo "ALL 8 VAL CONFIGS PASSED against $SIM_CMD"
else
  echo "SOME VAL CONFIGS FAILED against $SIM_CMD -- see per-instruction detail above"
fi
exit "$FAIL"

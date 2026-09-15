#!/usr/bin/env python3
"""
compare_report.py -- diffs a simulator's per-instruction report output
against an expected (golden) report, field-by-field, and reports exactly
which instruction and which pipeline stage first diverged.

This is the comparison engine underneath both:
  - golden-vs-golden self-check (today, proves the tool itself is correct)
  - eventual RTL-vs-golden regression (once ooo_pipeline.sv + the UVM
    monitor exist and can produce output in this same format)

Report line format (matches golden/sim_proc.cc's Retire() output exactly):
  <seq_no> fu{<op>} src{<s1>,<s2>} dst{<d>} FE{b,d} DE{b,d} RN{b,d}
           RR{b,d} DI{b,d} IS{b,d} EX{b,d} WB{b,d} RT{b,d}

Footer lines (start with '#') carry the final summary:
  # Dynamic Instruction Count    = N
  # Cycles                       = N
  # Instructions Per Cycle (IPC) = N.NN

Usage:
  compare_report.py <actual_file> <expected_file> [--max-mismatches N]

Exit code 0 = identical (modulo the one known-cosmetic difference: the
"# ./sim ..." command-line echo, which is allowed to differ since it just
reflects argv[0]/path, not simulator behavior). Exit code 1 = mismatch.
"""
import re
import sys
import argparse

# Matches one per-instruction report line, capturing every field we care about.
LINE_RE = re.compile(
    r'^(?P<seq>\d+)\s+fu\{(?P<fu>-?\d+)\}\s+src\{(?P<s1>-?\d+),(?P<s2>-?\d+)\}\s+'
    r'dst\{(?P<dst>-?\d+)\}\s+'
    r'FE\{(?P<fe_b>\d+),(?P<fe_d>\d+)\}\s+'
    r'DE\{(?P<de_b>\d+),(?P<de_d>\d+)\}\s+'
    r'RN\{(?P<rn_b>\d+),(?P<rn_d>\d+)\}\s+'
    r'RR\{(?P<rr_b>\d+),(?P<rr_d>\d+)\}\s+'
    r'DI\{(?P<di_b>\d+),(?P<di_d>\d+)\}\s+'
    r'IS\{(?P<is_b>\d+),(?P<is_d>\d+)\}\s+'
    r'EX\{(?P<ex_b>\d+),(?P<ex_d>\d+)\}\s+'
    r'WB\{(?P<wb_b>\d+),(?P<wb_d>\d+)\}\s+'
    r'RT\{(?P<rt_b>\d+),(?P<rt_d>\d+)\}\s*$'
)

STAGE_FIELDS = ["fu", "s1", "s2", "dst",
                "fe_b", "fe_d", "de_b", "de_d", "rn_b", "rn_d",
                "rr_b", "rr_d", "di_b", "di_d", "is_b", "is_d",
                "ex_b", "ex_d", "wb_b", "wb_d", "rt_b", "rt_d"]

FIELD_LABEL = {
    "fu": "fu{}", "s1": "src1", "s2": "src2", "dst": "dst",
    "fe_b": "FE.begin", "fe_d": "FE.dur", "de_b": "DE.begin", "de_d": "DE.dur",
    "rn_b": "RN.begin", "rn_d": "RN.dur", "rr_b": "RR.begin", "rr_d": "RR.dur",
    "di_b": "DI.begin", "di_d": "DI.dur", "is_b": "IS.begin", "is_d": "IS.dur",
    "ex_b": "EX.begin", "ex_d": "EX.dur", "wb_b": "WB.begin", "wb_d": "WB.dur",
    "rt_b": "RT.begin", "rt_d": "RT.dur",
}

SUMMARY_RE = re.compile(r'^#\s*(?P<key>[\w (%)/]+?)\s*=\s*(?P<val>.+?)\s*$')


def parse_report(path):
    """Returns (dict seq_no -> parsed-field-dict, dict summary_key -> value)."""
    instrs = {}
    summary = {}
    with open(path, "r") as f:
        for lineno, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line:
                continue
            if line.startswith("#"):
                if "Simulator Command" in line or "===" in line or line.strip() == "#":
                    continue
                m = SUMMARY_RE.match(line)
                if m:
                    summary[m.group("key").strip()] = m.group("val").strip()
                continue
            m = LINE_RE.match(line)
            if not m:
                print(f"WARNING: {path}:{lineno}: unparsed line, skipping: {line!r}",
                      file=sys.stderr)
                continue
            instrs[int(m.group("seq"))] = m.groupdict()
    return instrs, summary


def compare(actual_path, expected_path, max_mismatches):
    actual, actual_summary = parse_report(actual_path)
    expected, expected_summary = parse_report(expected_path)

    mismatches = []

    # instruction count sanity
    if set(actual.keys()) != set(expected.keys()):
        missing = sorted(set(expected.keys()) - set(actual.keys()))[:5]
        extra = sorted(set(actual.keys()) - set(expected.keys()))[:5]
        print(f"FAIL: instruction set differs. "
              f"missing from actual (first 5): {missing}  "
              f"extra in actual (first 5): {extra}")
        return False

    for seq in sorted(expected.keys()):
        a = actual[seq]
        e = expected[seq]
        for field in STAGE_FIELDS:
            if a[field] != e[field]:
                mismatches.append((seq, field, a[field], e[field]))
                break  # one mismatch per instruction is enough to localize the bug

    if mismatches:
        print(f"FAIL: {len(mismatches)} instruction(s) mismatched "
              f"(showing first {min(max_mismatches, len(mismatches))}):")
        for seq, field, av, ev in mismatches[:max_mismatches]:
            print(f"  seq {seq}: field {FIELD_LABEL.get(field, field)} "
                  f"actual={av} expected={ev}")
        return False

    # summary comparison (ignore the "Simulator Command" line itself --
    # that's allowed to differ, it's just an argv echo, not behavior)
    summary_fail = False
    for key in ("Dynamic Instruction Count", "Cycles", "Instructions Per Cycle (IPC)"):
        av = actual_summary.get(key)
        ev = expected_summary.get(key)
        if av != ev:
            print(f"FAIL: summary field '{key}' differs: actual={av} expected={ev}")
            summary_fail = True

    if summary_fail:
        return False

    print(f"PASS: {len(expected)} instructions identical, summary matches "
          f"({actual_path} vs {expected_path})")
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("actual")
    ap.add_argument("expected")
    ap.add_argument("--max-mismatches", type=int, default=10)
    args = ap.parse_args()

    ok = compare(args.actual, args.expected, args.max_mismatches)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

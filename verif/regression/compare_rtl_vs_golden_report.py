#!/usr/bin/env python3
"""
compare_rtl_vs_golden_report.py -- diffs the RTL's full per-instruction
report (verif/sim_trace/run_trace_report.sv) against golden's, field by
field, automatically accounting for the established +1 cycle-numbering
offset (RTL's cycle 1 == golden's cycle 0 -- see docs/README.md).

Usage: compare_rtl_vs_golden_report.py <rtl_report_file> <golden_report_file>
"""
import re
import sys

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
BEGIN_FIELDS = ["fe_b", "de_b", "rn_b", "rr_b", "di_b", "is_b", "ex_b", "wb_b", "rt_b"]
DUR_FIELDS   = ["fe_d", "de_d", "rn_d", "rr_d", "di_d", "is_d", "ex_d", "wb_d", "rt_d"]
OTHER_FIELDS = ["fu", "s1", "s2", "dst"]


def parse(path):
    out = {}
    with open(path) as f:
        for line in f:
            m = LINE_RE.match(line.strip())
            if m:
                out[int(m.group("seq"))] = m.groupdict()
    return out


def main():
    rtl = parse(sys.argv[1])
    gold = parse(sys.argv[2])
    common = sorted(set(rtl) & set(gold))
    if not common:
        print("No overlapping instructions parsed -- check file formats")
        sys.exit(1)

    mismatches = []
    for seq in common:
        r, g = rtl[seq], gold[seq]
        for f in OTHER_FIELDS:
            if r[f] != g[f]:
                mismatches.append((seq, f, r[f], g[f]))
        for f in BEGIN_FIELDS:
            if int(r[f]) != int(g[f]) + 1:  # established offset
                mismatches.append((seq, f, r[f], f"{g[f]}+1={int(g[f])+1}"))
        for f in DUR_FIELDS:
            if r[f] != g[f]:
                mismatches.append((seq, f, r[f], g[f]))

    print(f"Compared {len(common)} instructions (seq {common[0]}..{common[-1]})")
    if not mismatches:
        print("ALL FIELDS MATCH (modulo the established +1 begin-cycle offset)")
        sys.exit(0)

    # report only the FIRST divergence per instruction to keep output readable
    seen = set()
    shown = 0
    for seq, field, actual, expected in mismatches:
        if seq in seen:
            continue
        seen.add(seq)
        print(f"  seq={seq}: field={field} rtl={actual} expected={expected}")
        shown += 1
        if shown >= 20:
            print(f"  ... ({len(seen)} total instructions with at least one mismatch so far)")
            break
    sys.exit(1)


if __name__ == "__main__":
    main()

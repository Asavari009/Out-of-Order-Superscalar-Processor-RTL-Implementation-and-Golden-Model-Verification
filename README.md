# Out-of-Order Superscalar Pipeline — RTL Implementation & Verification

A parameterized, synthesizable SystemVerilog implementation of a 9-stage
out-of-order superscalar processor pipeline, verified to be **bit-exact**
(cycle count and IPC) against a golden C++ reference model across 8
official configurations — WIDTH 1 to 8, ROB size 16 to 512 entries.

## What this is

The pipeline implements the classic out-of-order structures end to end:

| Stage | RTL module | What it does |
|---|---|---|
| Fetch → Decode | `pipe_reg.sv` | WIDTH-wide pipeline registers, ready/valid handshake |
| Rename | `rmt.sv` | Register Map Table, intra-bundle RAW forwarding, WAW resolution |
| Register Read | `sched_reg.sv` | Wakeup-aware register tracking same-cycle producer completion |
| Dispatch / Issue | `issue_queue.sv` | CAM-style issue queue, oldest-first select, same-cycle wakeup-to-select |
| Execute | `exec_units.sv` | Pooled multi-latency functional units (1/2/5-cycle ops) |
| Retire | `rob.sv` | Circular reorder buffer, in-order retirement, generation-tagged entries |
| — | `ooo_pipeline.sv` | Top-level integration: wires every stage together with combinational backpressure |

**Verified correctness, not just "it runs":** every one of the 8 official
course configurations produces the *exact* same cycle count and IPC as
the golden C++ model, down to every individual instruction's per-stage
timing (`FE{}DE{}RN{}RR{}DI{}IS{}EX{}WB{}RT{}`) — not just the aggregate
numbers.

## Repository layout

```
rtl/                RTL source (SystemVerilog)
golden/              Golden C++ reference model + official trace/answer files
verif/
  tb_smoke/          Per-module unit tests (Verilator)
  sim_trace/         Full-pipeline trace runners (summary + per-instruction report)
  regression/         Automated golden-vs-RTL regression scripts
  uvm/                 UVM verification environment (built, not yet run — see docs/README.md)
docs/README.md        Detailed status log, design decisions, and known-issue history
Makefile              All the commands below
run_smoke.sh           Verilator unit-test runner
run_smoke_questa.sh     QuestaSim unit-test runner
```

## How to run it

### 1. Unit tests (fast, ~1 second)
```bash
make smoke              # Verilator — 7 testbenches, 66 checks total
bash run_smoke_questa.sh   # QuestaSim equivalent
```
Expect `ALL SMOKE TESTS PASSED`.

### 2. Full-trace correctness check (the real proof)
Runs a real 10,000-instruction trace through the assembled pipeline and
compares against the golden model:
```bash
make run TRACE=golden/vectors/val_trace_gcc1 WIDTH=1 ROB_SIZE=16 IQ_SIZE=8
```

### 3. Full per-instruction timing report
Same as above, but reconstructs every instruction's complete stage-by-stage
timing (matching the exact `FE{}...RT{}` format the golden model outputs):
```bash
make report TRACE=golden/vectors/val_trace_gcc1 WIDTH=1 ROB_SIZE=16 IQ_SIZE=8 \
  GOLDEN=golden/vectors/val1.txt
```

### 4. All 8 official configs at once
```bash
make val-rtl
```
Expect `ALL RTL VS GOLDEN VAL CONFIGS MATCHED EXACTLY` — every config's
summary *and* full per-instruction report saved to
`logs/val_rtl_reports/val<N>_report.txt`.

## Requirements
- [Verilator](https://verilator.org/) 5.x (primary flow, all commands above)
- Python 3 (regression comparison scripts)
- Siemens QuestaSim (cross-validated separately, see `run_smoke_questa.sh`)

## Status

RTL design and correctness: **done and verified exact**. UVM formal
verification environment: built, not yet compiled/run on a real
simulator. Full history — every bug found, root-caused, and fixed along
the way — is in [`docs/README.md`](docs/README.md).

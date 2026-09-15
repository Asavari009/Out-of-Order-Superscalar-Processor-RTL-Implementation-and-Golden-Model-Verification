# OoO Pipeline: C++ Golden Model -> RTL + UVM Verification

Status snapshot and complete file manifest. Language: SystemVerilog RTL,
UVM verification, targeting Questa/VCS/Xcelium (your licensed simulator).

## Phased plan for remaining work (current status)

**Phase 1 — DONE: full per-instruction report generator.** `verif/sim_trace/run_trace_report.sv` reconstructs the exact `FE{}DE{}RN{}RR{}DI{}IS{}EX{}WB{}RT{}` line per instruction, with every timestamp semantic verified directly against `golden/sim_proc.cc`'s source. `verif/regression/compare_rtl_vs_golden_report.py` automates the diff, exposed via `make report TRACE=... WIDTH=.. ROB_SIZE=.. IQ_SIZE=.. GOLDEN=expected.txt`. Along the way, a genuine Verilator-version-specific bug was found and fixed in the monitor itself (see "Known issues" below for the full story) — the tool is now fully trustworthy on both Verilator 5.020 and 5.053.

**Phase 2 — DONE: the cycle-count gap is closed. All 8 official configs now match golden EXACTLY.** Using Phase 1's now-trustworthy tool, the remaining divergence was root-caused precisely: the rename-time readiness fix from the previous round only checked *registered* ROB state (one cycle behind a live broadcast). When a producer's wakeup broadcasts on the *exact same cycle* a consumer is renamed, that registered check misses it by exactly one cycle. Fixed in `ooo_pipeline.sv` by also checking the live `wb_valid_bus` broadcast at rename time, matching the same "effective readiness = registered OR live broadcast" pattern used everywhere else in the design. **`make val-rtl` now reports `ALL RTL VS GOLDEN VAL CONFIGS MATCHED EXACTLY`** across all 8 configs (val1-val8), both real traces (`gcc1`/`perl1`), WIDTH 1 through 8, ROB sizes 16 through 512 — bit-for-bit identical cycle count and IPC to the golden model. `make report` on val1 confirms `ALL FIELDS MATCH` across the *complete* per-instruction timing report (all 9 stages, all 10,000 instructions), not just the aggregate.

**Phase 3 — IN PROGRESS: full UVM environment.** Core structure built in `verif/uvm/`: `trace_txn`/`trace_sequence` (reads a trace file, generates items), `fetch_if`/`trace_driver` (drives the fetch port, respecting backpressure exactly like the proven `run_trace.sv` driver loop), `pipe_probe_if` (exposes internal stage-transition signals via `bind`, not hierarchical dot-access — see the file's own header comment for why), `retire_monitor` (reconstructs full per-instruction timing, ported directly from the proven-correct `run_trace_report.sv` logic), `ooo_scoreboard` (compares against a golden val*.txt file field-by-field), `ooo_env`, `tb_top.sv`, and a first test (`test_val_trace`). **Important limitation: no UVM library is available in this sandbox, so none of this has actually been compiled or run** — everything was written carefully against standard UVM 1.2/IEEE-1800.2 patterns, and one real bug (a port name mismatch between `pipe_probe_if` and `ooo_pipeline`'s actual internal signal names, `wb_valid`/`wb_seq_no` vs. the real `wb_valid_bus`/`wb_seq_no_bus`) was already found and fixed via a partial Verilator lint check (the interface files alone, which don't depend on the UVM library, do lint clean against the real RTL including the `bind` cross-reference — a genuine, if partial, validation). **This needs real compilation and debugging on Questa/VCS/Xcelium next** — given how many subtle, simulator-specific issues this project has hit already (the IEEE-1800-2023 static-lifetime bug, the earlier Icarus array-port bugs), expect this UVM code to need real iteration once it hits an actual UVM-capable tool. One specific risk already flagged in the code itself: `trace_driver` and `retire_monitor` are independent clocked processes, and the fetch-observation callback between them (`fetch_ap`/`fetch_imp`) doesn't currently pin down their relative execution order within the same clock edge — this could cause an off-by-one and is the first thing to check if `fe_begin`/`de_begin` timestamps look wrong once this actually runs.

**Phase 4 — run on a licensed simulator** (Questa/VCS/Xcelium) once available. Everything so far has been validated on Verilator only.

**Phase 5 — `architecture.md` + `verification_plan.md`.**


## How to read "status"
- **DONE** — written and **genuinely verified** with Verilator (see "Tooling" below for why Verilator, not Icarus).
- **TODO** — not started.
- **NEXT** — what I'd build next, in order.

## Tooling: why Verilator, not Icarus

Earlier smoke tests used Icarus Verilog and reported all-green. That was
**not fully trustworthy**, for two compounding reasons found during a
deep debugging session:

1. **A real bug in the test methodology itself.** Every `check()` task
   used `if (!cond) FAIL; else PASS`. In SystemVerilog, an unknown (`X`)
   `cond` makes `!cond` evaluate to `X`, and `if (X)` is treated as
   **false** — silently falling into the PASS branch. Any signal stuck at
   X was reported as passing. Fixed everywhere with strict `cond ===
   1'b1` checks.
2. **A genuine Icarus 12.0 bug**: array-typed output ports driven
   combinationally from internal register arrays sometimes never
   propagate through the module boundary (stuck at X forever), confirmed
   via hierarchical probing that the internal state was actually correct.
3. **A deeper, tool-independent issue** found in *both* Icarus and
   Verilator: single-bit unpacked-array **ports** (`input logic foo[N]`)
   do not reliably trigger `always_comb` re-evaluation when an individual
   element's value changes after elaboration — confirmed with a minimal,
   from-scratch reproduction, not just observed in this project's
   modules. **Fix, now a hard rule for this whole project** (documented
   in `rtl/ooo_pkg.sv`): any per-lane **boolean** signal (valid/has/
   ready/fire flags) must be a packed vector (`logic [N-1:0] foo`,
   indexed the same way with `foo[i]`), never a 1-bit unpacked array.
   Multi-bit per-lane *data* (tags, indices, seq_no, op_type) is
   unaffected and stays as unpacked arrays as originally designed.
4. One more wrinkle on top of #3: the **first** assignment to such a
   packed-vector port must be a whole-vector assignment (`sig = '0;`),
   not a per-bit loop (`sig[i] = 0;`) — confirmed by direct
   side-by-side comparison of an otherwise-identical testbench. Once a
   signal has been assigned as a whole at least once, later per-bit
   assignment works fine (used throughout every testbench after its
   initial clear).

With all four fixes applied, **every module was re-verified from scratch
under Verilator** (a more robust, actively-maintained open-source
simulator) and genuinely passes — see the status table below. `rob.sv`
and `issue_queue.sv`'s port types were already close to correct; `rmt.sv`
and `exec_units.sv` needed the packed-vector conversion before their
tests could be trusted.

Icarus remains usable for a first-pass syntax/elaboration check but
**should not be trusted for pass/fail results** on this codebase without
Verilator (or a real simulator) confirming them — `run_smoke.sh` now uses
Verilator exclusively for exactly this reason.

---

## 1. RTL (`rtl/`)

| File | Status | What it is |
|---|---|---|
| `ooo_pkg.sv` | **DONE** | Shared types: `op_type_e`, `src_tag_t` (tag + valid + is_rob), `iflight_t` (in-flight instruction as it lives in a pipeline register), architectural constants (67 regs, latencies 1/2/5). Documents two things learned the hard way: (1) RTL pipeline registers do NOT carry the 9 pairs of timing timestamps the C++ struct carries — timing reconstruction is a verification-environment job; (2) the hard port-style rule (packed vectors for boolean per-lane signals) — see Tooling above. |
| `rmt.sv` | **DONE, smoke-tested (10/10 pass, Verilator)** | Rename Map Table. Handles **intra-bundle forwarding** — if instruction 2 of a WIDTH-wide rename bundle reads a register that instruction 1 (same bundle) writes, instruction 2 must see the fresh tag (the C++ model gets this for free from a sequential `for` loop; here it's explicit shadow-chain logic). Also retire-time invalidation (rename-write beats retire-clear on same-cycle conflicts) and **WAW resolution** (program-order-later write wins). |
| `rob.sv` | **DONE, smoke-tested (13/13 pass, Verilator)** | Reorder Buffer. Circular buffer, WIDTH-wide allocate and WIDTH-wide in-order retire, wakeup ports for marking entries ready. Deliberately replaces the C++ model's pointer-position-comparison free-count logic (which special-cases `head==tail` by peeking at a neighboring entry — fragile in software, worse in hardware) with an explicit `count_q` register. **Just added**: `entry_ready` output (packed vector, one bit per ROB entry) so RR/DI-stage wakeup listeners in `ooo_pipeline.sv` can query arbitrary entries' registered readiness, combined with the same-cycle `wb_valid`/`wb_idx` broadcast on the caller's side for the same same-cycle-wakeup visibility `issue_queue.sv` already has. |
| `issue_queue.sv` | **DONE, smoke-tested (8/8 pass, Verilator)** | The hard part. Implements: (1) **wakeup** — combinational broadcast-compare of finishing dst tags against every waiting instruction's src tags, with a **same-cycle wakeup-to-select path** (a producer finishing EX in cycle N can wake a consumer that also issues in cycle N — matches the golden model's `Execute()`-before-`Issue()` call order and the spec's explicit anti-deadlock note); (2) **oldest-first select**, WIDTH-wide, over up to `IQ_SIZE` candidates, structural iterative-argmin over sequence number; (3) same-cycle slot reuse on dispatch. |
| `exec_units.sv` | **DONE, smoke-tested (12/12 pass, Verilator)** | WIDTH parallel, fully-pipelined "universal" FUs. Op type 0/1/2 → latency 1/2/5. Deliberately **pools** all `WIDTH*MAX_LATENCY` execution slots together with a free-slot allocator, rather than binding each IQ select-lane to a dedicated FU — a rigid 1:1 mapping would incorrectly stall a lane whose "own" FU happened to be momentarily full while others sat idle. Confirmed: latency-1 same-cycle completion, exact 5-cycle latency-2 timing, and multiple simultaneous completions in one cycle (the spec's own worst-case scenario). |
| `pipe_reg.sv` | **DONE, smoke-tested (17/17 pass, Verilator)** | Generic parameterized WIDTH-wide pipeline register (used at the DE and RN boundaries, where no readiness-tracking is needed), with the all-or-nothing stall/advance handshake the spec's Section 5.2 guide describes throughout ("if DI is not empty, do nothing... if DI is empty, advance"). Confirmed: stall while occupied-and-unconsumed, advance on consume, and the same-cycle vacate-and-refill pattern. |
| `sched_reg.sv` | **DONE, smoke-tested (7/7 pass, Verilator)** | Wakeup-aware version of `pipe_reg` for the RR and DI stages specifically. **Why it exists**: re-reading the spec's `Execute()` description closely, wakeup must reach the IQ, DI, AND RR — not just the IQ. A bare `pipe_reg` would let an instruction stalled in RR/DI (e.g. IQ momentarily full) get stuck with permanently-stale "not ready" bits if its producer finished during the stall, deadlocking forever. Confirmed: an instruction is correctly woken same-cycle while stalled, and the wakeup latches into the registered ready bits so it persists after the broadcast pulse ends. |
| `fetch_decode.sv` | **SIMPLIFIED — folded into ooo_pipeline.sv** | Real "decode" (bit-splitting an instruction encoding) doesn't apply here: the trace format is already structured fields (pc/op_type/dst/src1/src2), and the C++ golden model's own Decode() is a trivial passthrough. Reading a trace file also isn't something synthesizable RTL can do at all — that's inherently a testbench/driver job. So there's no separate module: the DE `pipe_reg` instance in `ooo_pipeline.sv` IS fetch+decode, fed directly by an external "fetch port" (driven by a driver/testbench), with `de_ready_for_fetch` exposed as a top-level output so the driver knows when it's safe to push the next bundle. |
| `ooo_pipeline.sv` | **DONE, smoke-tested (3/3 pass, Verilator)** | **The top-level integration — the whole project's centerpiece.** Wires DE→RN (`pipe_reg`, decoded pre-rename data) → Rename (`rmt.sv`) → RR→DI (`sched_reg`, renamed + readiness-tracked data) → Dispatch+Issue (`issue_queue.sv`) → Execute (`exec_units.sv`) → Retire (`rob.sv`, which also allocates at Rename time). Backpressure is computed combinationally in the reverse (downstream-to-upstream) direction every cycle — each stage's advance signal depends on whether the *next* stage can accept — the hardware-native equivalent of the C++ model's reverse per-cycle call order. **Verified**: a single instruction flows fetch-to-retire correctly, and a genuine RAW-dependent instruction pair correctly retires the consumer exactly one cycle after its producer. **Two real correctness bugs found and fixed while building this**: (1) `rmt.sv`'s retire-clear port only accepted ONE retiring instruction per cycle — for any `WIDTH > 1` config (i.e. most of your actual course configs, val2 through val8), this would have silently corrupted the rename map on multi-retire cycles; widened to WIDTH-wide, with a new multi-way retire test added to `tb_rmt.sv`. (2) `src_tag_t.tag` was only 7 bits (sized for architectural register numbers), but is also used to hold ROB indices — `val8.txt`'s `ROB_SIZE=512` needs 9 bits, so large-ROB configs would have silently truncated tags; widened to a package-wide `TAG_W=9` constant. |

## 2. Verification (`verif/`)

| File | Status | What it is |
|---|---|---|
| `tb_smoke/tb_rob.sv` | **DONE, 11/11 pass (Verilator)** | Directed smoke test. |
| `tb_smoke/tb_rmt.sv` | **DONE, 10/10 pass (Verilator)** | Directed smoke test; intra-bundle forwarding (RAW), retire-clear, and WAW resolution. |
| `tb_smoke/tb_iq.sv` | **DONE, 8/8 pass (Verilator)** | Directed smoke test; oldest-first select across multiple dispatch/issue cycles, and same-cycle wakeup-to-select. |
| `tb_smoke/tb_exu.sv` | **DONE, 12/12 pass (Verilator)** | Directed smoke test; per-latency completion timing and simultaneous multi-slot completion. |
| `tb_smoke/tb_pipe_reg.sv` | **DONE, 17/17 pass (Verilator)** | Directed smoke test; stall, advance, same-cycle vacate-and-refill, flush. |
| `tb_smoke/tb_sched_reg.sv` | **DONE, 7/7 pass (Verilator)** | Directed smoke test; the deadlock-prevention scenario specifically — a stalled instruction correctly notices a same-cycle wakeup from its producer, and the wakeup persists after the broadcast ends. |
| `tb_smoke/tb_pipeline_basic.sv` | **DONE, 3/3 pass (Verilator)** | **First true end-to-end integration test.** Feeds a RAW-dependent instruction pair through the fully assembled `ooo_pipeline.sv` and confirms correct ordering (consumer retires after producer). This exercises the actual stage-to-stage wiring, not an isolated module — the real milestone this turn. |
| `uvm/trace_txn.sv` | **TODO** | UVM sequence item: one trace line (`pc`, `op_type`, `dst`, `src1`, `src2`) plus a `seq_no`. |
| `uvm/trace_driver.sv` + `trace_sequencer.sv` | **TODO** | Reads a trace file (same format as the spec/golden model) and drives it into the DUT's fetch interface, WIDTH instructions/cycle, respecting DE-stage backpressure. |
| `uvm/pipe_probe_if.sv` | **TODO** | A monitor-only interface tapped onto **every** pipeline-register boundary (DE/RN/RR/DI/IQ/execute_list/WB/RT), so the monitor can timestamp each `seq_no`'s entry into each stage — this is how we reconstruct the exact `FE{}DE{}RN{}...RT{}` line without polluting the RTL pipeline registers with timing fields. |
| `uvm/retire_monitor.sv` | **TODO** | Assembles the per-instruction report line from the probe taps, in the same format the golden model prints, and sends it to the scoreboard. |
| `uvm/ooo_scoreboard.sv` | **TODO** | The actual pass/fail authority. Runs (or reads a pre-captured log from) `golden/sim_proc.cc` for the **same trace + same ROB_SIZE/IQ_SIZE/WIDTH**, and diffs it line-by-line against what the RTL monitor reconstructed. Also checks final IPC/cycle-count summary. |
| `uvm/ooo_agent.sv`, `ooo_env.sv` | **TODO** | Standard UVM wiring: driver+sequencer+monitor per agent, env instantiates input agent + scoreboard. |
| `uvm/tests/*.sv` | **TODO** | `test_basic_raw` (2-3 instr, hand-picked hazards), `test_iq_full_stall`, `test_rob_full_stall`, `test_width_edge` (WIDTH=1 and a large WIDTH), `test_random` (constrained-random trace generation), `test_val_traces` (replays the 8 official `val1`–`val8` configs — **the comparison engine this depends on is already built and proven, see `verif/regression/` below**; this test just needs to feed it RTL output once the pipeline exists). |
| `regression/val_configs.csv` | **DONE** | Single source of truth for the 8 official configs (ROB_SIZE/IQ_SIZE/WIDTH/trace/expected-file), extracted from each `val*.txt`'s own footer. Both `compare_report.py` and `run_val_regression.sh` read this one file — and eventually `test_val_traces` should too, rather than each hardcoding its own copy of these 8 rows. |
| `regression/compare_report.py` | **DONE, proven correct** | Field-by-field diff of a sim's report output against expected: parses every `FE{}...RT{}` field per instruction plus the summary footer (instruction count/cycles/IPC), and on mismatch prints exactly which instruction and which stage-field diverged (e.g. `seq 4242: field EX.begin actual=4357 expected=4356`) rather than a useless "files differ." **Proven two ways**: (1) self-diff of `val1.txt` against itself passes; (2) a deliberately corrupted copy (one instruction's `EX{}` begin-cycle bumped by 1) is caught and correctly localized to that exact instruction and field. This is the same comparison logic the eventual UVM scoreboard will use — no need to write it twice. |
| `uvm/trace_driver.sv` + `trace_sequencer.sv` | **TODO** | Reads a trace file (same format as the spec/golden model) and drives it into the DUT's fetch interface, WIDTH instructions/cycle, respecting DE-stage backpressure. |
| `uvm/pipe_probe_if.sv` | **TODO** | A monitor-only interface tapped onto **every** pipeline-register boundary (DE/RN/RR/DI/IQ/execute_list/WB/RT), so the monitor can timestamp each `seq_no`'s entry into each stage — this is how we reconstruct the exact `FE{}DE{}RN{}...RT{}` line without polluting the RTL pipeline registers with timing fields. |
| `uvm/retire_monitor.sv` | **TODO** | Assembles the per-instruction report line from the probe taps, in the same format the golden model prints, and sends it to the scoreboard. |
| `uvm/ooo_scoreboard.sv` | **TODO** | The actual pass/fail authority. Runs (or reads a pre-captured log from) `golden/sim_proc.cc` for the **same trace + same ROB_SIZE/IQ_SIZE/WIDTH**, and diffs it line-by-line against what the RTL monitor reconstructed. Also checks final IPC/cycle-count summary. |
| `uvm/ooo_agent.sv`, `ooo_env.sv` | **TODO** | Standard UVM wiring: driver+sequencer+monitor per agent, env instantiates input agent + scoreboard. |
| `uvm/tests/*.sv` | **TODO** | `test_basic_raw` (2-3 instr, hand-picked hazards), `test_iq_full_stall`, `test_rob_full_stall`, `test_width_edge` (WIDTH=1 and a large WIDTH), `test_random` (constrained-random trace generation), `test_val_traces` (replays the 8 official `val1`–`val8` configs — **the comparison engine this depends on is already built and proven, see `verif/regression/` below**; this test just needs to feed it RTL output once the pipeline exists). |
| `regression/val_configs.csv` | **DONE** | Single source of truth for the 8 official configs (ROB_SIZE/IQ_SIZE/WIDTH/trace/expected-file), extracted from each `val*.txt`'s own footer. Both `compare_report.py` and `run_val_regression.sh` read this one file — and eventually `test_val_traces` should too, rather than each hardcoding its own copy of these 8 rows. |
| `regression/compare_report.py` | **DONE, proven correct** | Field-by-field diff of a sim's report output against expected: parses every `FE{}...RT{}` field per instruction plus the summary footer (instruction count/cycles/IPC), and on mismatch prints exactly which instruction and which stage-field diverged (e.g. `seq 4242: field EX.begin actual=4357 expected=4356`) rather than a useless "files differ." **Proven two ways**: (1) self-diff of `val1.txt` against itself passes; (2) a deliberately corrupted copy (one instruction's `EX{}` begin-cycle bumped by 1) is caught and correctly localized to that exact instruction and field. This is the same comparison logic the eventual UVM scoreboard will use — no need to write it twice. |
| `regression/run_val_regression.sh` | **DONE, proven correct** | Runs a `$SIM_CMD` (default: `golden/sim`) against all 8 configs from the CSV, calls `compare_report.py` on each. Run today with no RTL at all — it correctly reports 8/8 PASS (golden model diffed against itself), which validates the harness plumbing is right *before* there's any RTL to actually test. Once `ooo_pipeline.sv` exists and there's some way to invoke it (a Questa/VCS batch run piped to a file, or a wrapper script), point `SIM_CMD` at that instead and every line of this script works unchanged. |
| `regression/run_rtl_val_regression.sh` | **DONE, actively used** | Builds and runs the ASSEMBLED RTL PIPELINE (`verif/sim_trace/run_trace.sv`) against all 8 official configs and both real traces, comparing final summary (instruction count/cycles/IPC) against golden. Exposed via `make val-rtl [CONFIGS="val1 val2"]`. This is what found the compile failures on `val6`-`val8` (see Known Issues #11) and produces the current cycle-count-gap table (Known Issues #12). Summary-only comparison for now — the full per-instruction diff needs the UVM monitor, still TODO. |
| `tb_top.sv` | **TODO** | Instantiates DUT, binds the probe interfaces, calls `run_test()`. |

## 3. Golden reference (`golden/`)

**DONE** — your working `sim_proc.cc`/`.h`/`Makefile`. Now also includes
`vectors/` (the 2 official trace files, `val_trace_gcc1`/`val_trace_perl1`,
10,000 instructions each, plus the 8 official expected outputs `val1.txt`–
`val8.txt`) and `run_golden_regression.sh`, which **confirms `sim_proc.cc`
reproduces all 8 official outputs bit-for-bit exactly** (verified — all 8
pass). This matters: it's a sanity check on the oracle itself, not the
RTL. Everything downstream (the eventual UVM scoreboard) trusts this
golden model as ground truth, so proving it matches the course's own
answer key first means that trust is earned, not assumed.

The 8 configs, extracted from each file's own footer, give a good spread
for later RTL regression too — WIDTH from 1 to 8, ROB/IQ_SIZE from tight
(16/8) to generous (512/64), both traces:

| Config | ROB_SIZE | IQ_SIZE | WIDTH | Trace |
|---|---|---|---|---|
| val1 | 16 | 8 | 1 | gcc1 |
| val2 | 16 | 8 | 2 | gcc1 |
| val3 | 60 | 15 | 3 | gcc1 |
| val4 | 64 | 16 | 8 | gcc1 |
| val5 | 64 | 16 | 4 | perl1 |
| val6 | 128 | 16 | 5 | perl1 |
| val7 | 256 | 64 | 5 | perl1 |
| val8 | 512 | 64 | 7 | perl1 |

## 4. Docs (`docs/`)

**TODO**: `architecture.md` (C++ stage → RTL module map + every deliberate divergence, several of which are already called out as comments in the RTL itself), `verification_plan.md` (test list + coverage goals — functional coverage on IQ occupancy, ROB occupancy, WIDTH values, hazard types).

---

## Known issues found so far

1. **Real bug, found & fixed**: `rob.sv`'s `wrap_add()` used a constant part-select (`s[IDX_W-1:0]`) inside a function called from `always_comb`. Icarus Verilog mishandles this specific pattern and enters a zero-time evaluation storm (simulation hangs, never advances). Rewrote using implicit width truncation instead of an explicit part-select — cleaner code regardless of simulator.
2. **Icarus tool gap**: Icarus's elaborator hits an internal assertion (`elab_expr.cc:2487`) on some field accesses into unpacked-array-of-packed-struct ports. Well-supported in Questa/VCS/Xcelium; specifically Icarus's incomplete support.
3. **Test methodology bug, found & fixed**: every `check()` task used `if (!cond)`, which silently treats an unknown (`X`) value as passing (`!X` is `X`, and `if (X)` is false in SV, so it falls through to PASS). Fixed with strict `cond === 1'b1` checks everywhere. This one actually mattered — see #4 and #5 below, which it had been masking.
4. **Icarus 12.0 bug, confirmed via Verilator**: array-typed output ports driven combinationally from internal register arrays sometimes never propagate through the module boundary (stuck at X forever) — confirmed via hierarchical probing that internal state was correct. Not an RTL bug; Verilator handles the same RTL correctly.
5. **Deeper, tool-independent issue** (found in both Icarus and Verilator): single-bit unpacked-array **ports** (`input logic foo[N]`) don't reliably trigger `always_comb` re-evaluation when an element changes after elaboration. Fixed project-wide by converting all boolean per-lane ports (valid/has/ready/fire flags) to packed vectors — now a hard coding rule, documented in `rtl/ooo_pkg.sv`. Multi-bit per-lane data (tags, indices) was unaffected.
6. **Real correctness bug, found & fixed while building `ooo_pipeline.sv`**: `rmt.sv`'s retire-clear port only handled one retiring instruction per cycle — silently wrong for any `WIDTH > 1` (most of your actual course configs). Widened to WIDTH-wide, new multi-way retire test added.
7. **Real correctness bug, found & fixed**: `src_tag_t.tag` was only 7 bits, but also holds ROB indices — `val8.txt`'s `ROB_SIZE=512` needs 9 bits. Widened to a package-wide `TAG_W=9` constant.
8. **Real correctness bug, found & fixed**: `$clog2(WIDTH)` evaluates to `0` when `WIDTH=1` (your own `val1` config!), producing an invalid `[-1:0]` vector in `issue_queue.sv` and `exec_units.sv`. Fixed with a `LANE_W = (WIDTH<=1) ? 1 : $clog2(WIDTH)` guard in both.
9. **Testbench timing bug, found & fixed**: `run_trace.sv`'s initial reset sequence was missing an extra settle edge (`@(posedge clk); #1;`) that every other testbench in this project includes, plus a cycle-counting-convention offset. Fixed; **now matches the golden model exactly (bit-for-bit Cycles and IPC) on hand-built 1- and 5-instruction traces.**
10. **FIXED — the ROB-tag-staleness deadlock.** Root cause (confirmed via state dump on the real `val_trace_gcc1`, WIDTH=1/ROB_SIZE=16/IQ_SIZE=8 config): plain ROB-index tags with no way to detect staleness after a slot is reallocated. **Fix implemented**: a per-slot generation counter (`GEN_W=32` bits) captured into `src_tag_t` at rename time and checked by every wakeup listener (`issue_queue.sv`, `sched_reg.sv`) — a generation mismatch, or the referenced slot being currently invalid (retired but not yet reallocated — a second, related gap fixed the same way), is treated as "ready." **All 8 official course configs now run to completion on real 10,000-instruction traces with zero hangs** (previously: permanent deadlock on the very first config tried). Two distinct bugs found and fixed via this investigation (an 8-bit counter that was itself too narrow and wrapped, then the invalid-slot gap).
11. **FOUND & FIXED — a second latent bug, exposed only at large ROB_SIZE/IQ_SIZE.** Running the full 8-config battery (`verif/regression/run_rtl_val_regression.sh`) revealed `val6`/`val7`/`val8` (`ROB_SIZE` 128/256/512, `IQ_SIZE` up to 64) failed to even **compile**: Verilator's default loop-unroll limit rejects a for-loop-with-nonblocking-array-assignment reset pattern once the array gets large enough. `val1`–`val5`'s smaller sizes happened to fit under the threshold, masking this until the larger configs were tried. Fixed in `rob.sv` and (proactively) `issue_queue.sv` by switching to the whole-array assignment pattern already used elsewhere (`rmt.sv`) for exactly this reason. **All 8 configs now compile and run.**
12. **MAJOR FIX — a real bug in initial readiness computation at rename time, found via detailed EX-begin-cycle tracing against golden.** Root cause: when an instruction is renamed, its source-readiness was set to `!is_rob` only (i.e. "ready iff not ROB-pending") — it never checked whether the ROB entry it depends on had *already* become ready by that point. If a producer finished and broadcast its wakeup *before* the consumer was even renamed (the consumer was still sitting in DE/RN, which don't listen for wakeup broadcasts at all), the consumer would never learn its dependency was already satisfied — the broadcast pulse was long gone by the time it reached a wakeup-listening stage (RR/DI/IQ), and it would wait needlessly. **Confirmed via a real example**: instruction 12 depends on instruction 7's result via ROB tag 7; instruction 7 finished and retired well before instruction 12 was even renamed, yet instruction 12's `src1_ready` stayed false until a coincidental structural event finally cleared it, costing 2+ extra cycles. The fix (`ooo_pipeline.sv`): also check `rob.entry_ready[tag]` at the moment of rename, not just `is_rob`. (Note: `rob.entry_ready` had already been added as an output specifically for this purpose two rounds ago, but was never actually wired in — flagged with a "reserved for future use" comment that should have been a red flag sooner.) **Result across all 8 official configs, cycle-count gap vs. golden:**

    | Config | Before this fix | After this fix |
    |---|---|---|
    | val1 | 1.81% | 0.64% |
    | val2 | 3.07% | 1.67% |
    | val3 | 12.51% | 5.32% |
    | val4 | 5.35% | 2.62% |
    | val5 | 5.22% | 3.06% |
    | val6 | 4.99% | 1.73% |
    | val7 | 11.84% | 3.46% |
    | val8 | 26.89% | 8.17% |

    Every config improved substantially (most roughly halved; val8 improved more than 3x). A smaller residual gap remained after this fix — see item 13.

13. **RESOLVED — a Verilator-version-specific bug in the report-generator monitor itself, found via systematic bisection.** Immediately after item 12's fix, `run_trace_report.sv` (the Phase 1 per-instruction report generator) started hanging/misbehaving specifically on Verilator 5.053 (not 5.020, where it was developed) — showing every retiring instruction as `seq=0`, then later a complete stall after 1 instruction once a naive duplicate-guard was added. **Root cause**: `int seq = rt_seq_no[i];`, declared inside a loop body within a plain module-level `initial` block (not inside a `function automatic`/`task automatic`), defaults to **static lifetime** per IEEE 1800-2023 §6.21 — its initializer runs *exactly once, ever*, not fresh on every loop iteration. Every retire after the first silently reused the stale first value. Verilator 5.020 apparently didn't enforce this rule as strictly; 5.053 (newer, closer to the 2023 standard) did, and its own compiler warning (`IMPLICITSTATIC`) gave the answer directly once the right test finally triggered it. **Found via disciplined bisection**: starting from a proven-working minimal retire-logger and adding back exactly one piece at a time (stage probes → struct-field hierarchical access → two-level-deep hierarchy → the full multi-argument `$display`) until the exact addition that introduced the warning was identified. **Fix**: the explicit `automatic` keyword. **Lesson for any future testbench code in this project**: any local variable declared with an initializer inside a loop/conditional body in a module-level procedural block needs `automatic`, or must be declared once outside the loop and assigned fresh each iteration.

14. **RESOLVED — the remaining cycle-count gap from item 12, closed completely.** Once item 13's fix made the report generator trustworthy again, it immediately pointed to the precise remaining issue: item 12's rename-time readiness check only looked at *registered* ROB state (`rob_entry_ready`), which is one cycle behind a live broadcast. When a producer's wakeup broadcasts on the *exact same cycle* a consumer is renamed, that registered check misses it by exactly one cycle — the same bug class as item 12, just narrower. **Confirmed via a real example**: instruction 12 depends on instruction 7 (register 3); instruction 7's wakeup broadcasts on cycle 14, the *exact same cycle* instruction 12 is renamed. **Fixed** in `ooo_pipeline.sv`'s `rr_in_data` construction by also checking the live `wb_valid_bus`/`wb_idx_bus` broadcast at rename time, matching the "effective readiness = registered OR live broadcast" pattern already used everywhere else in the design (`sched_reg.sv`, `issue_queue.sv`) — this rename-time check was the one place that pattern was missing. **Result: `make val-rtl` reports `ALL RTL VS GOLDEN VAL CONFIGS MATCHED EXACTLY`** — all 8 official configs, both real traces, bit-for-bit identical cycle count and IPC to golden. `make report` confirms `ALL FIELDS MATCH` across the complete per-instruction report (all 9 stages, all 10,000 instructions) for val1, not just the aggregate summary.

## Hazard coverage

Register data hazards get handled by fundamentally different mechanisms in
an OoO design, and are covered here accordingly:

- **RAW** (true dependency) — the only hazard needing active hardware
  tracking: `src_ready` bits + wakeup broadcast + IQ select logic. Tested
  in `tb_iq.sv` (dependent instr blocked until same-cycle wakeup) and
  `tb_rmt.sv` (intra-bundle RAW forwarding). **Caveat as of this round**:
  works correctly for short-lived dependencies (confirmed on real traces
  up to the point of the deadlock above); long-lived dependencies that
  outlast a ROB wraparound are the open bug.
- **WAR** — eliminated structurally by renaming (each write gets a fresh
  unique ROB tag, so an earlier reader is unaffected by a later write to
  the same architectural register). Nothing to actively test — it falls
  out for free from correct renaming, the same way it does in the C++
  golden model.
- **WAW** — resolved by applying dest-writes in program order in
  `rmt.sv`, and by in-order ROB retirement. Explicitly tested in
  `tb_rmt.sv`: two same-bundle instructions both write the same register;
  confirmed the RMT ends up pointing at the later write, and confirmed the
  earlier write is what a same-bundle reader sees via forwarding.

## Suggested order for what's next

1. ~~`issue_queue.sv`~~ — **done**.
2. ~~Golden validation~~ — **done**.
3. ~~`exec_units.sv`~~ — **done**.
4. ~~Full re-verification under Verilator~~ — **done**.
5. ~~`pipe_reg.sv` + `sched_reg.sv`~~ — **done**.
6. ~~`ooo_pipeline.sv`~~ — **done**, passes its first end-to-end test.
7. ~~Trace-driven RTL runner + Makefile + persistent logging~~ — **done**, see below.
8. ~~Cycle-count calibration against the golden model~~ — **done**: exact match confirmed on both a 1-instruction and a 5-instruction hand-built trace.
9. **CRITICAL — the ROB-tag-staleness deadlock found on the first full 10,000-instruction course trace.** See "Known issues" #10. **The most important open item.**
10. Broader directed pipeline tests, golden differential testing on a full trace (blocked on #9), full UVM environment.

## The trace-driven RTL runner and Makefile

Two new pieces this round, aimed at closing the "does this actually run a real program" gap:

- **`verif/sim_trace/run_trace.sv`**: a (non-UVM, plain SystemVerilog) testbench that reads a real trace file, drives it into `ooo_pipeline.sv` respecting `de_ready_for_fetch` backpressure, and reports a summary footer (`Dynamic Instruction Count` / `Cycles` / `Instructions Per Cycle`) in the same format as the golden model's. **Calibrated and exact-matching** on small hand-built traces (1 and 5 instructions) — bit-for-bit same cycle count and IPC as `golden/sim`. **Does not yet** produce the full per-instruction `FE{}DE{}...RT{}` report line — that needs careful per-field begin/duration semantics matching (the golden model sets some fields' timestamps a stage early — e.g. `DE.begin_cycle` is pre-computed inside `Fetch()`, not set by `Decode()`) and is genuinely the "UVM monitor" work, not yet started. Takes `+trace=<path>` as a runtime plusarg; `WIDTH`/`ROB_SIZE`/`IQ_SIZE` are compile-time `-G` overrides (see the Makefile).
- **`Makefile`**: `make smoke`, `make golden`, `make lint`, `make run TRACE=... WIDTH=.. ROB_SIZE=.. IQ_SIZE=..`, `make val-regression`, `make clean`, `make help`. Every target logs its full output to `logs/<target>_<timestamp>.log` with a `logs/<target>_latest.log` symlink — results are no longer lost to `/tmp`.

---

## How to run these files

### Right now: local smoke tests (Verilator, free, already set up)

These are **not** the real verification — they're a fast sanity net so RTL
bugs get caught in seconds, not after a 10-minute Questa run. One script
runs everything:

```bash
cd ooo_rtl
./run_smoke.sh
```

It builds+runs `tb_rob`, `tb_rmt`, `tb_iq`, `tb_exu` with Verilator,
builds the golden C++ model (`make` in `golden/`), runs it on a tiny
hand-built trace, and prints PASS/FAIL per module. All four RTL smoke
tests currently pass (8–12 checks each, 41 checks total). Logs land in
`/tmp/ooo_rtl_smoke/*.run.log` if anything fails.

To run one test manually instead of the whole script:
```bash
verilator --binary -j 0 --timing -Wno-fatal -Irtl \
  rtl/ooo_pkg.sv rtl/rob.sv verif/tb_smoke/tb_rob.sv \
  --top-module tb_rob -o vtb_rob
./obj_dir/vtb_rob
```
(swap in `rtl/rmt.sv`+`tb_rmt.sv`, `rtl/issue_queue.sv`+`tb_iq.sv`, or
`rtl/exec_units.sv`+`tb_exu.sv`; `--top-module` must match the testbench
module name in each case.)

If Verilator isn't installed: `sudo apt-get install verilator`
(Debian/Ubuntu) or `brew install verilator` (macOS). No sudo? Build from
source into your home directory the same way as Icarus (see the earlier
no-sudo instructions in this conversation) — just `git clone
https://github.com/verilator/verilator.git` instead, then `autoconf &&
./configure --prefix=$HOME/local && make -j4 && make install`.

**Hard-won port-style rule, now baked into every module** (see "Tooling"
above for the full story): any per-lane **boolean** signal (valid, has,
ready, fire flags) must be a packed vector (`logic [N-1:0] foo`), never a
1-bit unpacked array (`logic foo[N]`) — the latter doesn't reliably
propagate through module ports in either Icarus or Verilator. Multi-bit
per-lane data (tags, indices, seq_no) is unaffected and stays as unpacked
arrays. Also: the *first* assignment to such a packed-vector port must be
a whole-vector assignment (`sig = '0;`), not a per-bit loop — after that,
per-bit assignment (`sig[i] = 1;`) works fine. If you add new
testbenches, follow this pattern or you may reproduce the exact
X-stuck/false-PASS bug this project already worked through.

### The real target: Questa / VCS / Xcelium

Once the UVM environment exists (`verif/uvm/`), a run looks like this
(exact flags vary slightly by site license setup):

**Questa:**
```bash
vlib work
vlog -sv +incdir+rtl rtl/*.sv verif/uvm/*.sv verif/tb_top.sv
vsim -c work.tb_top -do "run -all" +UVM_TESTNAME=test_random +trace=path/to/val1.txt
```

**VCS:**
```bash
vcs -sverilog -ntb_opts uvm -f filelist.f -o simv
./simv +UVM_TESTNAME=test_random +trace=path/to/val1.txt
```

**Xcelium:**
```bash
xrun -uvm -sv -f filelist.f +UVM_TESTNAME=test_random +trace=path/to/val1.txt
```

`filelist.f` (once it exists) will just list every `rtl/*.sv` and
`verif/uvm/*.sv` file in dependency order, package first.

### How correctness gets verified (the actual point of the project)

Two independent layers, in increasing order of rigor:

1. **Directed smoke tests per module** (what exists today) — hand-built
   scenarios that exercise one specific piece of tricky logic (intra-bundle
   forwarding, same-cycle wakeup, oldest-first select) with a known
   expected answer. Good for catching logic bugs early and cheaply, useless
   for catching integration/timing bugs across the full pipeline.

2. **Golden-model differential testing** (the real pass/fail authority,
   once the UVM scoreboard exists) — the same trace file, with the same
   `ROB_SIZE`/`IQ_SIZE`/`WIDTH`, is fed to both `golden/sim_proc.cc` and the
   RTL. The UVM monitor reconstructs, from probe taps at every pipeline
   register boundary, the exact same `seq_no fu{} src{} dst{}
   FE{}DE{}RN{}RR{}DI{}IS{}EX{}WB{}RT{}` line the C++ model prints, and the
   scoreboard diffs them line-by-line, plus checks the final `Dynamic
   Instruction Count` / `Cycles` / `IPC` summary matches exactly. This is a
   strong check: any timing divergence in any pipeline stage — not just a
   wrong final IPC — shows up as a specific mismatched line for a specific
   instruction, telling you exactly which stage misbehaved.

   Concretely, until the scoreboard is built, you can already do this by
   hand: `golden/sim <ROB> <IQ> <WIDTH> <trace> > golden.log`, and once
   `ooo_pipeline.sv` exists, `diff` its retire-order output (once you have
   a way to print it) against `golden.log`.

   Test coverage should include: the directed hazard cases already in the
   smoke tests, the two structural stall cases (IQ full, ROB full), edge
   values of WIDTH (1 and something large like 8), and — once you have
   them from the course site — the real `val1.txt`–`val8.txt` validation
   traces, which are the actual bar the original course project was graded
   against and make an excellent regression suite here too.


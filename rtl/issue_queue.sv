//=============================================================================
// issue_queue.sv -- Issue Queue: wakeup + oldest-first select
//
// This is the module the whole project is actually about. Mirrors
// Dispatch()+Issue() in golden/sim_proc.cc, but as real parallel hardware
// instead of "sort() then linear scan, called once per software cycle."
//
// KEY TIMING DECISION -- same-cycle wakeup-to-select:
//   In the C++ model, Execute() (which sets ready flags on wakeup) is
//   called BEFORE Issue() within the same do-while iteration. So an
//   instruction finishing execution in cycle N can wake a dependent
//   instruction that *also issues in cycle N* -- zero-cycle wakeup-to-
//   select. The spec calls this out explicitly ("producers in their last
//   cycle of execution wake up dependent operands ... this is required to
//   avoid deadlock"). This RTL reproduces that: an entry's issue-eligible
//   signal is (registered ready bit) OR (matches a same-cycle wakeup
//   broadcast), evaluated combinationally, feeding the select logic in the
//   same cycle. This is the classic "wakeup-select" critical path in a
//   real OoO scheduler -- expect it to be the timing-critical loop if this
//   were ever pushed through synthesis.
//
// SELECT ALGORITHM:
//   Oldest-first, WIDTH-wide, over up to IQ_SIZE candidates: iteratively
//   pick the minimum-seq_no ready candidate not yet picked this cycle,
//   WIDTH times. O(WIDTH * IQ_SIZE) comparators. This is a direct
//   structural description, not a synthesis-optimized banked/segmented
//   scheduler -- correct and traceable beats clever for a project whose
//   point is the scheduling *algorithm*, and IQ_SIZE / WIDTH values in the
//   spec (up to 256 / 8) already produce a large compare network either
//   way.
//
// SLOT REUSE:
//   The C++ model calls Issue() then Dispatch() in the same iteration, so
//   Dispatch() already sees the IQ space freed by this cycle's issues. To
//   match that, `free_entries` here = (currently-invalid slots) + (slots
//   selected for issue this cycle), and a slot vacated by issue this cycle
//   can be immediately reoccupied by a dispatching instruction on the same
//   clock edge (see the always_ff: "issued-and-refilled" case).
//=============================================================================
`include "ooo_pkg.sv"

module issue_queue
  import ooo_pkg::*;
#(
  parameter int WIDTH    = 4,
  parameter int IQ_SIZE  = 16,
  parameter int ROB_SIZE = 32,
  parameter int WB_PORTS = WIDTH * MAX_LATENCY,
  localparam int ROBIDX_W = $clog2(ROB_SIZE),
  localparam int FREEW    = $clog2(IQ_SIZE+1),
  // $clog2(WIDTH) alone is 0 when WIDTH==1 (e.g. the course's own val1
  // config), producing an invalid [-1:0] vector -- force minimum 1 bit.
  localparam int LANE_W   = (WIDTH <= 1) ? 1 : $clog2(WIDTH)
)(
  input  logic clk,
  input  logic rst_n,

  // ---- occupancy (combinational, includes this-cycle issue vacancies) ---
  output logic [FREEW-1:0]      free_entries,

  // ---- dispatch (from DI stage; admission decided externally like rob.sv)
  input  logic                  disp_fire,
  input  logic [WIDTH-1:0]      disp_valid,             // packed: see ooo_pkg.sv port-style rule
  input  logic [SEQ_W-1:0]      disp_seq_no  [WIDTH],
  input  op_type_e              disp_op_type [WIDTH],
  input  logic [ROBIDX_W-1:0]   disp_rob_idx [WIDTH],  // this instr's own ROB entry
  input  src_tag_t              disp_src1    [WIDTH],
  input  src_tag_t              disp_src2    [WIDTH],
  input  logic [WIDTH-1:0]      disp_src1_ready,        // packed
  input  logic [WIDTH-1:0]      disp_src2_ready,        // packed

  // ---- wakeup broadcast (from Execute, same-cycle, see note above) ------
  input  logic [WB_PORTS-1:0]   wb_valid,               // packed
  input  logic [ROBIDX_W-1:0]   wb_idx   [WB_PORTS],

  // ---- ROB generation query (staleness detection, see ooo_pkg.sv GEN_W) -
  input  logic [GEN_W-1:0]      entry_gen [ROB_SIZE],
  input  logic [ROB_SIZE-1:0]   entry_valid,

  // ---- select / issue outputs (to Execute) -------------------------------
  output logic [WIDTH-1:0]      sel_valid,              // packed
  output logic [SEQ_W-1:0]      sel_seq_no   [WIDTH],
  output op_type_e              sel_op_type  [WIDTH],
  output logic [ROBIDX_W-1:0]   sel_rob_idx  [WIDTH]
);

  // ------------------------------------------------------------------
  // Storage
  // ------------------------------------------------------------------
  logic                valid_q      [IQ_SIZE];
  logic [SEQ_W-1:0]    seq_no_q     [IQ_SIZE];
  op_type_e            op_type_q    [IQ_SIZE];
  logic [ROBIDX_W-1:0] rob_idx_q    [IQ_SIZE];
  logic                src1_is_rob_q[IQ_SIZE];
  logic [ROBIDX_W-1:0] src1_tag_q   [IQ_SIZE];
  logic [GEN_W-1:0]    src1_gen_q   [IQ_SIZE];
  logic                src1_ready_q [IQ_SIZE];
  logic                src2_is_rob_q[IQ_SIZE];
  logic [ROBIDX_W-1:0] src2_tag_q   [IQ_SIZE];
  logic [GEN_W-1:0]    src2_gen_q   [IQ_SIZE];
  logic                src2_ready_q [IQ_SIZE];

  // ------------------------------------------------------------------
  // Wakeup match + STALENESS (see ooo_pkg.sv GEN_W) + effective
  // (this-cycle) readiness
  // ------------------------------------------------------------------
  logic wk_match1[IQ_SIZE];
  logic wk_match2[IQ_SIZE];
  logic stale1[IQ_SIZE];
  logic stale2[IQ_SIZE];
  logic eff_ready1[IQ_SIZE];
  logic eff_ready2[IQ_SIZE];

  always_comb begin
    for (int e = 0; e < IQ_SIZE; e++) begin
      wk_match1[e] = 1'b0;
      wk_match2[e] = 1'b0;
      for (int w = 0; w < WB_PORTS; w++) begin
        if (wb_valid[w] && src1_is_rob_q[e] && (wb_idx[w] == src1_tag_q[e]))
          wk_match1[e] = 1'b1;
        if (wb_valid[w] && src2_is_rob_q[e] && (wb_idx[w] == src2_tag_q[e]))
          wk_match2[e] = 1'b1;
      end
      // Staleness: if the ROB slot this entry is waiting on has moved to
      // a DIFFERENT generation than the one captured at rename time, OR
      // is currently INVALID (retired but not yet reallocated -- see
      // rob.sv's entry_valid comment), the slot has been vacated by the
      // TRUE producer, which can only happen after it already retired.
      // Treat as ready: the value is long since committed.
      stale1[e] = src1_is_rob_q[e] && (!entry_valid[src1_tag_q[e]] || (entry_gen[src1_tag_q[e]] != src1_gen_q[e]));
      stale2[e] = src2_is_rob_q[e] && (!entry_valid[src2_tag_q[e]] || (entry_gen[src2_tag_q[e]] != src2_gen_q[e]));
      eff_ready1[e] = src1_ready_q[e] | wk_match1[e] | stale1[e];
      eff_ready2[e] = src2_ready_q[e] | wk_match2[e] | stale2[e];
    end
  end

  // ------------------------------------------------------------------
  // Oldest-first select, WIDTH-wide, over (valid & eff_ready1 & eff_ready2)
  // ------------------------------------------------------------------
  logic issued_this_cyc[IQ_SIZE]; // combinational: is slot e chosen this cycle

  always_comb begin
    logic taken[IQ_SIZE];
    logic cand [IQ_SIZE];

    for (int e = 0; e < IQ_SIZE; e++) begin
      taken[e] = 1'b0;
      cand[e]  = valid_q[e] & eff_ready1[e] & eff_ready2[e];
      issued_this_cyc[e] = 1'b0;
    end

    for (int r = 0; r < WIDTH; r++) begin
      logic              found;
      logic [SEQ_W-1:0]  best_seq;
      int                best_idx;
      found    = 1'b0;
      best_seq = '0;
      best_idx = 0;
      for (int e = 0; e < IQ_SIZE; e++) begin
        if (cand[e] && !taken[e]) begin
          if (!found || (seq_no_q[e] < best_seq)) begin
            found    = 1'b1;
            best_seq = seq_no_q[e];
            best_idx = e;
          end
        end
      end
      sel_valid[r]   = found;
      sel_seq_no[r]  = found ? seq_no_q[best_idx]  : '0;
      if (found) sel_op_type[r] = op_type_e'(op_type_q[best_idx]);
      else       sel_op_type[r] = OP_TYPE0;
      sel_rob_idx[r] = found ? rob_idx_q[best_idx] : '0;
      if (found) begin
        taken[best_idx]           = 1'b1;
        issued_this_cyc[best_idx] = 1'b1;
      end
    end
  end

  // ------------------------------------------------------------------
  // Free-slot accounting + dispatch allocation (this-cycle vacancies
  // from issue count as available, matching the C++ model's call order)
  // ------------------------------------------------------------------
  logic avail[IQ_SIZE]; // combinational: usable by dispatch THIS cycle
  always_comb begin
    for (int e = 0; e < IQ_SIZE; e++)
      avail[e] = (!valid_q[e]) | issued_this_cyc[e];
  end

  always_comb begin
    int unsigned cnt;
    cnt = 0;
    for (int e = 0; e < IQ_SIZE; e++)
      if (avail[e]) cnt++;
    free_entries = FREEW'(cnt);
  end

  // Allocate each valid disp[i] (in order) to the next unclaimed avail slot.
  logic              disp_assign_valid[WIDTH];
  logic [$clog2(IQ_SIZE)-1:0] disp_assign_slot[WIDTH];

  always_comb begin
    logic claimed[IQ_SIZE];
    for (int e = 0; e < IQ_SIZE; e++) claimed[e] = 1'b0;

    for (int i = 0; i < WIDTH; i++) begin
      logic found;
      int   slot;
      found = 1'b0;
      slot  = 0;
      disp_assign_valid[i] = 1'b0;
      disp_assign_slot[i]  = '0;
      if (disp_fire && disp_valid[i]) begin
        for (int e = 0; e < IQ_SIZE; e++) begin
          if (avail[e] && !claimed[e] && !found) begin
            found = 1'b1;
            slot  = e;
          end
        end
        if (found) begin
          claimed[slot]         = 1'b1;
          disp_assign_valid[i]  = 1'b1;
          disp_assign_slot[i]   = ($clog2(IQ_SIZE))'(slot);
        end
      end
    end
  end

  // per-slot: which (if any) dispatch instruction targets it this cycle
  logic              slot_disp_valid[IQ_SIZE];
  logic [LANE_W-1:0] slot_disp_src[IQ_SIZE];
  always_comb begin
    for (int e = 0; e < IQ_SIZE; e++) begin
      slot_disp_valid[e] = 1'b0;
      slot_disp_src[e]   = '0;
    end
    for (int i = 0; i < WIDTH; i++) begin
      if (disp_assign_valid[i]) begin
        slot_disp_valid[disp_assign_slot[i]] = 1'b1;
        slot_disp_src[disp_assign_slot[i]]   = LANE_W'(i);
      end
    end
  end

  // ------------------------------------------------------------------
  // Sequential update
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // Whole-array assignment instead of a for-loop with nonblocking
      // assigns to array elements -- Verilator's default unroll limit
      // rejects the for-loop form once IQ_SIZE gets large (found the
      // same issue in rob.sv at ROB_SIZE=128+; fixing proactively here
      // since val7/val8 use IQ_SIZE=64).
      valid_q      <= '{default: 1'b0};
      src1_ready_q <= '{default: 1'b0};
      src2_ready_q <= '{default: 1'b0};
    end else begin
      for (int e = 0; e < IQ_SIZE; e++) begin
        if (slot_disp_valid[e]) begin
          // either a freshly-freed slot getting refilled, or an already-
          // free slot getting its first occupant -- both look the same.
          // Pull the whole struct into scalar temps first: Icarus (local
          // smoke test only) can't handle field access through a second
          // level of dynamic indexing (array-of-struct indexed by a
          // signal that is itself indexed by another signal).
          src_tag_t s1, s2;
          s1 = disp_src1[slot_disp_src[e]];
          s2 = disp_src2[slot_disp_src[e]];
          valid_q[e]        <= 1'b1;
          seq_no_q[e]       <= disp_seq_no[slot_disp_src[e]];
          op_type_q[e]      <= disp_op_type[slot_disp_src[e]];
          rob_idx_q[e]      <= disp_rob_idx[slot_disp_src[e]];
          src1_is_rob_q[e]  <= s1.is_rob;
          src1_tag_q[e]     <= s1.tag;
          src1_gen_q[e]     <= s1.gen;
          src1_ready_q[e]   <= disp_src1_ready[slot_disp_src[e]];
          src2_is_rob_q[e]  <= s2.is_rob;
          src2_tag_q[e]     <= s2.tag;
          src2_gen_q[e]     <= s2.gen;
          src2_ready_q[e]   <= disp_src2_ready[slot_disp_src[e]];
        end else if (issued_this_cyc[e]) begin
          valid_q[e] <= 1'b0;
        end else if (valid_q[e]) begin
          // no dispatch, no issue: latch this cycle's wakeup into the
          // registered ready bits so future cycles see it without a
          // live broadcast match
          src1_ready_q[e] <= eff_ready1[e];
          src2_ready_q[e] <= eff_ready2[e];
        end
      end
    end
  end

endmodule : issue_queue

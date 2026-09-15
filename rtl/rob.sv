//=============================================================================
// rob.sv -- Reorder Buffer
//
// Mirrors the ROB in golden/sim_proc.cc: a circular buffer of {ready, dest,
// pc}, with head/tail pointers. Differences from the C++ version, both
// deliberate hardware cleanups:
//
//   1. Free-entry count: the C++ model recomputes free entries from
//      head/tail pointer *positions* every call (with a special-cased
//      branch for head==tail, peeking at rob[tail+/-1] to disambiguate
//      "totally empty" from "totally full" -- see Rename() in sim_proc.cc).
//      In hardware that's just asking for an off-by-one bug. We instead
//      keep an explicit `count_q` register (0..ROB_SIZE), incremented by
//      #allocated and decremented by #retired each cycle. This is
//      functionally identical to the C++ logic and much easier to verify.
//
//   2. Allocation and retirement are both WIDTH-wide per cycle (the C++
//      model allocates the whole rename bundle in one Rename() call and
//      retires up to WIDTH per Retire() call already -- this just makes
//      the width-wide behavior structurally explicit with real pointer
//      arithmetic instead of a scalar increment in a loop).
//
// Allocation (from Rename stage):
//   - alloc_fire + alloc_valid[i] => entry (tail+i) gets {dest, pc, ready=0}
//   - alloc_rob_idx[i] output gives Rename the ROB index for instruction i,
//     which Rename/RMT need *before* the actual tail pointer updates (i.e.
//     this is combinational: tail + i, wrapped).
//
// Wakeup (from Writeback stage): sets ready=1 for 1 completing instruction
// per FU per cycle -- the top level fans this out across WIDTH*MAX_LATENCY
// writeback slots (see ooo_pipeline.sv). To keep the ROB port count sane,
// we accept up to WB_PORTS simultaneous ready-sets per cycle.
//
// Retire (in-order, up to WIDTH per cycle): consumes from head while
// rob[head].ready, exactly like the C++ Retire() while() loop.
//=============================================================================
`include "ooo_pkg.sv"

module rob
  import ooo_pkg::*;
#(
  parameter int WIDTH     = 4,
  parameter int ROB_SIZE  = 32,
  parameter int WB_PORTS  = WIDTH * MAX_LATENCY,  // worst case simultaneous completions
  localparam int IDX_W    = $clog2(ROB_SIZE)
)(
  input  logic clk,
  input  logic rst_n,

  // ---- occupancy / allocation --------------------------------------------
  output logic [IDX_W:0]      free_entries,          // 0..ROB_SIZE
  output logic [IDX_W-1:0]    alloc_rob_idx [WIDTH],  // tail+i (combinational)
  output logic [GEN_W-1:0]    alloc_gen     [WIDTH],  // generation this alloc will carry (combinational)

  // ---- readiness query (for RegRead / DI-stage wakeup listeners) ---------
  // Combinational, registered-state-only view of every entry's ready bit.
  // Callers combine this with the SAME-CYCLE wb_valid/wb_idx broadcast
  // themselves (see ooo_pipeline.sv) to get the same same-cycle wakeup
  // visibility issue_queue.sv already implements -- this port alone only
  // reflects wakeups that landed on a PRIOR cycle.
  output logic [ROB_SIZE-1:0] entry_ready,
  // Whether each slot is currently allocated at all. A caller's stale
  // check must treat an INVALID slot as ready too, not just a
  // generation mismatch: generation only increments at ALLOCATION, not
  // at retire, so a slot that has retired but not yet been reallocated
  // still shows its OLD (matching) generation to a late-arriving
  // consumer -- which would otherwise see "generation matches" (looks
  // current) AND "ready_q cleared" (looks not-ready), a false permanent
  // stall. v_q[idx]==0 unambiguously means that instruction retired
  // (nothing else ever clears it), so the value is definitely available.
  output logic [ROB_SIZE-1:0] entry_valid,
  // Current live generation per slot -- callers compare their STORED
  // src_tag_t.gen against this to detect a stale tag (see GEN_W comment
  // in ooo_pkg.sv for the full story on why this exists).
  output logic [GEN_W-1:0]    entry_gen [ROB_SIZE],

  input  logic                 alloc_fire,             // Rename bundle commits
  input  logic [WIDTH-1:0]     alloc_valid,            // packed: see ooo_pkg.sv port-style rule
  input  logic [ARCH_REG_W-1:0] alloc_dst_areg[WIDTH],
  input  logic [WIDTH-1:0]     alloc_dst_has,          // packed
  input  logic [PC_W-1:0]      alloc_pc       [WIDTH],
  input  logic [SEQ_W-1:0]     alloc_seq_no   [WIDTH],

  // ---- wakeup: mark an entry's result ready (from Writeback) -------------
  input  logic [WB_PORTS-1:0]  wb_valid,               // packed
  input  logic [IDX_W-1:0]     wb_idx   [WB_PORTS],

  // ---- retire (in-order, up to WIDTH/cycle) -------------------------------
  input  logic                 retire_fire,     // allow retirement this cycle
  output logic [WIDTH-1:0]     rt_valid,               // packed
  output logic [ARCH_REG_W-1:0] rt_dst_areg[WIDTH],
  output logic [WIDTH-1:0]     rt_dst_has,             // packed
  output logic [PC_W-1:0]      rt_pc       [WIDTH],
  output logic [SEQ_W-1:0]     rt_seq_no   [WIDTH],
  output logic [IDX_W-1:0]     rt_rob_idx  [WIDTH],
  output logic [$clog2(WIDTH+1)-1:0] rt_count   // # actually retired this cycle
);

  // storage
  logic                 v_q     [ROB_SIZE]; // entry allocated (between alloc and retire)
  logic                 ready_q [ROB_SIZE];
  logic [ARCH_REG_W-1:0] dst_areg_q[ROB_SIZE];
  logic                 dst_has_q [ROB_SIZE];
  logic [PC_W-1:0]      pc_q      [ROB_SIZE];
  logic [SEQ_W-1:0]     seq_no_q  [ROB_SIZE];
  logic [GEN_W-1:0]     gen_q     [ROB_SIZE]; // incremented every (re)allocation of this slot

  logic [IDX_W-1:0] head_q, tail_q;
  logic [IDX_W:0]   count_q; // one extra bit: 0..ROB_SIZE inclusive

  assign free_entries = ROB_SIZE[IDX_W:0] - count_q;

  always_comb begin
    for (int e = 0; e < ROB_SIZE; e++) begin
      entry_ready[e] = ready_q[e];
      entry_gen[e]   = gen_q[e];
      entry_valid[e] = v_q[e];
    end
  end

  // combinational: where would instruction i of the incoming bundle land
  function automatic logic [IDX_W-1:0] wrap_add(logic [IDX_W-1:0] base, int off);
    int unsigned s;
    s = int'(base) + off;
    if (s >= ROB_SIZE) s = s - ROB_SIZE;
    return IDX_W'(s);
  endfunction

  always_comb begin
    for (int i = 0; i < WIDTH; i++) begin
      alloc_rob_idx[i] = wrap_add(tail_q, i);
      // the generation THIS allocation will carry is one more than
      // whatever is currently stored (incremented at the same edge)
      alloc_gen[i] = gen_q[alloc_rob_idx[i]] + GEN_W'(1);
    end
  end

  // how many of the alloc bundle are actually valid (only valid entries
  // consume a slot; mirrors DI bundle possibly having fewer than WIDTH
  // real instructions, still renamed/allocated together in program order)
  int unsigned alloc_count;
  always_comb begin
    alloc_count = 0;
    for (int i = 0; i < WIDTH; i++)
      if (alloc_fire && alloc_valid[i]) alloc_count++;
  end

  // -------------------------------------------------------------------
  // Retire selection: in-order, scan from head, stop at first !ready
  // (or first invalid slot), up to WIDTH.
  // -------------------------------------------------------------------
  always_comb begin
    logic [IDX_W-1:0] idx;
    logic              stop;
    stop = 1'b0;
    for (int i = 0; i < WIDTH; i++) begin
      idx = wrap_add(head_q, i);
      if (!stop && retire_fire && v_q[idx] && ready_q[idx]) begin
        rt_valid[i]    = 1'b1;
        rt_dst_areg[i] = dst_areg_q[idx];
        rt_dst_has[i]  = dst_has_q[idx];
        rt_pc[i]       = pc_q[idx];
        rt_seq_no[i]   = seq_no_q[idx];
        rt_rob_idx[i]  = idx;
      end else begin
        stop = 1'b1;
        rt_valid[i]    = 1'b0;
        rt_dst_areg[i] = '0;
        rt_dst_has[i]  = 1'b0;
        rt_pc[i]       = '0;
        rt_seq_no[i]   = '0;
        rt_rob_idx[i]  = '0;
      end
    end
  end

  always_comb begin
    rt_count = '0;
    for (int i = 0; i < WIDTH; i++)
      if (rt_valid[i]) rt_count = rt_count + 1'b1;
  end

  // -------------------------------------------------------------------
  // Sequential state update
  // -------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      head_q  <= '0;
      tail_q  <= '0;
      count_q <= '0;
      // Whole-array assignment instead of a for-loop with nonblocking
      // assigns to array elements: functionally identical (same pattern
      // already used in rmt.sv), and Verilator's default unroll limit
      // rejects the for-loop form here once ROB_SIZE gets large (found
      // when testing ROB_SIZE=128+ configs -- val1-5's smaller ROB_SIZE
      // happened to fit under the default unroll threshold, masking this
      // until larger configs were tried).
      v_q     <= '{default: 1'b0};
      ready_q <= '{default: 1'b0};
      gen_q   <= '{default: '0};
    end else begin
      // allocate
      if (alloc_fire) begin
        for (int i = 0; i < WIDTH; i++) begin
          if (alloc_valid[i]) begin
            v_q[alloc_rob_idx[i]]        <= 1'b1;
            ready_q[alloc_rob_idx[i]]    <= 1'b0;
            dst_areg_q[alloc_rob_idx[i]] <= alloc_dst_areg[i];
            dst_has_q[alloc_rob_idx[i]]  <= alloc_dst_has[i];
            pc_q[alloc_rob_idx[i]]       <= alloc_pc[i];
            seq_no_q[alloc_rob_idx[i]]   <= alloc_seq_no[i];
            gen_q[alloc_rob_idx[i]]      <= alloc_gen[i];
          end
        end
        tail_q <= wrap_add(tail_q, alloc_count);
      end

      // wakeup (mark ready) -- independent of alloc/retire this cycle
      for (int w = 0; w < WB_PORTS; w++) begin
        if (wb_valid[w]) ready_q[wb_idx[w]] <= 1'b1;
      end

      // retire -- clear entries, advance head
      for (int i = 0; i < WIDTH; i++) begin
        if (rt_valid[i]) begin
          v_q[rt_rob_idx[i]]     <= 1'b0;
          ready_q[rt_rob_idx[i]] <= 1'b0;
        end
      end
      if (rt_count != 0) head_q <= wrap_add(head_q, int'(rt_count));

      // occupancy count
      count_q <= count_q + alloc_count - rt_count;
    end
  end

endmodule : rob

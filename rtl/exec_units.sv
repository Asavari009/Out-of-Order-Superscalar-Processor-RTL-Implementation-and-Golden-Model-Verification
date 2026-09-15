//=============================================================================
// exec_units.sv -- WIDTH universal, fully-pipelined function units
//
// Mirrors Execute() + the "execute_list" pipeline register in
// golden/sim_proc.cc. Per spec 5.1: WIDTH universal FUs, each fully
// pipelined (a new op can begin execution on some FU every cycle), with
// op_type 0/1/2 -> latency 1/2/5 cycles.
//
// KEY DESIGN DECISION -- pooled slots, not per-FU lanes:
//   Because the FUs are "universal" (interchangeable, any FU can run any
//   op type) and the model never needs to know WHICH specific FU an
//   instruction ran on, this module does NOT bind IQ select-lane i to a
//   dedicated FU i. That rigid 1:1 mapping would be WRONG: it could stall
//   an issue on lane i just because "FU i" happens to be momentarily full
//   of long-latency ops, even while other FUs sit idle -- a bug that has
//   nothing to do with the real microarchitecture's actual constraints.
//
//   Instead, all WIDTH*MAX_LATENCY execution slots are pooled into one
//   array with a free-slot allocator (same pattern as issue_queue.sv's
//   dispatch allocator). This matches the spec's own capacity reasoning
//   exactly: at most WIDTH new instructions enter per cycle (bounded by
//   IQ's own select width), each occupies a slot for up to MAX_LATENCY
//   cycles, so worst-case total occupancy is WIDTH*MAX_LATENCY -- which
//   is exactly the pool size and exactly the spec's stated WB pipeline
//   register size (Table 1: "conservative upper bound... multiply by
//   WIDTH").
//
// COMPLETION / WAKEUP:
//   A slot's countdown starts at op_latency(op_type) on entry and
//   decrements each cycle. When remaining==1, this is (per the spec's own
//   framing) the instruction's LAST cycle of execution: wb_valid fires
//   COMBINATIONALLY that same cycle (feeding issue_queue.sv's and
//   rob.sv's same-cycle wakeup ports), and the slot becomes available for
//   reuse (possibly by a new instruction entering that very cycle) on the
//   next clock edge. A latency-1 op therefore fires wb_valid in the same
//   cycle it enters -- matches the FE{5,1}...EX{6,1}WB{7,1} example in
//   the spec, where EX's 1-cycle duration means it's "last cycle" from
//   the moment it starts.
//=============================================================================
`include "ooo_pkg.sv"

module exec_units
  import ooo_pkg::*;
#(
  parameter int WIDTH    = 4,
  parameter int ROB_SIZE = 32,
  localparam int ROBIDX_W  = $clog2(ROB_SIZE),
  localparam int NUM_SLOTS = WIDTH * MAX_LATENCY,
  localparam int REMW      = $clog2(MAX_LATENCY+1),
  // $clog2(WIDTH) alone is 0 when WIDTH==1 (e.g. the course's own val1
  // config), producing an invalid [-1:0] vector -- force minimum 1 bit.
  localparam int LANE_W    = (WIDTH <= 1) ? 1 : $clog2(WIDTH)
)(
  input  logic clk,
  input  logic rst_n,

  // ---- instructions selected by the IQ this cycle (up to WIDTH) --------
  // NOTE: this is NOT a per-FU lane binding -- see design note above.
  // Any avail slot in the pool can take any of these.
  input  logic [WIDTH-1:0]    iss_valid,              // packed: see ooo_pkg.sv port-style rule
  input  logic [SEQ_W-1:0]    iss_seq_no  [WIDTH],
  input  op_type_e            iss_op_type [WIDTH],
  input  logic [ROBIDX_W-1:0] iss_rob_idx [WIDTH],

  // ---- completion / wakeup broadcast (combinational, same-cycle) -------
  // Feeds rob.sv's wb_valid/wb_idx and issue_queue.sv's wb_valid/wb_idx
  // ports directly (both sized WIDTH*MAX_LATENCY = NUM_SLOTS already).
  output logic [NUM_SLOTS-1:0] wb_valid,              // packed
  output logic [ROBIDX_W-1:0] wb_idx    [NUM_SLOTS],
  output logic [SEQ_W-1:0]    wb_seq_no [NUM_SLOTS]  // for report reconstruction
);

  logic                valid_q    [NUM_SLOTS];
  logic [REMW-1:0]     remaining_q[NUM_SLOTS]; // counts down to 1, not 0 (see note)
  logic [SEQ_W-1:0]    seq_no_q   [NUM_SLOTS];
  logic [ROBIDX_W-1:0] rob_idx_q  [NUM_SLOTS];

  // ------------------------------------------------------------------
  // Completion (combinational): a slot fires in its LAST cycle, i.e.
  // when remaining==1, not when it would hit 0.
  // ------------------------------------------------------------------
  logic firing[NUM_SLOTS];
  always_comb begin
    for (int s = 0; s < NUM_SLOTS; s++) begin
      firing[s]    = valid_q[s] && (remaining_q[s] == REMW'(1));
      wb_valid[s]  = firing[s];
      wb_idx[s]    = rob_idx_q[s];
      wb_seq_no[s] = seq_no_q[s];
    end
  end

  // ------------------------------------------------------------------
  // Free-slot pool + allocator (same pattern as issue_queue.sv dispatch)
  // ------------------------------------------------------------------
  logic avail[NUM_SLOTS];
  always_comb begin
    for (int s = 0; s < NUM_SLOTS; s++)
      avail[s] = (!valid_q[s]) | firing[s];
  end

  logic              slot_new_valid[NUM_SLOTS]; // this slot gets a new instr this cycle
  logic [LANE_W-1:0] slot_new_src[NUM_SLOTS]; // which iss[] lane feeds it

  always_comb begin
    logic claimed[NUM_SLOTS];
    for (int s = 0; s < NUM_SLOTS; s++) begin
      claimed[s]        = 1'b0;
      slot_new_valid[s] = 1'b0;
      slot_new_src[s]   = '0;
    end

    for (int i = 0; i < WIDTH; i++) begin
      logic found;
      int   slot;
      found = 1'b0;
      slot  = 0;
      if (iss_valid[i]) begin
        for (int s = 0; s < NUM_SLOTS; s++) begin
          if (avail[s] && !claimed[s] && !found) begin
            found = 1'b1;
            slot  = s;
          end
        end
        // `found` should always be true here -- see the capacity argument
        // in the header comment (WIDTH new entries/cycle max, pool sized
        // WIDTH*MAX_LATENCY). If this ever fails in simulation, it means
        // an upstream module is issuing more than WIDTH/cycle or this
        // pool's sizing assumption was violated -- worth an assertion
        // once this is wired into ooo_pipeline.sv.
        if (found) begin
          claimed[slot]        = 1'b1;
          slot_new_valid[slot] = 1'b1;
          slot_new_src[slot]   = LANE_W'(i);
        end
      end
    end
  end

  // ------------------------------------------------------------------
  // Sequential update
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int s = 0; s < NUM_SLOTS; s++) begin
        valid_q[s]     <= 1'b0;
        remaining_q[s] <= '0;
      end
    end else begin
      for (int s = 0; s < NUM_SLOTS; s++) begin
        if (slot_new_valid[s]) begin
          valid_q[s]     <= 1'b1;
          seq_no_q[s]    <= iss_seq_no[slot_new_src[s]];
          rob_idx_q[s]   <= iss_rob_idx[slot_new_src[s]];
          remaining_q[s] <= REMW'(op_latency(iss_op_type[slot_new_src[s]]));
        end else if (firing[s]) begin
          valid_q[s] <= 1'b0; // completed, not refilled this cycle
        end else if (valid_q[s]) begin
          remaining_q[s] <= remaining_q[s] - REMW'(1);
        end
      end
    end
  end

endmodule : exec_units

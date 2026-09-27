//=============================================================================
// exec_units.sv -- WIDTH universal, fully-pipelined function units
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

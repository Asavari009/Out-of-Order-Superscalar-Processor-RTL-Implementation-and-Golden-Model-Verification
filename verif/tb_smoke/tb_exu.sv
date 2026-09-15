`timescale 1ns/1ps
`include "ooo_pkg.sv"

// Timing model being tested: iss_valid asserted at cycle T is a
// COMBINATIONAL request this cycle (mirrors IQ's sel_* outputs); the
// instruction only lands in exec_units' registers at the NEXT posedge,
// at which point it occupies its first EX cycle. A latency-1 op's first
// EX cycle IS its last (fires wb_valid immediately after that edge). A
// latency-L op fires wb_valid after (L-1) further edges. This matches
// the spec's own FE{5,1}...EX{6,1} example: IS ends at cycle 5, EX
// begins at cycle 6 -- a full cycle boundary between "selected" and
// "occupying EX."
module tb_exu;
  import ooo_pkg::*;

  localparam int WIDTH    = 2;
  localparam int ROB_SIZE = 16;
  localparam int ROBIDX_W = $clog2(ROB_SIZE);
  localparam int NUM_SLOTS = WIDTH * MAX_LATENCY;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic [WIDTH-1:0]    iss_valid;              // packed: see ooo_pkg.sv port-style rule
  logic [SEQ_W-1:0]    iss_seq_no[WIDTH];
  op_type_e            iss_op_type[WIDTH];
  logic [ROBIDX_W-1:0] iss_rob_idx[WIDTH];

  logic [NUM_SLOTS-1:0] wb_valid;              // packed
  logic [ROBIDX_W-1:0] wb_idx[NUM_SLOTS];
  logic [SEQ_W-1:0]    wb_seq_no[NUM_SLOTS];

  int errors = 0;
  task automatic check(string name, logic cond);
    // STRICT check: cond===1'b1 required. Plain "if (!cond)" is a real
    // bug pattern -- if cond is X (unknown, e.g. from an undriven or
    // unpropagated signal), !cond evaluates to X, and "if (X)" is FALSE
    // in SystemVerilog, so a naive check silently falls through to PASS.
    // This bit us for real: exec_units.sv hit an Icarus port-propagation
    // bug that left outputs at X, and the old check() reported PASS
    // anyway. === with an explicit 1'b1 check catches X, Z, and 0 alike.
    if (cond === 1'b1) $display("PASS: %s", name);
    else begin errors++; $display("FAIL: %s (cond=%b)", name, cond); end
  endtask

  exec_units #(.WIDTH(WIDTH), .ROB_SIZE(ROB_SIZE)) dut (.*);

  function automatic int count_valid_wb();
    int c;
    c = 0;
    for (int s=0;s<NUM_SLOTS;s++) if (wb_valid[s]) c++;
    return c;
  endfunction

  function automatic logic wb_has_rob(logic [ROBIDX_W-1:0] idx);
    for (int s=0;s<NUM_SLOTS;s++)
      if (wb_valid[s] && wb_idx[s]==idx) return 1'b1;
    return 1'b0;
  endfunction

  task automatic clear_iss();
    // whole-vector assignment first (see tb_rmt.sv comment for why this
    // matters), then per-index clear of the remaining fields
    iss_valid = '0;
    for (int i=0;i<WIDTH;i++) begin
      iss_seq_no[i]=0; iss_op_type[i]=OP_TYPE0; iss_rob_idx[i]=0;
    end
  endtask

  initial begin
    clear_iss();
    rst_n = 0; @(posedge clk); @(posedge clk); rst_n = 1; @(posedge clk); #1;

    check("reset: no completions", count_valid_wb() == 0);

    // -----------------------------------------------------------------
    // Test 1: latency-1 op (OP_TYPE0). Request this cycle; on the NEXT
    // edge it enters EX; since latency=1, that same first-EX-cycle is
    // also its last -- fires wb right after that edge.
    // -----------------------------------------------------------------
    clear_iss();
    iss_valid[0]=1; iss_seq_no[0]=100; iss_op_type[0]=OP_TYPE0; iss_rob_idx[0]=5;
    @(posedge clk); #1;   // now in its first (and only) EX cycle
    clear_iss();
    check("latency-1 op fires wb on its first EX cycle", wb_has_rob(5));

    @(posedge clk); #1;
    check("latency-1 op gone the cycle after firing", !wb_has_rob(5));

    // -----------------------------------------------------------------
    // Test 2: latency-5 op (OP_TYPE2). Request this cycle; enters EX on
    // next edge (EX cycle 1 of 5); must NOT fire until EX cycle 5 (i.e.
    // after 4 further edges beyond entry).
    // -----------------------------------------------------------------
    clear_iss();
    iss_valid[0]=1; iss_seq_no[0]=200; iss_op_type[0]=OP_TYPE2; iss_rob_idx[0]=9;
    @(posedge clk); #1; clear_iss();   // EX cycle 1
    check("latency-5 op: EX cycle 1 not firing", !wb_has_rob(9));
    @(posedge clk); #1;                 // EX cycle 2
    check("latency-5 op: EX cycle 2 not firing", !wb_has_rob(9));
    @(posedge clk); #1;                 // EX cycle 3
    check("latency-5 op: EX cycle 3 not firing", !wb_has_rob(9));
    @(posedge clk); #1;                 // EX cycle 4
    check("latency-5 op: EX cycle 4 not firing", !wb_has_rob(9));
    @(posedge clk); #1;                 // EX cycle 5 -- last cycle
    check("latency-5 op: EX cycle 5 FIRES", wb_has_rob(9));

    @(posedge clk); #1;
    check("latency-5 op: gone after firing", !wb_has_rob(9));

    // -----------------------------------------------------------------
    // Test 3: two ops timed to complete their EX in the SAME cycle --
    // a latency-2 op entering one cycle before a latency-1 op, so the
    // latency-2 op's 2nd (last) EX cycle coincides with the latency-1
    // op's 1st (last) EX cycle.
    // -----------------------------------------------------------------
    clear_iss();
    iss_valid[0]=1; iss_seq_no[0]=300; iss_op_type[0]=OP_TYPE1; iss_rob_idx[0]=1; // latency 2
    @(posedge clk); #1; clear_iss();   // rob1 now in EX cycle 1 of 2
    iss_valid[0]=1; iss_seq_no[0]=301; iss_op_type[0]=OP_TYPE0; iss_rob_idx[0]=2; // latency 1
    @(posedge clk); #1; clear_iss();   // rob1 now in EX cycle 2 (last); rob2 now in EX cycle 1 (also last)
    check("simultaneous completion: rob1 fires", wb_has_rob(1));
    check("simultaneous completion: rob2 fires", wb_has_rob(2));
    check("simultaneous completion: exactly 2 wb ports active", count_valid_wb() == 2);

    if (errors == 0) $display("ALL PASS");
    else $display("%0d FAILURES", errors);
    $finish;
  end
endmodule

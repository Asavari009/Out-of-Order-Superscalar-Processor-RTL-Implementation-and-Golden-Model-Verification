`timescale 1ns/1ps
`include "ooo_pkg.sv"

module tb_iq;
  import ooo_pkg::*;

  localparam int WIDTH    = 2;
  localparam int IQ_SIZE  = 4;
  localparam int ROB_SIZE = 8;
  localparam int ROBIDX_W = $clog2(ROB_SIZE);
  localparam int WB_PORTS = WIDTH * MAX_LATENCY;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic [$clog2(IQ_SIZE+1)-1:0] free_entries;

  logic                disp_fire;
  logic [WIDTH-1:0]    disp_valid;             // packed: see ooo_pkg.sv port-style rule
  logic [SEQ_W-1:0]    disp_seq_no[WIDTH];
  op_type_e            disp_op_type[WIDTH];
  logic [ROBIDX_W-1:0] disp_rob_idx[WIDTH];
  src_tag_t            disp_src1[WIDTH];
  src_tag_t            disp_src2[WIDTH];
  logic [WIDTH-1:0]    disp_src1_ready;        // packed
  logic [WIDTH-1:0]    disp_src2_ready;        // packed

  logic [WB_PORTS-1:0] wb_valid;               // packed
  logic [ROBIDX_W-1:0] wb_idx[WB_PORTS];
  logic [GEN_W-1:0] entry_gen[ROB_SIZE]; // staleness detection; kept all-zero so existing tests see no aliasing
  logic [ROB_SIZE-1:0] entry_valid; // kept all-1 (nothing "retired") so existing tests aren't affected

  logic [WIDTH-1:0]    sel_valid;              // packed
  logic [SEQ_W-1:0]    sel_seq_no[WIDTH];
  op_type_e            sel_op_type[WIDTH];
  logic [ROBIDX_W-1:0] sel_rob_idx[WIDTH];

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

  issue_queue #(.WIDTH(WIDTH), .IQ_SIZE(IQ_SIZE), .ROB_SIZE(ROB_SIZE)) dut (.*);

  // helper: build a "ready now, not a ROB wait" src_tag_t (already-committed reg)
  function automatic src_tag_t mk_ready();
    src_tag_t t;
    t.valid = 1'b0; t.is_rob = 1'b0; t.tag = '0; t.gen = '0;
    return t;
  endfunction

  // helper: build a "waiting on ROB idx X" src_tag_t. gen=0 matches
  // entry_gen[]'s all-zero init above, so the new staleness check never
  // fires unintentionally in these directed tests -- they're testing
  // wakeup timing, not staleness, which gets its own dedicated test.
  function automatic src_tag_t mk_wait(logic [ROBIDX_W-1:0] idx);
    src_tag_t t;
    t.valid = 1'b1; t.is_rob = 1'b1; t.tag = idx; t.gen = '0;
    return t;
  endfunction

  task automatic clear_disp();
    disp_fire = 0;
    // whole-vector assignment first (see tb_rmt.sv comment for why this
    // matters), then per-index clear of the remaining fields
    disp_valid = '0;
    disp_src1_ready = '1;
    disp_src2_ready = '1;
    for (int i=0;i<WIDTH;i++) begin
      disp_seq_no[i]=0; disp_op_type[i]=OP_TYPE0;
      disp_rob_idx[i]=0; disp_src1[i]=mk_ready(); disp_src2[i]=mk_ready();
    end
  endtask

  task automatic clear_wb();
    wb_valid = '0;
    for (int w=0;w<WB_PORTS;w++) begin wb_idx[w]=0; end
  endtask

  initial begin
    clear_disp(); clear_wb();
    for (int e=0;e<ROB_SIZE;e++) entry_gen[e] = '0;
    entry_valid = '1;
    rst_n = 0; @(posedge clk); @(posedge clk); rst_n = 1; @(posedge clk); #1;

    check("reset free_entries==IQ_SIZE", free_entries == IQ_SIZE);

    // ---------------------------------------------------------------
    // Test 1: dispatch 2 ready instructions, out of program order by
    // seq_no is NOT possible via dispatch (dispatch is always program-
    // order), so instead dispatch 3 instructions across 2 cycles with
    // seq_no 5,6 then 3,4, and verify SELECT still picks lowest seq_no
    // first regardless of arrival/slot order.
    // ---------------------------------------------------------------
    clear_disp();
    disp_fire = 1;
    disp_valid[0]=1; disp_seq_no[0]=5; disp_rob_idx[0]=0;
    disp_valid[1]=1; disp_seq_no[1]=6; disp_rob_idx[1]=1;
    @(posedge clk); #1;
    clear_disp();

    disp_fire = 1;
    disp_valid[0]=1; disp_seq_no[0]=3; disp_rob_idx[0]=2;
    disp_valid[1]=1; disp_seq_no[1]=4; disp_rob_idx[1]=3;
    #1; // let this cycle's dispatch combinationally land before checking selects
    // (selects reflect PREVIOUS cycle's stored entries: seq 5,6 only, since
    //  this dispatch hasn't landed in registers yet)
    check("before 2nd disp lands: 2 ready oldest are seq5,seq6",
          sel_valid[0] && sel_valid[1] &&
          ((sel_seq_no[0]==5 && sel_seq_no[1]==6) ||
           (sel_seq_no[0]==6 && sel_seq_no[1]==5)));

    @(posedge clk); #1; // now seq 5,6 issued (freed), seq 3,4 landed
    clear_disp();

    // now IQ holds seq_no 3,4 only (5,6 were issued last cycle)
    check("after issue+2nd disp: entries are seq3,seq4",
          sel_valid[0] && sel_valid[1] &&
          ((sel_seq_no[0]==3 && sel_seq_no[1]==4) ||
           (sel_seq_no[0]==4 && sel_seq_no[1]==3)));

    @(posedge clk); #1; // issue seq3,seq4 -> IQ should be empty now
    check("IQ empty after all issued", free_entries == IQ_SIZE);
    check("no more candidates", !sel_valid[0] && !sel_valid[1]);

    // ---------------------------------------------------------------
    // Test 2: dependency + same-cycle wakeup-to-issue.
    // Dispatch one instr (seq 10) waiting on ROB idx 7 (not ready).
    // It must NOT be selected while unready, then a wakeup broadcast
    // for ROB idx 7 must make it selectable in the SAME cycle as the
    // broadcast (zero-cycle wakeup-to-select).
    // ---------------------------------------------------------------
    clear_disp();
    disp_fire = 1;
    disp_valid[0] = 1; disp_seq_no[0] = 10; disp_rob_idx[0] = 4;
    disp_src1[0] = mk_wait(7); disp_src1_ready[0] = 0;
    disp_src2[0] = mk_ready(); disp_src2_ready[0] = 1;
    @(posedge clk); #1;
    clear_disp();

    check("dependent instr not yet selectable", !sel_valid[0]);

    clear_wb();
    wb_valid[0] = 1; wb_idx[0] = 7; // producer ROB idx 7 finishes THIS cycle
    #1;
    check("same-cycle wakeup makes it selectable", sel_valid[0]);
    check("selected seq_no==10", sel_seq_no[0] == 10);

    if (errors == 0) $display("ALL PASS");
    else $display("%0d FAILURES", errors);
    $finish;
  end
endmodule

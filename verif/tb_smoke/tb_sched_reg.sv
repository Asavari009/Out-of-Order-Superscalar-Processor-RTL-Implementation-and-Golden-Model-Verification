`timescale 1ns/1ps
`include "ooo_pkg.sv"

module tb_sched_reg;
  import ooo_pkg::*;

  localparam int WIDTH    = 2;
  localparam int ROB_SIZE = 8;
  localparam int WB_PORTS = WIDTH * MAX_LATENCY;

  logic clk = 0, rst_n = 0, flush = 0;
  always #5 clk = ~clk;

  logic [WIDTH-1:0] in_valid;
  iflight_t         in_data[WIDTH];
  logic             in_fire;
  logic             consume;

  logic [WB_PORTS-1:0] wb_valid;
  logic [$clog2(ROB_SIZE)-1:0] wb_idx[WB_PORTS];
  logic [GEN_W-1:0] entry_gen[ROB_SIZE]; // staleness detection; kept all-zero so this test's checks aren't affected
  logic [ROB_SIZE-1:0] entry_valid; // kept all-1 (nothing "retired") so this test's checks aren't affected

  logic [WIDTH-1:0] out_valid;
  iflight_t         out_data[WIDTH];
  logic             occupied, avail;

  int errors = 0;
  task automatic check(string name, logic cond);
    if (cond === 1'b1) $display("PASS: %s", name);
    else begin errors++; $display("FAIL: %s (cond=%b)", name, cond); end
  endtask

  sched_reg #(.WIDTH(WIDTH), .ROB_SIZE(ROB_SIZE)) dut (.*);

  function automatic iflight_t mk_instr(logic [SEQ_W-1:0] seq,
                                          logic s1_is_rob, logic [8:0] s1_tag, logic s1_ready);
    iflight_t t;
    t = '0;
    t.valid = 1'b1;
    t.seq_no = seq;
    t.src1.valid = 1'b1;
    t.src1.is_rob = s1_is_rob;
    t.src1.tag = s1_tag;
    t.src1_ready = s1_ready;
    t.src2_ready = 1'b1; // src2 unused in this test, keep it trivially ready
    return t;
  endfunction

  task automatic clear_in();
    in_valid = '0; in_fire = 0;
    for (int i=0;i<WIDTH;i++) in_data[i] = '0;
  endtask

  task automatic clear_wb();
    wb_valid = '0;
    for (int w=0;w<WB_PORTS;w++) wb_idx[w] = '0;
  endtask

  initial begin
    clear_in(); clear_wb(); consume = 0;
    for (int e=0;e<ROB_SIZE;e++) entry_gen[e] = '0;
    entry_valid = '1;
    rst_n = 0; @(posedge clk); @(posedge clk); rst_n = 1; @(posedge clk); #1;

    check("reset: not occupied", occupied === 1'b0);

    // Push one instruction waiting on ROB idx 3 (not ready yet)
    in_valid[0] = 1; in_data[0] = mk_instr(42, 1'b1, 9'd3, 1'b0);
    in_fire = 1;
    @(posedge clk); #1;
    clear_in();

    check("loaded: occupied", occupied === 1'b1);
    check("loaded: src1_ready starts false", out_data[0].src1_ready === 1'b0);

    // Stall for a couple cycles with no consume and no wakeup -- should
    // stay not-ready (this is the "old bug" scenario: a bare pipe_reg
    // would never learn about a wakeup that happens later while stalled)
    @(posedge clk); #1;
    check("still stalled, still not ready (no wakeup yet)", out_data[0].src1_ready === 1'b0);

    // NOW the producer finishes while we're still stalled here
    clear_wb();
    wb_valid[0] = 1; wb_idx[0] = 3;
    #1;
    check("same-cycle wakeup while stalled: EFFECTIVE ready NOW true",
          out_data[0].src1_ready === 1'b1);

    // advance the clock with the wakeup still asserted, then drop it,
    // and confirm the REGISTERED bit latched it (persists after broadcast ends)
    @(posedge clk); #1;
    clear_wb();
    check("after latch: ready persists with broadcast gone", out_data[0].src1_ready === 1'b1);

    // Now consume it
    consume = 1;
    @(posedge clk); #1;
    consume = 0;
    check("after consume: empty", occupied === 1'b0);

    if (errors == 0) $display("ALL PASS");
    else $display("%0d FAILURES", errors);
    $finish;
  end
endmodule

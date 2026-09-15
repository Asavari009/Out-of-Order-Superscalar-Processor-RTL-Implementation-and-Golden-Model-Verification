`timescale 1ns/1ps
`include "ooo_pkg.sv"

module tb_rob;
  import ooo_pkg::*;

  localparam int WIDTH    = 2;
  localparam int ROB_SIZE = 4;
  localparam int IDX_W    = $clog2(ROB_SIZE);
  localparam int WB_PORTS = WIDTH * MAX_LATENCY;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic [IDX_W:0]   free_entries;
  logic [ROB_SIZE-1:0] entry_ready;
  logic [ROB_SIZE-1:0] entry_valid;
  logic [GEN_W-1:0] entry_gen [ROB_SIZE];
  logic [IDX_W-1:0] alloc_rob_idx [WIDTH];
  logic [GEN_W-1:0] alloc_gen [WIDTH];

  logic                  alloc_fire;
  logic [WIDTH-1:0]      alloc_valid;
  logic [ARCH_REG_W-1:0] alloc_dst_areg[WIDTH];
  logic [WIDTH-1:0]      alloc_dst_has;
  logic [PC_W-1:0]       alloc_pc[WIDTH];
  logic [SEQ_W-1:0]      alloc_seq_no[WIDTH];

  logic [WB_PORTS-1:0]   wb_valid;
  logic [IDX_W-1:0]      wb_idx[WB_PORTS];

  logic                  retire_fire;
  logic [WIDTH-1:0]      rt_valid;
  logic [ARCH_REG_W-1:0] rt_dst_areg[WIDTH];
  logic [WIDTH-1:0]      rt_dst_has;
  logic [PC_W-1:0]       rt_pc[WIDTH];
  logic [SEQ_W-1:0]      rt_seq_no[WIDTH];
  logic [IDX_W-1:0]      rt_rob_idx[WIDTH];
  logic [$clog2(WIDTH+1)-1:0] rt_count;

  int errors = 0;

  rob #(.WIDTH(WIDTH), .ROB_SIZE(ROB_SIZE)) dut (.*);

  task automatic clear_alloc();
    alloc_fire = 0;
    // whole-vector assignment first (see tb_rmt.sv for why this matters),
    // then per-index clear of the remaining fields
    alloc_valid = '0;
    alloc_dst_has = '0;
    for (int i=0;i<WIDTH;i++) begin
      alloc_dst_areg[i]=0;
      alloc_pc[i]=0; alloc_seq_no[i]=0;
    end
  endtask

  task automatic clear_wb();
    wb_valid = '0;
    for (int w=0;w<WB_PORTS;w++) begin wb_idx[w]=0; end
  endtask

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

  initial begin
    #2000;
    $display("WATCHDOG TIMEOUT - sim stuck");
    $finish;
  end

  initial begin
    $display("sim start");
    clear_alloc(); clear_wb(); retire_fire = 0;
    rst_n = 0; @(posedge clk); $display("t1"); @(posedge clk); $display("t2"); rst_n = 1; @(posedge clk); $display("t3");

    // free entries should be ROB_SIZE at reset
    check("reset free_entries == ROB_SIZE", free_entries == ROB_SIZE);

    // allocate 2 instructions (seq 0,1), dst regs 5 and 6
    clear_alloc();
    alloc_fire = 1;
    alloc_valid[0]=1; alloc_dst_areg[0]=5; alloc_dst_has[0]=1; alloc_pc[0]=64'h100; alloc_seq_no[0]=0;
    alloc_valid[1]=1; alloc_dst_areg[1]=6; alloc_dst_has[1]=1; alloc_pc[1]=64'h104; alloc_seq_no[1]=1;
    check("alloc_rob_idx[0]==0", alloc_rob_idx[0] == 0);
    check("alloc_rob_idx[1]==1", alloc_rob_idx[1] == 1);
    @(posedge clk);
    clear_alloc();
    #1;
    check("free_entries==2 after alloc 2", free_entries == 2);

    // nothing ready yet -> retire fires but nothing retires
    retire_fire = 1;
    @(posedge clk); #1;
    check("rt_count==0 (nothing ready)", rt_count == 0);

    // wakeup entry 0 (seq 0) via wb port 0
    clear_wb();
    wb_valid[0] = 1; wb_idx[0] = 0;
    @(posedge clk); #1;
    clear_wb();

    // ready_q[0] is now set; check the combinational retire-select output
    // BEFORE the next clock edge consumes it (retire is level-sensitive,
    // not itself clocked, so it's already valid here)
    check("rt_count==1 (pre-edge, entry0 ready)", rt_count == 1);
    check("rt_valid[0]==1", rt_valid[0] == 1);
    check("rt_rob_idx[0]==0", rt_rob_idx[0] == 0);
    check("rt_dst_areg[0]==5", rt_dst_areg[0] == 5);
    check("rt_seq_no[0]==0", rt_seq_no[0] == 0);
    check("entry_ready[0]==1 (readiness query port)", entry_ready[0] == 1'b1);
    check("entry_ready[1]==0 (not woken)", entry_ready[1] == 1'b0);

    // now let the clock edge actually perform the retire
    @(posedge clk); #1;

    @(posedge clk); #1;
    check("free_entries==3 after 1 retire", free_entries == 3);

    if (errors == 0) $display("ALL PASS");
    else $display("%0d FAILURES", errors);
    $finish;
  end
endmodule

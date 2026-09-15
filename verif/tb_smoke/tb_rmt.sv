`timescale 1ns/1ps
`include "ooo_pkg.sv"

module tb_rmt;
  import ooo_pkg::*;

  localparam int WIDTH = 2;
  localparam int ROB_SIZE = 8;
  localparam int ROBIDX_W = $clog2(ROB_SIZE);

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic                  rn_fire;
  logic [WIDTH-1:0]      rn_valid;
  logic [ARCH_REG_W-1:0] rn_src1_areg[WIDTH];
  logic [WIDTH-1:0]      rn_src1_has;
  logic [ARCH_REG_W-1:0] rn_src2_areg[WIDTH];
  logic [WIDTH-1:0]      rn_src2_has;
  logic [ARCH_REG_W-1:0] rn_dst_areg[WIDTH];
  logic [WIDTH-1:0]      rn_dst_has;
  logic [ROBIDX_W-1:0]   rn_rob_idx[WIDTH];
  logic [GEN_W-1:0]      rn_gen[WIDTH];

  src_tag_t rn_src1_tag[WIDTH];
  src_tag_t rn_src2_tag[WIDTH];

  logic [WIDTH-1:0]      rt_valid;
  logic [ARCH_REG_W-1:0] rt_areg[WIDTH];
  logic [ROBIDX_W-1:0]   rt_rob_idx[WIDTH];

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

  // Icarus (local smoke test only) crashes on `array_of_struct_signal[i].field`
  // read from outside the module (elab_expr.cc assertion), and separately
  // doesn't support field access chained directly onto a function call
  // result. Work around both by copying into a plain local variable first,
  // then field-accessing that. Real simulators don't need this workaround.
  src_tag_t tmp1, tmp2;

  rmt #(.WIDTH(WIDTH), .ROB_SIZE(ROB_SIZE)) dut (.*);

  initial begin
    rn_fire = 0;
    // IMPORTANT: the very first assignment to a packed-vector port signal
    // must be a WHOLE-VECTOR assignment, not a per-bit/indexed one --
    // confirmed by direct comparison: initializing via a per-bit loop here
    // left downstream combinational logic permanently stuck reading stale
    // values for that signal, while whole-vector init did not. Once a
    // signal has been assigned as a whole at least once, later per-bit
    // assignment (e.g. rn_valid[0]=1;) works fine, as seen throughout the
    // rest of this file.
    rn_valid = '0; rn_src1_has = '0; rn_src2_has = '0; rn_dst_has = '0;
    for (int i=0;i<WIDTH;i++) begin
      rn_src1_areg[i]=0; rn_src2_areg[i]=0; rn_dst_areg[i]=0; rn_rob_idx[i]=0; rn_gen[i]=0;
    end
    rt_valid = '0;
    for (int i=0;i<WIDTH;i++) begin rt_areg[i]=0; rt_rob_idx[i]=0; end

    rst_n = 0; @(posedge clk); @(posedge clk); rst_n = 1; @(posedge clk); #1;

    // Bundle: instr0 writes r5 (rob idx 3), instr1 reads r5 as src1.
    // Since r5 was never renamed before, instr0's src lookups should be
    // "already committed" (is_rob=0). instr1's src1 must see instr0's
    // FRESH rename (is_rob=1, tag=3) -- this is the intra-bundle
    // forwarding the C++ model gets for free from its sequential loop.
    rn_valid[0]=1; rn_dst_has[0]=1; rn_dst_areg[0]=5; rn_rob_idx[0]=3;
    rn_src1_has[0]=0; rn_src2_has[0]=0;

    rn_valid[1]=1; rn_src1_has[1]=1; rn_src1_areg[1]=5; rn_rob_idx[1]=4;
    rn_dst_has[1]=0; rn_src2_has[1]=0;
    #1;
    tmp1 = rn_src1_tag[1];
    check("instr1.src1.valid==1", tmp1.valid == 1);
    check("instr1.src1.is_rob==1 (renamed within same bundle)", tmp1.is_rob == 1);
    check("instr1.src1.tag==3 (instr0's rob idx)", tmp1.tag == 3);

    rn_fire = 1;
    @(posedge clk); #1;
    rn_fire = 0;
    for (int i=0;i<WIDTH;i++) begin rn_valid[i]=0; rn_dst_has[i]=0; rn_src1_has[i]=0; end

    // Now a fresh lookup of r5 (no bundle in flight) should show the
    // committed rename: is_rob=1, tag=3 (instr0's rob idx), from state.
    rn_valid[0]=1; rn_src1_has[0]=1; rn_src1_areg[0]=5; rn_dst_has[0]=0;
    #1;
    tmp1 = rn_src1_tag[0];
    check("post-cycle lookup of r5: valid", tmp1.valid == 1);
    check("post-cycle lookup of r5: is_rob", tmp1.is_rob == 1);
    check("post-cycle lookup of r5: tag==3", tmp1.tag == 3);
    rn_valid[0] = 0; rn_src1_has[0] = 0;

    // Retire ROB idx 3 (the instr0 that wrote r5) -> RMT[5] should clear
    rt_valid = '0; rt_valid[0] = 1'b1; rt_areg[0] = 5; rt_rob_idx[0] = 3;
    @(posedge clk); #1;
    rt_valid = '0;

    rn_valid[0]=1; rn_src1_has[0]=1; rn_src1_areg[0]=5;
    #1;
    tmp1 = rn_src1_tag[0];
    check("after retire, r5 lookup is_rob==0 (committed/free)", tmp1.is_rob == 0);
    check("after retire, r5 lookup valid==1 (has a value, just not pending)", tmp1.valid == 1);
    rn_valid[0] = 0; rn_src1_has[0] = 0;

    // ---------------------------------------------------------------
    // Multi-way retire test: rename r6 (rob idx 4) and r7 (rob idx 5) in
    // one bundle, then retire BOTH in the SAME cycle via two different
    // retire ports. Both mappings must clear -- this is the whole point
    // of widening the retire port to WIDTH-wide.
    // ---------------------------------------------------------------
    rn_valid[0]=1; rn_dst_has[0]=1; rn_dst_areg[0]=6; rn_rob_idx[0]=4;
    rn_valid[1]=1; rn_dst_has[1]=1; rn_dst_areg[1]=7; rn_rob_idx[1]=5;
    rn_src1_has[0]=0; rn_src1_has[1]=0; rn_src2_has[0]=0; rn_src2_has[1]=0;
    rn_fire = 1;
    @(posedge clk); #1;
    rn_fire = 0;
    for (int i=0;i<WIDTH;i++) begin rn_valid[i]=0; rn_dst_has[i]=0; end

    rt_valid = '0;
    rt_valid[0] = 1'b1; rt_areg[0] = 6; rt_rob_idx[0] = 4;
    rt_valid[1] = 1'b1; rt_areg[1] = 7; rt_rob_idx[1] = 5;
    @(posedge clk); #1;
    rt_valid = '0;

    rn_valid[0]=1; rn_src1_has[0]=1; rn_src1_areg[0]=6;
    rn_valid[1]=1; rn_src1_has[1]=1; rn_src1_areg[1]=7;
    #1;
    tmp1 = rn_src1_tag[0];
    tmp2 = rn_src1_tag[1];
    check("multi-retire: r6 cleared (is_rob==0)", tmp1.is_rob == 0);
    check("multi-retire: r7 also cleared (is_rob==0)", tmp2.is_rob == 0);
    rn_valid[0] = 0; rn_src1_has[0] = 0;
    rn_valid[1] = 0; rn_src1_has[1] = 0;

    // ---------------------------------------------------------------
    // WAW test: instr0 and instr1, SAME bundle, BOTH write r9 (rob idx
    // 6 and 7 respectively). Program order says instr1's write is the
    // one that must "win" -- a later lookup of r9 must see tag=7, not
    // tag=6, and instr1's own rename (as instr1 also happens to read
    // r9 as src2 here, i.e. RAW+WAW in the same bundle) must see
    // instr0's write via intra-bundle forwarding, not its own.
    // ---------------------------------------------------------------
    rn_valid[0]=1; rn_dst_has[0]=1; rn_dst_areg[0]=9; rn_rob_idx[0]=6;
    rn_src1_has[0]=0; rn_src2_has[0]=0;

    rn_valid[1]=1; rn_dst_has[1]=1; rn_dst_areg[1]=9; rn_rob_idx[1]=7;
    rn_src2_has[1]=1; rn_src2_areg[1]=9; // instr1 also reads r9 (sees instr0's write)
    rn_src1_has[1]=0;
    #1;
    tmp2 = rn_src2_tag[1];
    check("WAW: instr1 (same bundle) reading r9 sees instr0's fresh tag=6",
          tmp2.valid == 1 && tmp2.is_rob == 1 && tmp2.tag == 6);

    rn_fire = 1;
    @(posedge clk); #1;
    rn_fire = 0;
    for (int i=0;i<WIDTH;i++) begin rn_valid[i]=0; rn_dst_has[i]=0; rn_src2_has[i]=0; end

    // fresh lookup of r9 after the bundle commits: must see instr1's
    // (program-order-LATER) tag=7, not instr0's tag=6
    rn_valid[0]=1; rn_src1_has[0]=1; rn_src1_areg[0]=9;
    #1;
    tmp1 = rn_src1_tag[0];
    check("WAW: post-bundle r9 lookup sees LATER write, tag==7 (not 6)",
          tmp1.valid == 1 && tmp1.is_rob == 1 && tmp1.tag == 7);
    rn_valid[0] = 0; rn_src1_has[0] = 0;

    if (errors == 0) $display("ALL PASS");
    else $display("%0d FAILURES", errors);
    $finish;
  end
endmodule

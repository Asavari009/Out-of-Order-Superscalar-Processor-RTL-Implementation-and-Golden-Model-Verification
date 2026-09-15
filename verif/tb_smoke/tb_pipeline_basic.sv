`timescale 1ns/1ps
`include "ooo_pkg.sv"
// First true end-to-end integration test: feeds two instructions with a
// real RAW dependency through the FULLY ASSEMBLED pipeline (DE->RN->RR->
// DI->IQ->EX->ROB->Retire, all combinational backpressure wired) and
// confirms the dependent instruction correctly waits for and retires
// after its producer. This is the first test that exercises the actual
// stage-to-stage wiring in ooo_pipeline.sv, not an isolated module.
module tb_pipeline_basic;
  import ooo_pkg::*;
  localparam int WIDTH=2, ROB_SIZE=8, IQ_SIZE=8;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;

  logic [WIDTH-1:0] fe_valid;
  decoded_instr_t fe_data[WIDTH];
  logic fe_fire;
  logic de_ready_for_fetch;

  logic [WIDTH-1:0] rt_valid;
  logic [ARCH_REG_W-1:0] rt_dst_areg[WIDTH];
  logic [WIDTH-1:0] rt_dst_has;
  logic [PC_W-1:0] rt_pc[WIDTH];
  logic [SEQ_W-1:0] rt_seq_no[WIDTH];
  logic [$clog2(ROB_SIZE)-1:0] rt_rob_idx[WIDTH];
  logic [$clog2(WIDTH+1)-1:0] rt_count;

  ooo_pipeline #(.WIDTH(WIDTH), .ROB_SIZE(ROB_SIZE), .IQ_SIZE(IQ_SIZE)) dut(.*);

  int retire_cycle[10];
  int errors = 0;
  task automatic check(string name, logic cond);
    if (cond === 1'b1) $display("PASS: %s", name);
    else begin errors++; $display("FAIL: %s", name); end
  endtask

  initial begin
    fe_valid = '0; fe_fire = 0;
    for (int i=0;i<WIDTH;i++) fe_data[i] = '0;
    for (int i=0;i<10;i++) retire_cycle[i] = -1;
    rst_n=0; @(posedge clk); @(posedge clk); rst_n=1; @(posedge clk); #1;

    // instr0: op_type2 (latency 5), dst=r1, no srcs -- the long-latency producer
    // instr1: op_type0 (latency 1), dst=r2, src1=r1 -- depends on instr0!
    fe_valid = 2'b11; fe_fire=1;
    fe_data[0].seq_no=0; fe_data[0].pc=64'h100; fe_data[0].op_type=OP_TYPE2;
    fe_data[0].dst_has=1; fe_data[0].dst_areg=1;
    fe_data[0].src1_has=0; fe_data[0].src2_has=0;

    fe_data[1].seq_no=1; fe_data[1].pc=64'h104; fe_data[1].op_type=OP_TYPE0;
    fe_data[1].dst_has=1; fe_data[1].dst_areg=2;
    fe_data[1].src1_has=1; fe_data[1].src1_areg=1;
    fe_data[1].src2_has=0;

    @(posedge clk); #1;
    fe_valid='0; fe_fire=0;

    for (int c = 0; c < 40; c++) begin
      @(posedge clk); #1;
      for (int i=0;i<WIDTH;i++) begin
        if (rt_valid[i]) begin
          $display("t=%0t RETIRE seq=%0d dst=%0d", $time, rt_seq_no[i], rt_dst_areg[i]);
          retire_cycle[rt_seq_no[i]] = c;
        end
      end
    end

    check("instr0 (producer) retired", retire_cycle[0] != -1);
    check("instr1 (consumer) retired", retire_cycle[1] != -1);
    check("instr1 retires AFTER instr0 (RAW respected)", retire_cycle[1] > retire_cycle[0]);

    if (errors == 0) $display("ALL PASS");
    else $display("%0d FAILURES", errors);
    $finish;
  end
endmodule

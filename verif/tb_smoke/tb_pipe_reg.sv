`timescale 1ns/1ps
`include "ooo_pkg.sv"

module tb_pipe_reg;
  import ooo_pkg::*;

  localparam int WIDTH = 2;
  typedef logic [7:0] payload_t;

  logic clk = 0, rst_n = 0, flush = 0;
  always #5 clk = ~clk;

  logic [WIDTH-1:0] in_valid;
  payload_t         in_data[WIDTH];
  logic             in_fire;
  logic             consume;

  logic [WIDTH-1:0] out_valid;
  payload_t         out_data[WIDTH];
  logic             occupied, avail;

  int errors = 0;
  task automatic check(string name, logic cond);
    if (cond === 1'b1) $display("PASS: %s", name);
    else begin errors++; $display("FAIL: %s (cond=%b)", name, cond); end
  endtask

  pipe_reg #(.WIDTH(WIDTH), .T(payload_t)) dut (.*);

  task automatic clear_in();
    in_valid = '0; in_fire = 0;
    for (int i=0;i<WIDTH;i++) in_data[i] = 8'h00;
  endtask

  initial begin
    clear_in(); consume = 0;
    rst_n = 0; @(posedge clk); @(posedge clk); rst_n = 1; @(posedge clk); #1;

    check("reset: not occupied", occupied === 1'b0);
    check("reset: avail", avail === 1'b1);

    // Push a bundle in
    in_valid = 2'b11; in_data[0]=8'hAA; in_data[1]=8'hBB; in_fire = 1;
    @(posedge clk); #1;
    clear_in();

    check("after push: occupied", occupied === 1'b1);
    check("after push: avail is false (no consume yet)", avail === 1'b0);
    check("after push: out_data[0]==0xAA", out_data[0] == 8'hAA);
    check("after push: out_data[1]==0xBB", out_data[1] == 8'hBB);
    check("after push: out_valid==2'b11", out_valid == 2'b11);

    // Try to push AGAIN while occupied and not consumed -- must be ignored
    in_valid = 2'b11; in_data[0]=8'hFF; in_fire = 1;
    @(posedge clk); #1;
    clear_in();
    check("stalled: still holds original data (0xAA)", out_data[0] == 8'hAA);
    check("stalled: still occupied", occupied === 1'b1);

    // Now consume without a simultaneous new push -- register should empty
    consume = 1;
    @(posedge clk); #1;
    consume = 0;
    check("after consume alone: not occupied", occupied === 1'b0);
    check("after consume alone: avail", avail === 1'b1);

    // Same-cycle vacate-and-refill: assert consume AND in_fire together
    // while occupied -- new data should land THIS edge, not be dropped
    // or delayed an extra cycle.
    in_valid = 2'b01; in_data[0]=8'h11; in_fire = 1;
    @(posedge clk); #1; // load first bundle
    clear_in();
    check("loaded first bundle for refill test", out_data[0] == 8'h11 && out_valid[0] == 1'b1);

    in_valid = 2'b11; in_data[0]=8'h22; in_data[1]=8'h33; in_fire = 1;
    consume = 1; // consume old bundle AND push new one, same cycle
    #1;
    check("same-cycle avail asserted (occupied|consume)", avail === 1'b1);
    @(posedge clk); #1;
    clear_in(); consume = 0;
    check("same-cycle refill: out_data[0]==0x22 (new, not old 0x11)", out_data[0] == 8'h22);
    check("same-cycle refill: out_data[1]==0x33", out_data[1] == 8'h33);
    check("same-cycle refill: occupied", occupied === 1'b1);

    // Flush clears regardless of contents
    flush = 1;
    @(posedge clk); #1;
    flush = 0;
    check("flush clears occupied", occupied === 1'b0);

    if (errors == 0) $display("ALL PASS");
    else $display("%0d FAILURES", errors);
    $finish;
  end
endmodule

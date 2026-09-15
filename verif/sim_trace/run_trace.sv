`timescale 1ns/1ps
`include "ooo_pkg.sv"

// run_trace.sv -- reads a trace file and drives it through ooo_pipeline,
// reporting summary statistics (Dynamic Instruction Count / Cycles / IPC)
// in the same format as golden/sim_proc.cc's footer.
//
// NOT YET IMPLEMENTED: the full per-instruction FE{}DE{}RN{}...RT{}
// report line. That needs careful per-field begin/duration semantics
// matching (see docs/README.md) -- this is the "UVM monitor" work,
// still ahead. What this DOES give you: does the whole assembled
// pipeline produce the right ANSWER (same instruction count, same cycle
// count, same IPC) as the golden model for a real trace -- a genuine,
// meaningful checkpoint on its own.
//
// Usage: pass ROB_SIZE/IQ_SIZE/WIDTH as Verilator -G parameter overrides
// at compile time (see the Makefile), and the trace file as a runtime
// plusarg: +trace=/path/to/trace
module run_trace;
  import ooo_pkg::*;

  parameter int WIDTH    = 4;
  parameter int ROB_SIZE = 32;
  parameter int IQ_SIZE  = 16;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic [WIDTH-1:0] fe_valid;
  decoded_instr_t   fe_data[WIDTH];
  logic             fe_fire;
  logic             de_ready_for_fetch;

  logic [WIDTH-1:0]     rt_valid;
  logic [ARCH_REG_W-1:0] rt_dst_areg[WIDTH];
  logic [WIDTH-1:0]     rt_dst_has;
  logic [PC_W-1:0]      rt_pc[WIDTH];
  logic [SEQ_W-1:0]     rt_seq_no[WIDTH];
  logic [$clog2(ROB_SIZE)-1:0] rt_rob_idx[WIDTH];
  logic [$clog2(WIDTH+1)-1:0]  rt_count;

  ooo_pipeline #(.WIDTH(WIDTH), .ROB_SIZE(ROB_SIZE), .IQ_SIZE(IQ_SIZE)) dut (.*);

  // ------------------------------------------------------------------
  // Load the trace file into memory upfront (a testbench can do file
  // I/O; the RTL itself never could -- see ooo_pipeline.sv header).
  // ------------------------------------------------------------------
  decoded_instr_t trace_mem[$]; // dynamic queue, sized by however many lines the trace has
  string trace_path;
  int fd;
  int pc_hex, op_type_i, dst_i, src1_i, src2_i;
  int scan_ret;
  int total_instrs;

  initial begin
    if (!$value$plusargs("trace=%s", trace_path)) begin
      $display("ERROR: no +trace=<path> given");
      $finish;
    end
    fd = $fopen(trace_path, "r");
    if (fd == 0) begin
      $display("ERROR: could not open trace file %s", trace_path);
      $finish;
    end
    while (!$feof(fd)) begin
      scan_ret = $fscanf(fd, "%h %d %d %d %d\n", pc_hex, op_type_i, dst_i, src1_i, src2_i);
      if (scan_ret != 5) continue; // skip trailing blank lines etc.
      begin
        decoded_instr_t d;
        d = '0;
        d.seq_no    = trace_mem.size();
        d.pc        = pc_hex;
        d.op_type   = op_type_e'(op_type_i[1:0]);
        d.dst_has   = (dst_i  != -1);
        d.dst_areg  = d.dst_has  ? ARCH_REG_W'(dst_i)  : '0;
        d.src1_has  = (src1_i != -1);
        d.src1_areg = d.src1_has ? ARCH_REG_W'(src1_i) : '0;
        d.src2_has  = (src2_i != -1);
        d.src2_areg = d.src2_has ? ARCH_REG_W'(src2_i) : '0;
        trace_mem.push_back(d);
      end
    end
    $fclose(fd);
    total_instrs = trace_mem.size();
    $display("# loaded %0d instructions from %s", total_instrs, trace_path);
  end

  // ------------------------------------------------------------------
  // Fetch driver: pushes up to WIDTH instructions/cycle, respecting
  // de_ready_for_fetch. Re-drives the same batch on a stall rather than
  // dropping it (matches pipe_reg's in_fire/avail contract).
  // ------------------------------------------------------------------
  int fetch_ptr;
  int unsigned cycle_count;
  int unsigned total_retired;
  logic all_fetched;

  assign all_fetched = (fetch_ptr >= total_instrs);

  initial begin
    fe_valid = '0; fe_fire = 0;
    for (int i=0;i<WIDTH;i++) fe_data[i] = '0;
    fetch_ptr = 0;
    cycle_count = 1; // see docs/README.md note on cycle-numbering convention
    total_retired = 0;

    rst_n = 0; @(posedge clk); @(posedge clk); rst_n = 1; @(posedge clk);

    // wait for trace to finish loading (the file-read initial block runs
    // in the same delta-0 window; a small delay guarantees ordering)
    #1;

    while (total_retired < total_instrs) begin
      @(posedge clk);
      #1; // let this edge's combinational logic fully settle before
          // reading de_ready_for_fetch or rt_count -- checking
          // immediately after @(posedge clk) with no delay reads
          // pre-edge (stale) values in some simulators' scheduling,
          // causing a subtle off-by-one-cycle misalignment.
      cycle_count++;
      if (de_ready_for_fetch && !all_fetched) begin
        fe_fire = 1;
        fe_valid = '0;
        for (int i = 0; i < WIDTH; i++) begin
          if (fetch_ptr + i < total_instrs) begin
            fe_valid[i] = 1'b1;
            fe_data[i]  = trace_mem[fetch_ptr + i];
          end
        end
        fetch_ptr = fetch_ptr + ((total_instrs - fetch_ptr) < WIDTH ? (total_instrs - fetch_ptr) : WIDTH);
      end else if (de_ready_for_fetch && all_fetched) begin
        fe_fire = 0;
        fe_valid = '0;
      end
      // else: de_ready_for_fetch was false -- hold current fe_valid/fe_data,
      // re-presenting the same request next cycle (do nothing here)

      if (rt_count > 0) total_retired += rt_count;

      if (cycle_count % 1000 == 0) begin
        $display("# progress: cycle=%0d fetched=%0d/%0d retired=%0d de_ready=%b",
                  cycle_count, fetch_ptr, total_instrs, total_retired, de_ready_for_fetch);
      end

      if (cycle_count > 2_000_000) begin
        $display("ERROR: exceeded 2,000,000 cycles without draining -- likely a real hang, not a slow trace");
        $finish;
      end
    end

    $display("# === Simulator Command =========");
    $display("# (run_trace.sv) %s", trace_path);
    $display("# === Processor Configuration ===");
    $display("# ROB_SIZE = %0d", ROB_SIZE);
    $display("# IQ_SIZE  = %0d", IQ_SIZE);
    $display("# WIDTH    = %0d", WIDTH);
    $display("# === Simulation Results ========");
    $display("# Dynamic Instruction Count    = %0d", total_retired);
    $display("# Cycles                       = %0d", cycle_count);
    $display("# Instructions Per Cycle (IPC) = %.2f", real'(total_retired) / real'(cycle_count));
    $finish;
  end

endmodule : run_trace

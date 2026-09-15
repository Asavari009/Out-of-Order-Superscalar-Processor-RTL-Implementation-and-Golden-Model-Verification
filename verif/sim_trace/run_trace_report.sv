`timescale 1ns/1ps
`include "ooo_pkg.sv"

// run_trace_report.sv -- like run_trace.sv, but reconstructs the FULL
// per-instruction FE{}DE{}RN{}RR{}DI{}IS{}EX{}WB{}RT{} report line,
// matching golden/sim_proc.cc's exact format and timestamp semantics
// (verified directly against the C++ source, not guessed):
//
//   FE.begin  = cycle instruction is pushed at the fetch port (fe_fire)
//   DE.begin  = FE.begin + 1                          (always, by construction:
//               Fetch() only fires when DE is guaranteed empty next cycle)
//   RN.begin  = cycle decode_fire moves it into RN
//   RR.begin  = cycle rename_fire moves it into RR
//   DI.begin  = cycle regread_fire moves it into DI
//   IS.begin  = cycle dispatch_fire moves it into the IQ
//   EX.begin  = cycle the IQ selects it (sel_valid)
//   WB.begin  = cycle exec_units broadcasts its completion (wb_valid)
//   RT.begin  = WB.begin + 1                          (always, by construction:
//               this design has no separate WB holding register --
//               exec_units' broadcast directly feeds the ROB's registered
//               ready_q, which takes effect the cycle after the broadcast)
//   <stage>.duration = next_stage.begin - this_stage.begin, except
//   RT.duration = actual_retire_cycle - RT.begin  (queueing delay at the
//                 head of the ROB when WIDTH>1 instructions are ready
//                 simultaneously but can only retire one at a time)
//
// Prints in retire order, which is always increasing seq_no (ROB retires
// strictly in-order), matching golden's own "program order" guarantee.
module run_trace_report;
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
  // Trace loading (same as run_trace.sv)
  // ------------------------------------------------------------------
  decoded_instr_t trace_mem[$];
  string trace_path;
  int fd, pc_hex, op_type_i, dst_i, src1_i, src2_i, scan_ret, total_instrs;

  initial begin
    if (!$value$plusargs("trace=%s", trace_path)) begin
      $display("ERROR: no +trace=<path> given"); $finish;
    end
    fd = $fopen(trace_path, "r");
    if (fd == 0) begin $display("ERROR: could not open trace file %s", trace_path); $finish; end
    while (!$feof(fd)) begin
      scan_ret = $fscanf(fd, "%h %d %d %d %d\n", pc_hex, op_type_i, dst_i, src1_i, src2_i);
      if (scan_ret != 5) continue;
      begin
        decoded_instr_t d;
        d = '0;
        d.seq_no    = trace_mem.size();
        d.pc        = pc_hex;
        d.op_type   = op_type_e'(op_type_i[1:0]);
        d.dst_has   = (dst_i  != -1); d.dst_areg  = d.dst_has  ? ARCH_REG_W'(dst_i)  : '0;
        d.src1_has  = (src1_i != -1); d.src1_areg = d.src1_has ? ARCH_REG_W'(src1_i) : '0;
        d.src2_has  = (src2_i != -1); d.src2_areg = d.src2_has ? ARCH_REG_W'(src2_i) : '0;
        trace_mem.push_back(d);
      end
    end
    $fclose(fd);
    total_instrs = trace_mem.size();
  end

  // ------------------------------------------------------------------
  // Per-instruction stage-timestamp tracking (associative arrays keyed
  // by seq_no -- sized for the whole trace, sparse storage)
  // ------------------------------------------------------------------
  int fe_begin[int], de_begin[int], rn_begin[int], rr_begin[int];
  int di_begin[int], is_begin[int], ex_begin[int], wb_begin[int], rt_begin_arr[int];
  // op/src/dst info for the report line, captured at fetch time
  op_type_e op_type_arr[int];
  logic [ARCH_REG_W-1:0] dst_arr[int], src1_arr[int], src2_arr[int];
  logic dst_has_arr[int], src1_has_arr[int], src2_has_arr[int];

  int fetch_ptr;
  int unsigned cycle_count;
  int unsigned total_retired;
  logic all_fetched;
  // Plain fixed-size array instead of an associative array as the
  // "already retired" guard -- avoiding any possible tool-version-
  // specific associative-array/.exists() quirk, since the associative-
  // array version did not reliably block repeats when tested on a
  // newer tool version (unconfirmed whether that's a tool issue or
  // symptom of a deeper RTL issue -- see diagnostic prints below).
  bit already_retired_arr[100000];
  assign all_fetched = (fetch_ptr >= total_instrs);

  function automatic string fmt_reg(logic has, logic [ARCH_REG_W-1:0] r);
    return has ? $sformatf("%0d", r) : "-1";
  endfunction

  initial begin
    fe_valid = '0; fe_fire = 0;
    for (int i=0;i<WIDTH;i++) fe_data[i] = '0;
    for (int i=0;i<100000;i++) already_retired_arr[i] = 1'b0;
    fetch_ptr = 0; cycle_count = 1; total_retired = 0;

    rst_n = 0; @(posedge clk); @(posedge clk); rst_n = 1; @(posedge clk);
    #1;

    while (total_retired < total_instrs) begin
      @(posedge clk);
      #1;
      cycle_count++;

      // ---- fetch ----
      if (de_ready_for_fetch && !all_fetched) begin
        fe_fire = 1;
        fe_valid = '0;
        for (int i = 0; i < WIDTH; i++) begin
          if (fetch_ptr + i < total_instrs) begin
            fe_valid[i] = 1'b1;
            fe_data[i]  = trace_mem[fetch_ptr + i];
            fe_begin[fe_data[i].seq_no] = cycle_count - 1; // FE uses cycle_count-1, see header
            de_begin[fe_data[i].seq_no] = cycle_count;     // DE = FE+1 always
            op_type_arr[fe_data[i].seq_no]  = fe_data[i].op_type;
            dst_arr[fe_data[i].seq_no]      = fe_data[i].dst_areg;
            dst_has_arr[fe_data[i].seq_no]  = fe_data[i].dst_has;
            src1_arr[fe_data[i].seq_no]     = fe_data[i].src1_areg;
            src1_has_arr[fe_data[i].seq_no] = fe_data[i].src1_has;
            src2_arr[fe_data[i].seq_no]     = fe_data[i].src2_areg;
            src2_has_arr[fe_data[i].seq_no] = fe_data[i].src2_has;
          end
        end
        fetch_ptr = fetch_ptr + ((total_instrs - fetch_ptr) < WIDTH ? (total_instrs - fetch_ptr) : WIDTH);
      end else if (de_ready_for_fetch && all_fetched) begin
        fe_fire = 0; fe_valid = '0;
      end

      // ---- stage-transition probes (hierarchical) ----
      if (dut.decode_fire) begin
        for (int i = 0; i < WIDTH; i++)
          if (dut.de_valid[i]) rn_begin[dut.de_data[i].seq_no] = cycle_count;
      end
      if (dut.rename_fire) begin
        for (int i = 0; i < WIDTH; i++)
          if (dut.rn_valid[i]) rr_begin[dut.rn_data[i].seq_no] = cycle_count;
      end
      if (dut.regread_fire) begin
        for (int i = 0; i < WIDTH; i++)
          if (dut.rr_valid[i]) di_begin[dut.rr_data[i].seq_no] = cycle_count;
      end
      if (dut.dispatch_fire) begin
        for (int i = 0; i < WIDTH; i++)
          if (dut.di_valid[i]) is_begin[dut.di_data[i].seq_no] = cycle_count;
      end
      for (int i = 0; i < WIDTH; i++) begin
        if (dut.sel_valid[i]) ex_begin[dut.sel_seq_no[i]] = cycle_count;
      end
      for (int w = 0; w < WIDTH*MAX_LATENCY; w++) begin
        if (dut.u_exu.wb_valid[w]) begin
          wb_begin[dut.u_exu.wb_seq_no[w]]     = cycle_count;
          rt_begin_arr[dut.u_exu.wb_seq_no[w]] = cycle_count + 1; // RT = WB+1 always
        end
      end

      // ---- retire: print the report line now (all timestamps known) ----
      // Uses top-level ports (rt_count/rt_valid/rt_seq_no), NOT
      // hierarchical dut.-prefixed access -- a minimal bisection test
      // (run_trace_retirelog_diag.sv) proved these top-level ports work
      // correctly even on the tool version that broke the earlier
      // hierarchical-access version of this exact block. The real
      // problem is somewhere in the stage-tracking hierarchical probes
      // below, not port propagation.
      if (rt_count > 0) begin
        for (int i = 0; i < WIDTH; i++) begin
          if (rt_valid[i]) begin
            automatic int seq = rt_seq_no[i];
            if (already_retired_arr[seq]) begin
              // DIAGNOSTIC: this should never happen. If it does, print
              // enough ROB internal state to tell whether the ROB itself
              // is genuinely stuck re-retiring the same entry (real RTL
              // bug) or whether this is purely a signal-reading artifact
              // in this testbench.
              $display("REPEAT-RETIRE DETECTED at cycle=%0d: seq=%0d already seen. head_q=%0d v_q[head]=%b ready_q[head]=%b rt_count=%0d",
                        cycle_count, seq, dut.u_rob.head_q, dut.u_rob.v_q[dut.u_rob.head_q],
                        dut.u_rob.ready_q[dut.u_rob.head_q], rt_count);
            end else begin
              already_retired_arr[seq] = 1'b1;
              $display("%0d fu{%0d} src{%0s,%0s} dst{%0s} FE{%0d,%0d} DE{%0d,%0d} RN{%0d,%0d} RR{%0d,%0d} DI{%0d,%0d} IS{%0d,%0d} EX{%0d,%0d} WB{%0d,%0d} RT{%0d,%0d}",
                seq, op_type_arr[seq],
                fmt_reg(src1_has_arr[seq], src1_arr[seq]), fmt_reg(src2_has_arr[seq], src2_arr[seq]),
                fmt_reg(dst_has_arr[seq], dst_arr[seq]),
                fe_begin[seq], de_begin[seq]-fe_begin[seq],
                de_begin[seq], rn_begin[seq]-de_begin[seq],
                rn_begin[seq], rr_begin[seq]-rn_begin[seq],
                rr_begin[seq], di_begin[seq]-rr_begin[seq],
                di_begin[seq], is_begin[seq]-di_begin[seq],
                is_begin[seq], ex_begin[seq]-is_begin[seq],
                ex_begin[seq], wb_begin[seq]-ex_begin[seq],
                wb_begin[seq], rt_begin_arr[seq]-wb_begin[seq],
                rt_begin_arr[seq], (cycle_count+1)-rt_begin_arr[seq]
              );
              total_retired++;
            end
          end
        end
      end

      if (cycle_count > 2_000_000) begin
        $display("ERROR: exceeded 2,000,000 cycles without draining");
        $finish;
      end
    end

    $display("# === Simulator Command =========");
    $display("# (run_trace_report.sv) %s", trace_path);
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

endmodule : run_trace_report

//=============================================================================
// ooo_pipeline.sv -- top-level integration
//
// Wires together: DE/RN (pipe_reg) -> Rename (rmt.sv) -> RR/DI (sched_reg)
// -> Dispatch+Issue (issue_queue.sv) -> Execute (exec_units.sv) -> Retire
// (rob.sv, which also does allocation at Rename time).
//
// PIPELINE REGISTER NAMING (matches the spec exactly -- named for the
// stage each one feeds INTO, per Section 5.1 Table 1):
//   DE feeds Decode   (holds fetched, undecoded data -- decode is a pure
//                       identity passthrough here; see decoded_instr_t)
//   RN feeds Rename   (holds decoded, unrenamed data)
//   RR feeds RegRead  (holds renamed data: tags assigned, readiness TBD)
//   DI feeds Dispatch (holds renamed + readiness-checked data)
// then the Issue Queue itself is the register feeding Issue, exec_units'
// internal pooled slots are the register feeding Writeback, and the ROB's
// own retire-selection is what feeds Retire -- no separate registers
// needed for those two, see rtl/exec_units.sv and rtl/rob.sv headers.
//
// BACKPRESSURE, THE HARDWARE-NATIVE VERSION OF THE C++ MODEL'S REVERSE
// CALL ORDER: the golden model calls Retire()...Fetch() in reverse order
// each software "cycle" specifically so a stage sees the PREVIOUS stage's
// already-updated-this-cycle state. Real hardware doesn't need that
// trick -- every always_ff fires in parallel on the same edge -- but the
// combinational "can I advance" logic below is computed in the exact
// same reverse (downstream-to-upstream) dependency direction, which is
// what makes it equivalent: each `*_fire` signal here depends on the
// NEXT stage's availability, chaining from Retire (unconditional) back
// to the external fetch port (`de_ready_for_fetch`).
//
// EXTERNAL FETCH PORT CONTRACT: this design cannot read a trace file
// itself (synthesizable RTL has no file I/O) -- an external driver
// (later, the UVM trace_driver) supplies WIDTH decoded instructions per
// cycle on fe_valid/fe_data, gated by fe_fire. The driver MUST check
// de_ready_for_fetch before deciding whether its push this cycle will
// actually land: if false, the push is silently dropped (matching
// pipe_reg's in_fire/avail contract) and the driver must re-drive the
// SAME bundle next cycle rather than advancing its trace pointer.
//=============================================================================
`include "ooo_pkg.sv"

module ooo_pipeline
  import ooo_pkg::*;
#(
  parameter int WIDTH    = 4,
  parameter int ROB_SIZE = 32,
  parameter int IQ_SIZE  = 16,
  localparam int ROBIDX_W = $clog2(ROB_SIZE),
  localparam int WB_PORTS = WIDTH * MAX_LATENCY
)(
  input  logic clk,
  input  logic rst_n,

  // ---- external fetch port (driven by a testbench/driver) --------------
  input  logic [WIDTH-1:0]   fe_valid,
  input  decoded_instr_t     fe_data [WIDTH],
  input  logic                fe_fire,
  output logic                de_ready_for_fetch,

  // ---- retire output (for a verification monitor to observe) -----------
  output logic [WIDTH-1:0]     rt_valid,
  output logic [ARCH_REG_W-1:0] rt_dst_areg[WIDTH],
  output logic [WIDTH-1:0]     rt_dst_has,
  output logic [PC_W-1:0]      rt_pc      [WIDTH],
  output logic [SEQ_W-1:0]     rt_seq_no  [WIDTH],
  output logic [ROBIDX_W-1:0]  rt_rob_idx [WIDTH],
  output logic [$clog2(WIDTH+1)-1:0] rt_count
);

  // ------------------------------------------------------------------
  // DE register (fetch -> decode boundary)
  // ------------------------------------------------------------------
  logic [WIDTH-1:0] de_valid;
  decoded_instr_t   de_data[WIDTH];
  logic             de_occupied, de_avail, decode_fire;

  pipe_reg #(.WIDTH(WIDTH), .T(decoded_instr_t)) u_de (
    .clk(clk), .rst_n(rst_n), .flush(1'b0),
    .in_valid(fe_valid), .in_data(fe_data), .in_fire(fe_fire),
    .consume(decode_fire),
    .out_valid(de_valid), .out_data(de_data),
    .occupied(de_occupied), .avail(de_avail)
  );
  assign de_ready_for_fetch = de_avail;

  // ------------------------------------------------------------------
  // RN register (decode -> rename boundary). Decode is identity: RN's
  // input is just DE's current output, unchanged.
  // ------------------------------------------------------------------
  logic [WIDTH-1:0] rn_valid;
  decoded_instr_t   rn_data[WIDTH];
  logic             rn_occupied, rn_avail, rename_fire;

  assign decode_fire = de_occupied && rn_avail;

  pipe_reg #(.WIDTH(WIDTH), .T(decoded_instr_t)) u_rn (
    .clk(clk), .rst_n(rst_n), .flush(1'b0),
    .in_valid(de_valid), .in_data(de_data), .in_fire(decode_fire),
    .consume(rename_fire),
    .out_valid(rn_valid), .out_data(rn_data),
    .occupied(rn_occupied), .avail(rn_avail)
  );

  // ------------------------------------------------------------------
  // Rename (rmt.sv) + ROB allocation, gated on: RN occupied, RR has
  // room, AND the ROB has enough free entries for the whole bundle
  // (matches the spec's Rename() gating exactly).
  // ------------------------------------------------------------------
  logic [ROBIDX_W:0]   rob_free_entries;
  logic [ROB_SIZE-1:0] rob_entry_ready; // reserved for future use (RR/DI ready recompute from registered state -- currently sched_reg only uses live wb broadcast; see docs/README.md limitations note)
  logic [GEN_W-1:0]    rob_entry_gen[ROB_SIZE]; // live generation per ROB slot, for staleness detection (see ooo_pkg.sv GEN_W)
  logic [ROB_SIZE-1:0] rob_entry_valid; // is each slot currently allocated at all (see rob.sv entry_valid comment)
  logic [ROBIDX_W-1:0] alloc_rob_idx[WIDTH];
  logic [GEN_W-1:0]    alloc_gen[WIDTH]; // generation each newly-allocated slot will carry

  logic [WIDTH-1:0] rn_src1_has_p, rn_src2_has_p, rn_dst_has_p;
  logic [ARCH_REG_W-1:0] rn_src1_areg_p[WIDTH], rn_src2_areg_p[WIDTH], rn_dst_areg_p[WIDTH];
  logic [PC_W-1:0]  rn_pc_p[WIDTH];
  logic [SEQ_W-1:0] rn_seq_no_p[WIDTH];
  logic [$clog2(WIDTH+1)-1:0] rn_valid_count;

  always_comb begin
    for (int i = 0; i < WIDTH; i++) begin
      rn_src1_has_p[i]  = rn_data[i].src1_has;
      rn_src2_has_p[i]  = rn_data[i].src2_has;
      rn_dst_has_p[i]   = rn_data[i].dst_has;
      rn_src1_areg_p[i] = rn_data[i].src1_areg;
      rn_src2_areg_p[i] = rn_data[i].src2_areg;
      rn_dst_areg_p[i]  = rn_data[i].dst_areg;
      rn_pc_p[i]        = rn_data[i].pc;
      rn_seq_no_p[i]    = rn_data[i].seq_no;
    end
    rn_valid_count = $countones(rn_valid);
  end

  src_tag_t rn_src1_tag[WIDTH], rn_src2_tag[WIDTH];

  // Declared here (ahead of its first use in the rename_fire assign
  // below) rather than down with the rest of the RR register's signals
  // -- QuestaSim, unlike Verilator, requires a `logic` referenced in a
  // continuous assign to be declared textually before that assign
  // (found via real compilation on Questa; Verilator silently accepted
  // the out-of-order reference). Verilator's leniency here was masking
  // a genuine style issue, not a case where the two tools disagree on
  // correct behavior -- Questa's stricter reading is the safer one to
  // follow project-wide.
  logic             rr_occupied, rr_avail, regread_fire;

  // Retire-clear feed for the RMT: up to WIDTH ports, straight from the
  // ROB's own retire outputs (see ROB instantiation below).
  logic [WIDTH-1:0]      rmt_rt_valid;
  logic [ARCH_REG_W-1:0] rmt_rt_areg[WIDTH];
  logic [ROBIDX_W-1:0]   rmt_rt_rob_idx[WIDTH];

  rmt #(.WIDTH(WIDTH), .ROB_SIZE(ROB_SIZE)) u_rmt (
    .clk(clk), .rst_n(rst_n),
    .rn_fire(rename_fire),
    .rn_valid(rn_valid),
    .rn_src1_areg(rn_src1_areg_p), .rn_src1_has(rn_src1_has_p),
    .rn_src2_areg(rn_src2_areg_p), .rn_src2_has(rn_src2_has_p),
    .rn_dst_areg(rn_dst_areg_p),   .rn_dst_has(rn_dst_has_p),
    .rn_rob_idx(alloc_rob_idx),
    .rn_gen(alloc_gen),
    .rn_src1_tag(rn_src1_tag), .rn_src2_tag(rn_src2_tag),
    .rt_valid(rmt_rt_valid), .rt_areg(rmt_rt_areg), .rt_rob_idx(rmt_rt_rob_idx)
  );

  assign rename_fire = rn_occupied && rr_avail && (rob_free_entries >= {1'b0, rn_valid_count});

  // ------------------------------------------------------------------
  // RR register (rename -> regread boundary). Loaded with the freshly
  // renamed bundle exactly when rename_fire commits. Initial readiness:
  // a committed (non-ROB) source is ready immediately; a ROB-pending
  // source starts not-ready and is tracked live by sched_reg from here.
  // ------------------------------------------------------------------
  logic [WIDTH-1:0] rr_valid;
  iflight_t         rr_in_data[WIDTH], rr_data[WIDTH];
  logic [WB_PORTS-1:0] wb_valid_bus;
  logic [ROBIDX_W-1:0] wb_idx_bus[WB_PORTS];
  logic [WIDTH-1:0] rn_src1_live_wake, rn_src2_live_wake; // see rr_in_data comment on same-cycle rename-time wakeup

  always_comb begin
    iflight_t t;
    for (int i = 0; i < WIDTH; i++) begin
      t = '0;
      t.valid      = rn_valid[i];
      t.seq_no     = rn_seq_no_p[i];
      t.pc         = rn_pc_p[i];
      t.op_type    = rn_data[i].op_type;
      t.dst_valid  = rn_dst_has_p[i];
      t.dst_areg   = rn_dst_areg_p[i];
      t.src1       = rn_src1_tag[i];
      t.src2       = rn_src2_tag[i];
      // Initial readiness at rename time: not just "not ROB-pending" --
      // ALSO check whether the ROB entry has ALREADY become ready by now
      // (rob_entry_ready), not just "will a live broadcast happen while
      // I'm sitting in a wakeup-listening stage." REAL BUG FOUND ON A
      // FULL TRACE (not any hand-built test): if a producer finishes and
      // broadcasts its wakeup BEFORE the consumer is even renamed (e.g.
      // the consumer was still sitting in DE/RN, which don't listen for
      // wakeup at all), the consumer would previously never learn its
      // dependency was already satisfied -- the broadcast pulse is long
      // gone by the time it reaches a listening stage. This was exactly
      // what `rob_entry_ready` was added for (see rob.sv), but it was
      // wired as an output and never actually consulted here until now.
      //
      // SECOND, RELATED BUG (found via the report-generator diff, once
      // that tool was finally trustworthy): rob_entry_ready alone is
      // REGISTERED state, one cycle behind a live broadcast. If a
      // producer's wakeup broadcasts on the EXACT SAME cycle a consumer
      // is being renamed, rob_entry_ready hasn't updated yet (it updates
      // on the NEXT edge) -- so this check would still miss it, exactly
      // like the case above but by one cycle instead of many. Fixed by
      // ALSO checking the live wb_valid_bus/wb_idx_bus broadcast this
      // same cycle, matching the "effective readiness = registered OR
      // live broadcast" pattern already used everywhere else (sched_reg.sv,
      // issue_queue.sv) -- this was the one place that pattern was missing.
      rn_src1_live_wake[i] = 1'b0;
      rn_src2_live_wake[i] = 1'b0;
      if (rn_src1_tag[i].is_rob)
        for (int w = 0; w < WB_PORTS; w++)
          if (wb_valid_bus[w] && (ROBIDX_W'(wb_idx_bus[w]) == ROBIDX_W'(rn_src1_tag[i].tag)))
            rn_src1_live_wake[i] = 1'b1;
      if (rn_src2_tag[i].is_rob)
        for (int w = 0; w < WB_PORTS; w++)
          if (wb_valid_bus[w] && (ROBIDX_W'(wb_idx_bus[w]) == ROBIDX_W'(rn_src2_tag[i].tag)))
            rn_src2_live_wake[i] = 1'b1;
      t.src1_ready = !rn_src1_tag[i].is_rob || rob_entry_ready[ROBIDX_W'(rn_src1_tag[i].tag)] || rn_src1_live_wake[i];
      t.src2_ready = !rn_src2_tag[i].is_rob || rob_entry_ready[ROBIDX_W'(rn_src2_tag[i].tag)] || rn_src2_live_wake[i];
      t.rob_idx    = TAG_W'(alloc_rob_idx[i]);
      rr_in_data[i] = t;
    end
  end

  sched_reg #(.WIDTH(WIDTH), .ROB_SIZE(ROB_SIZE)) u_rr (
    .clk(clk), .rst_n(rst_n), .flush(1'b0),
    .in_valid(rn_valid), .in_data(rr_in_data), .in_fire(rename_fire),
    .consume(regread_fire),
    .wb_valid(wb_valid_bus), .wb_idx(wb_idx_bus),
    .entry_gen(rob_entry_gen), .entry_valid(rob_entry_valid),
    .out_valid(rr_valid), .out_data(rr_data),
    .occupied(rr_occupied), .avail(rr_avail)
  );

  // ------------------------------------------------------------------
  // DI register (regread -> dispatch boundary). RegisterRead's whole
  // job is already done by RR's effective-ready output -- this is a
  // straight passthrough when both sides allow.
  // ------------------------------------------------------------------
  logic [WIDTH-1:0] di_valid;
  iflight_t         di_data[WIDTH];
  logic             di_occupied, di_avail, dispatch_fire;
  logic [$clog2(IQ_SIZE+1)-1:0] iq_free_entries;
  logic [$clog2(WIDTH+1)-1:0] di_valid_count;

  assign regread_fire = rr_occupied && di_avail;
  assign di_valid_count = $countones(di_valid);

  sched_reg #(.WIDTH(WIDTH), .ROB_SIZE(ROB_SIZE)) u_di (
    .clk(clk), .rst_n(rst_n), .flush(1'b0),
    .in_valid(rr_valid), .in_data(rr_data), .in_fire(regread_fire),
    .consume(dispatch_fire),
    .wb_valid(wb_valid_bus), .wb_idx(wb_idx_bus),
    .entry_gen(rob_entry_gen), .entry_valid(rob_entry_valid),
    .out_valid(di_valid), .out_data(di_data),
    .occupied(di_occupied), .avail(di_avail)
  );

  assign dispatch_fire = di_occupied && (iq_free_entries >= {1'b0, di_valid_count});

  // ------------------------------------------------------------------
  // Issue Queue (dispatch + issue) -- unpack di_data's per-lane fields
  // into the individual ports issue_queue.sv expects.
  // ------------------------------------------------------------------
  logic [SEQ_W-1:0]    di_seq_no_p[WIDTH];
  op_type_e            di_op_type_p[WIDTH];
  logic [ROBIDX_W-1:0] di_rob_idx_p[WIDTH];
  src_tag_t            di_src1_p[WIDTH], di_src2_p[WIDTH];
  logic [WIDTH-1:0]    di_src1_ready_p, di_src2_ready_p;

  always_comb begin
    for (int i = 0; i < WIDTH; i++) begin
      di_seq_no_p[i]   = di_data[i].seq_no;
      di_op_type_p[i]  = di_data[i].op_type;
      di_rob_idx_p[i]  = ROBIDX_W'(di_data[i].rob_idx);
      di_src1_p[i]     = di_data[i].src1;
      di_src2_p[i]     = di_data[i].src2;
      di_src1_ready_p[i] = di_data[i].src1_ready;
      di_src2_ready_p[i] = di_data[i].src2_ready;
    end
  end

  logic [WIDTH-1:0] sel_valid;
  logic [SEQ_W-1:0] sel_seq_no[WIDTH];
  op_type_e         sel_op_type[WIDTH];
  logic [ROBIDX_W-1:0] sel_rob_idx[WIDTH];

  issue_queue #(.WIDTH(WIDTH), .IQ_SIZE(IQ_SIZE), .ROB_SIZE(ROB_SIZE)) u_iq (
    .clk(clk), .rst_n(rst_n),
    .free_entries(iq_free_entries),
    .disp_fire(dispatch_fire),
    .disp_valid(di_valid),
    .disp_seq_no(di_seq_no_p), .disp_op_type(di_op_type_p), .disp_rob_idx(di_rob_idx_p),
    .disp_src1(di_src1_p), .disp_src2(di_src2_p),
    .disp_src1_ready(di_src1_ready_p), .disp_src2_ready(di_src2_ready_p),
    .wb_valid(wb_valid_bus), .wb_idx(wb_idx_bus),
    .entry_gen(rob_entry_gen), .entry_valid(rob_entry_valid),
    .sel_valid(sel_valid), .sel_seq_no(sel_seq_no),
    .sel_op_type(sel_op_type), .sel_rob_idx(sel_rob_idx)
  );

  // ------------------------------------------------------------------
  // Execute Units
  // ------------------------------------------------------------------
  logic [SEQ_W-1:0] wb_seq_no_bus[WB_PORTS];

  exec_units #(.WIDTH(WIDTH), .ROB_SIZE(ROB_SIZE)) u_exu (
    .clk(clk), .rst_n(rst_n),
    .iss_valid(sel_valid), .iss_seq_no(sel_seq_no),
    .iss_op_type(sel_op_type), .iss_rob_idx(sel_rob_idx),
    .wb_valid(wb_valid_bus), .wb_idx(wb_idx_bus), .wb_seq_no(wb_seq_no_bus)
  );

  // ------------------------------------------------------------------
  // ROB (allocation at rename, wakeup from writeback, in-order retire)
  // ------------------------------------------------------------------
  rob #(.WIDTH(WIDTH), .ROB_SIZE(ROB_SIZE)) u_rob (
    .clk(clk), .rst_n(rst_n),
    .free_entries(rob_free_entries),
    .alloc_rob_idx(alloc_rob_idx),
    .alloc_gen(alloc_gen),
    .entry_ready(rob_entry_ready),
    .entry_gen(rob_entry_gen),
    .entry_valid(rob_entry_valid),
    .alloc_fire(rename_fire),
    .alloc_valid(rn_valid),
    .alloc_dst_areg(rn_dst_areg_p), .alloc_dst_has(rn_dst_has_p),
    .alloc_pc(rn_pc_p), .alloc_seq_no(rn_seq_no_p),
    .wb_valid(wb_valid_bus), .wb_idx(wb_idx_bus),
    .retire_fire(1'b1), // always attempt retirement, matching the spec
    .rt_valid(rt_valid), .rt_dst_areg(rt_dst_areg), .rt_dst_has(rt_dst_has),
    .rt_pc(rt_pc), .rt_seq_no(rt_seq_no), .rt_rob_idx(rt_rob_idx),
    .rt_count(rt_count)
  );

  // Feed the ROB's retire outputs straight into the RMT's (now WIDTH-wide)
  // retire-clear port -- only meaningful for lanes that actually wrote a
  // destination register.
  always_comb begin
    for (int i = 0; i < WIDTH; i++) begin
      rmt_rt_valid[i]   = rt_valid[i] && rt_dst_has[i];
      rmt_rt_areg[i]    = rt_dst_areg[i];
      rmt_rt_rob_idx[i] = rt_rob_idx[i];
    end
  end

endmodule : ooo_pipeline

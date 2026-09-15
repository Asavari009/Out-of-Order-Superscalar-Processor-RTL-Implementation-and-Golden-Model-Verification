//=============================================================================
// sched_reg.sv -- wakeup-aware pipeline register (RR and DI stages only)
//
// Same producer/consumer handshake as pipe_reg.sv, but specialized for
// iflight_t payloads and augmented with same-cycle wakeup tracking.
//
// WHY THIS EXISTS (see docs/README.md for the full story): re-reading the
// spec's Execute() description closely, wakeup must reach THREE places on
// a producer's last cycle of execution -- the IQ, the DI register, and
// the RR register -- not just the IQ. If an instruction is stalled in DI
// or RR (e.g. the IQ is momentarily full) and its producer finishes
// during that stall, it must notice, or it could be dispatched into the
// IQ with permanently-stale "not ready" bits and deadlock forever
// (nothing would ever wake it after that point). A bare pipe_reg has no
// way to do this -- it just holds whatever was loaded until consumed.
//
// Two levels of readiness, same pattern as issue_queue.sv's eff_ready:
//   - REGISTERED readiness (src1_ready_q/src2_ready_q): latched on a
//     match, persists across stall cycles.
//   - EFFECTIVE readiness (what out_data actually reports): registered
//     bit OR a same-cycle match against the current wb_valid/wb_idx
//     broadcast. This is what lets a producer finishing in cycle N wake
//     a consumer that ALSO advances out of this register in cycle N --
//     required because the golden model's Execute() runs before
//     RegRead()/Dispatch() in its per-cycle call order, so a same-cycle
//     producer-to-RR/DI wakeup must already be visible when this
//     register's content is read that same cycle.
//=============================================================================
`include "ooo_pkg.sv"

module sched_reg
  import ooo_pkg::*;
#(
  parameter int WIDTH    = 4,
  parameter int ROB_SIZE = 32,
  parameter int WB_PORTS = WIDTH * MAX_LATENCY,
  localparam int ROBIDX_W = $clog2(ROB_SIZE)
)(
  input  logic clk,
  input  logic rst_n,
  input  logic flush,

  // ---- producer side ------------------------------------------------
  input  logic [WIDTH-1:0] in_valid,
  input  iflight_t         in_data [WIDTH],
  input  logic              in_fire,

  // ---- consumer side --------------------------------------------------
  input  logic              consume,

  // ---- same-cycle wakeup broadcast (from exec_units) -------------------
  input  logic [WB_PORTS-1:0] wb_valid,
  input  logic [ROBIDX_W-1:0] wb_idx[WB_PORTS],

  // ---- ROB generation query (staleness detection, see ooo_pkg.sv GEN_W) -
  input  logic [GEN_W-1:0]    entry_gen [ROB_SIZE],
  input  logic [ROB_SIZE-1:0] entry_valid,

  // ---- register contents (out_data's ready bits are EFFECTIVE, i.e.
  //      already include this-cycle wakeup -- see header comment) -------
  output logic [WIDTH-1:0] out_valid,
  output iflight_t         out_data [WIDTH],
  output logic              occupied,
  output logic              avail
);

  logic [WIDTH-1:0] valid_q;
  iflight_t         data_q [WIDTH];

  assign occupied = |valid_q;
  assign avail    = (!occupied) | consume;
  assign out_valid = valid_q;

  // ------------------------------------------------------------------
  // Same-cycle wakeup match, one comparison per lane per source
  // ------------------------------------------------------------------
  logic wk_match1[WIDTH];
  logic wk_match2[WIDTH];
  logic stale1[WIDTH];
  logic stale2[WIDTH];
  logic eff_ready1[WIDTH];
  logic eff_ready2[WIDTH];

  always_comb begin
    for (int i = 0; i < WIDTH; i++) begin
      wk_match1[i] = 1'b0;
      wk_match2[i] = 1'b0;
      for (int w = 0; w < WB_PORTS; w++) begin
        if (wb_valid[w] && data_q[i].src1.is_rob && (TAG_W'(wb_idx[w]) == data_q[i].src1.tag))
          wk_match1[i] = 1'b1;
        if (wb_valid[w] && data_q[i].src2.is_rob && (TAG_W'(wb_idx[w]) == data_q[i].src2.tag))
          wk_match2[i] = 1'b1;
      end
      // Staleness (see ooo_pkg.sv GEN_W / rob-tag-aliasing fix): if this
      // slot's live generation no longer matches what was captured at
      // rename time, OR the slot is currently invalid (retired but not
      // yet reallocated), the true producer already retired -- ready.
      stale1[i] = data_q[i].src1.is_rob && (!entry_valid[ROBIDX_W'(data_q[i].src1.tag)] || (entry_gen[ROBIDX_W'(data_q[i].src1.tag)] != data_q[i].src1.gen));
      stale2[i] = data_q[i].src2.is_rob && (!entry_valid[ROBIDX_W'(data_q[i].src2.tag)] || (entry_gen[ROBIDX_W'(data_q[i].src2.tag)] != data_q[i].src2.gen));
      eff_ready1[i] = data_q[i].src1_ready | wk_match1[i] | stale1[i];
      eff_ready2[i] = data_q[i].src2_ready | wk_match2[i] | stale2[i];
    end
  end

  // out_data reports EFFECTIVE readiness (registered OR this-cycle) --
  // built via a scalar temp per lane, whole-struct-assigned, per the
  // established pattern (avoids field-assignment-into-array-port issues
  // seen earlier in rmt.sv).
  always_comb begin
    iflight_t t;
    for (int i = 0; i < WIDTH; i++) begin
      t = data_q[i];
      t.src1_ready = eff_ready1[i];
      t.src2_ready = eff_ready2[i];
      out_data[i] = t;
    end
  end

  // ------------------------------------------------------------------
  // Sequential update
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || flush) begin
      valid_q <= '0;
    end else if (avail && in_fire) begin
      valid_q <= in_valid;
      data_q  <= in_data;
    end else if (consume) begin
      valid_q <= '0;
    end else if (occupied) begin
      // stalled: latch this cycle's wakeup into the registered bits so
      // future cycles see it without a live broadcast match
      for (int i = 0; i < WIDTH; i++) begin
        if (valid_q[i]) begin
          data_q[i].src1_ready <= eff_ready1[i];
          data_q[i].src2_ready <= eff_ready2[i];
        end
      end
    end
  end

endmodule : sched_reg

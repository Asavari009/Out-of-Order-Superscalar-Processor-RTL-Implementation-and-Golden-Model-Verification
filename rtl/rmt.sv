//=============================================================================
// rmt.sv -- Rename Map Table
//
// Mirrors Rename() in golden/sim_proc.cc:
//   - rename_map_table[areg] = {valid, tag=ROB index}
//   - A WIDTH-wide rename bundle is renamed "in program order" (spec 5.2):
//     if instruction i and instruction i+1..WIDTH-1 in the SAME bundle
//     share a register (WAR/WAW/RAW within the bundle), later instructions
//     must see the earlier instruction's fresh rename. The C++ model gets
//     this for free from its sequential for-loop; here it's explicit
//     intra-bundle forwarding logic.
//   - At retire, if rmt[areg].tag == retiring ROB index, invalidate the
//     entry (mirrors sim_proc.cc Retire(), the RMT-clear loop).
//   - Rename-write (this cycle) beats retire-clear (this cycle) on the same
//     architectural register: a fresh rename is always newer than a
//     retiring, older, instruction.
//=============================================================================
`include "ooo_pkg.sv"

module rmt
  import ooo_pkg::*;
#(
  parameter int WIDTH    = 4,
  parameter int ROB_SIZE = 32,
  localparam int ROBIDX_W = $clog2(ROB_SIZE)
)(
  input  logic clk,
  input  logic rst_n,

  // ---- Rename port: WIDTH-wide bundle, index 0 = oldest ----------------
  input  logic                    rn_fire,                 // commit this bundle
  input  logic [WIDTH-1:0]        rn_valid,                // packed: see ooo_pkg.sv port-style rule
  input  logic [ARCH_REG_W-1:0]   rn_src1_areg[WIDTH],
  input  logic [WIDTH-1:0]        rn_src1_has,             // packed
  input  logic [ARCH_REG_W-1:0]   rn_src2_areg[WIDTH],
  input  logic [WIDTH-1:0]        rn_src2_has,             // packed
  input  logic [ARCH_REG_W-1:0]   rn_dst_areg [WIDTH],
  input  logic [WIDTH-1:0]        rn_dst_has,              // packed
  input  logic [ROBIDX_W-1:0]     rn_rob_idx  [WIDTH],     // tail+i, from rob.sv
  input  logic [GEN_W-1:0]        rn_gen      [WIDTH],     // rob.alloc_gen[i], the generation this alloc carries

  output src_tag_t                rn_src1_tag [WIDTH],
  output src_tag_t                rn_src2_tag [WIDTH],

  // ---- Retire port: clear stale mapping, up to WIDTH/cycle --------------
  input  logic [WIDTH-1:0]        rt_valid,                // packed
  input  logic [ARCH_REG_W-1:0]   rt_areg     [WIDTH],
  input  logic [ROBIDX_W-1:0]     rt_rob_idx  [WIDTH]
);

  // architected mapping state
  logic                valid_q [NUM_ARCH_REGS];
  logic [ROBIDX_W-1:0] tag_q   [NUM_ARCH_REGS];
  logic [GEN_W-1:0]    gen_q   [NUM_ARCH_REGS]; // generation captured alongside each mapping

  // ------------------------------------------------------------------
  // Combinational lookahead: "shadow" copy of the RMT that reflects
  // the effect of dst writes from earlier instructions (index < i) in
  // THIS SAME bundle, so source lookups for instruction i see them.
  // shadow_valid/shadow_tag[i] = state of the RMT just before renaming
  // instruction i (i.e. after applying instructions 0..i-1 of this bundle).
  // ------------------------------------------------------------------
  logic                shadow_valid [WIDTH+1][NUM_ARCH_REGS];
  logic [ROBIDX_W-1:0] shadow_tag   [WIDTH+1][NUM_ARCH_REGS];
  logic [GEN_W-1:0]    shadow_gen   [WIDTH+1][NUM_ARCH_REGS];

  always_comb begin
    for (int r = 0; r < NUM_ARCH_REGS; r++) begin
      shadow_valid[0][r] = valid_q[r];
      shadow_tag[0][r]   = tag_q[r];
      shadow_gen[0][r]   = gen_q[r];
    end
    for (int i = 0; i < WIDTH; i++) begin
      for (int r = 0; r < NUM_ARCH_REGS; r++) begin
        shadow_valid[i+1][r] = shadow_valid[i][r];
        shadow_tag[i+1][r]   = shadow_tag[i][r];
        shadow_gen[i+1][r]   = shadow_gen[i][r];
      end
      if (rn_valid[i] && rn_dst_has[i]) begin
        shadow_valid[i+1][rn_dst_areg[i]] = 1'b1;
        shadow_tag[i+1][rn_dst_areg[i]]   = rn_rob_idx[i];
        shadow_gen[i+1][rn_dst_areg[i]]   = rn_gen[i];
      end
    end
  end

  // Source lookups for instruction i use shadow state BEFORE instruction i
  // (i.e. shadow_valid/tag[i], reflecting insns 0..i-1 of this bundle).
  //
  // NOTE: built via a scalar local `t` then assigned whole to the array
  // element in one shot -- Icarus Verilog (local smoke-test sim only)
  // doesn't support field-by-field assignment into an unpacked-array-of-
  // struct output port. This form is also just cleaner in any simulator.
  always_comb begin
    src_tag_t t;
    for (int i = 0; i < WIDTH; i++) begin
      if (rn_src1_has[i] && shadow_valid[i][rn_src1_areg[i]]) begin
        t.valid = 1'b1; t.is_rob = 1'b1; t.tag = shadow_tag[i][rn_src1_areg[i]]; t.gen = shadow_gen[i][rn_src1_areg[i]];
      end else if (rn_src1_has[i]) begin
        t.valid = 1'b1; t.is_rob = 1'b0; t.tag = rn_src1_areg[i]; t.gen = '0; // already-committed reg
      end else begin
        t.valid = 1'b0; t.is_rob = 1'b0; t.tag = '0; t.gen = '0;
      end
      rn_src1_tag[i] = t;

      if (rn_src2_has[i] && shadow_valid[i][rn_src2_areg[i]]) begin
        t.valid = 1'b1; t.is_rob = 1'b1; t.tag = shadow_tag[i][rn_src2_areg[i]]; t.gen = shadow_gen[i][rn_src2_areg[i]];
      end else if (rn_src2_has[i]) begin
        t.valid = 1'b1; t.is_rob = 1'b0; t.tag = rn_src2_areg[i]; t.gen = '0;
      end else begin
        t.valid = 1'b0; t.is_rob = 1'b0; t.tag = '0; t.gen = '0;
      end
      rn_src2_tag[i] = t;
    end
  end

  // ------------------------------------------------------------------
  // Sequential update: retire-clear, then rename-write (rename wins ties)
  // ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // Whole-array assignment pattern instead of a for-loop with
      // nonblocking assigns to array elements: functionally identical,
      // and Verilator (unlike Icarus) rejects the for-loop form here
      // ("delayed assignment to array inside for loops" is unsupported
      // in its synthesizable subset) -- this form works cleanly in both.
      valid_q <= '{default: 1'b0};
      tag_q   <= '{default: '0};
      gen_q   <= '{default: '0};
    end else begin
      // 1) retire-time invalidation, up to WIDTH entries this cycle. No
      //    interaction between lanes needed: rob_idx values are unique
      //    per instruction, so at most one lane's tag can ever match a
      //    given tag_q[areg] value, regardless of how many lanes target
      //    the same architectural register this cycle.
      for (int i = 0; i < WIDTH; i++) begin
        if (rt_valid[i] && valid_q[rt_areg[i]] && (tag_q[rt_areg[i]] == rt_rob_idx[i])) begin
          valid_q[rt_areg[i]] <= 1'b0;
        end
      end
      // 2) rename-time writes for this bundle, applied in program order so
      //    the last instruction in the bundle to touch a given dest reg wins
      //    (matches the shadow-chain semantics used for src lookups above)
      if (rn_fire) begin
        for (int i = 0; i < WIDTH; i++) begin
          if (rn_valid[i] && rn_dst_has[i]) begin
            valid_q[rn_dst_areg[i]] <= 1'b1;
            tag_q[rn_dst_areg[i]]   <= rn_rob_idx[i];
            gen_q[rn_dst_areg[i]]   <= rn_gen[i];
          end
        end
      end
    end
  end

endmodule : rmt

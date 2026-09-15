//=============================================================================
// ooo_pkg.sv
//
// Shared types/parameters for the 9-stage out-of-order pipeline RTL.
//
// Design decision (read this before touching anything else):
//   The golden C++ model (golden/sim_proc.cc) carries 9 pairs of
//   {begin_cycle,duration} timestamps INSIDE every in-flight instruction
//   struct, because that's the easiest way for a piece of software to later
//   print the per-instruction FE{}DE{}RN{}...RT{} report line.
//
//   That is not how you'd build real hardware: a pipeline register has no
//   business carrying nine cycle-stamped fields end to end. In this RTL,
//   pipeline registers only carry what scheduling logic actually needs
//   (tag, op type, src/dst tags+ready bits, rob index). ALL per-instruction
//   timing reconstruction (the FE{}...RT{} line) is done by the
//   verification environment, which snoops every pipeline-register load
//   with its `seq_no` and current cycle count, and reconstructs the exact
//   same report line the golden model prints -- for scoreboard comparison.
//   See verif/uvm/ooo_scoreboard.sv.
//=============================================================================
`ifndef OOO_PKG_SV
`define OOO_PKG_SV

package ooo_pkg;

  // ---------------------------------------------------------------------
  // Architectural constants (fixed by the spec, not parameterized)
  // ---------------------------------------------------------------------
  localparam int NUM_ARCH_REGS = 67;          // r0..r66
  localparam int ARCH_REG_W    = 7;           // ceil(log2(67)) = 7
  localparam int SEQ_W         = 32;          // dynamic instruction count width
  localparam int PC_W          = 64;          // trace PCs are hex, store wide

  // ---------------------------------------------------------------------
  // Operation type -> execution latency (Section 5.1 of spec)
  // ---------------------------------------------------------------------
  typedef enum logic [1:0] {
    OP_TYPE0 = 2'd0,   // latency 1
    OP_TYPE1 = 2'd1,   // latency 2
    OP_TYPE2 = 2'd2    // latency 5
  } op_type_e;

  function automatic int unsigned op_latency(op_type_e t);
    case (t)
      OP_TYPE0: return 1;
      OP_TYPE1: return 2;
      OP_TYPE2: return 5;
      default:  return 5; // unreachable, keep synthesis happy
    endcase
  endfunction

  localparam int MAX_LATENCY = 5;

  // Widest tag value that can ever need to be stored: either an
  // architectural register number (0..66, needs ARCH_REG_W=7 bits) or a
  // ROB index for the largest ROB_SIZE this design is validated against
  // (512, per the course's own val8.txt config -- needs $clog2(512)=9
  // bits). src_tag_t is a fixed-width PACKAGE type shared across every
  // module regardless of that module's own ROB_SIZE parameter, so its
  // tag field must be sized for the largest ROB_SIZE used ANYWHERE in
  // the design, not just whatever one instance happens to use -- widen
  // this if a larger ROB_SIZE is ever needed.
  localparam int TAG_W = 9;

  // Generation counter width for detecting stale ROB tags. THE BUG THIS
  // FIXES (found on a real 10,000-instr trace, not any hand-built test):
  // a bare ROB index is not a stable identifier across a long stall.
  // Consumer C renames while depending on producer P's ROB slot X.
  // If C then stalls (e.g. behind IQ backpressure) long enough for P to
  // finish AND retire AND slot X to be reallocated to an unrelated LATER
  // instruction Q, C's stored tag=X now refers to Q, not P -- C ends up
  // waiting on the wrong (or already-satisfied) dependency forever. This
  // is not a corner case: it reproduces reliably on ROB_SIZE=16 within
  // the first ~40 instructions of a real trace.
  //
  // Fix: every ROB slot carries a generation counter, incremented every
  // time that slot is (re)allocated. A tag now carries {gen, rob_idx}.
  // Any reader (issue_queue.sv, sched_reg.sv) compares its stored gen
  // against the SLOT'S CURRENT live generation: a mismatch can only mean
  // the slot has been reallocated since this tag was captured, which can
  // only happen after the true producer already retired -- so a mismatch
  // is treated as "ready" (the value is long since committed), not as
  // "still waiting". 32 bits means a single ROB slot would need over 4
  // billion reallocations while one specific consumer sits waiting for
  // the counter to wrap back around and coincidentally re-match a stale
  // tag -- effectively impossible for any realistic trace length. (An
  // earlier 8-bit version of this counter was NOT wide enough: it
  // wrapped and re-triggered the exact same bug after ~3900 instructions
  // on a real course trace, ROB_SIZE=16 -- confirmed by observing the
  // stall point coincide almost exactly with 256 reallocations per slot.
  // Lesson: the "astronomically unlikely" margin needs to be checked
  // against the actual per-slot reallocation RATE for realistic configs,
  // not just eyeballed.)
  localparam int GEN_W = 32;

  // ---------------------------------------------------------------------
  // A "tag" is either an architectural register that's already committed
  // (no rename needed) or a ROB index (renamed, value pending). We encode
  // "no source / no dest" (-1 in the trace) with a valid bit instead of a
  // sentinel value, which is the honest hardware way to do it.
  // ---------------------------------------------------------------------
  typedef struct packed {
    logic                    valid;     // 0 => "-1" in the trace (no reg)
    logic                    is_rob;    // 1 => tag is a ROB index (renamed,
                                         //      not-yet-ready); 0 => tag is
                                         //      an architectural reg # that
                                         //      was already free (ready now)
    logic [TAG_W-1:0]        tag;       // ROB index OR architectural reg #
    logic [GEN_W-1:0]        gen;       // ROB slot generation at capture time
                                         // (only meaningful when is_rob=1);
                                         // see GEN_W comment above for why.
  } src_tag_t;

  // ---------------------------------------------------------------------
  // Instruction as it flows through the scheduling pipeline (DE..IQ..EX).
  // This is the packed struct that actually lives in pipeline registers.
  // ---------------------------------------------------------------------
  typedef struct packed {
    logic                  valid;
    logic [SEQ_W-1:0]      seq_no;      // == dynamic instruction count (PC
                                         // field in the golden model's output
                                         // is actually this sequence number,
                                         // not the hex trace PC -- see
                                         // sim_proc.cc line ~229 and the
                                         // Retire() print. We match that.)
    logic [PC_W-1:0]       pc;          // original hex PC, kept for the report
    op_type_e              op_type;
    logic                  dst_valid;
    logic [ARCH_REG_W-1:0] dst_areg;    // architectural dest reg # (pre-rename)
    src_tag_t              src1;
    src_tag_t              src2;
    logic                  src1_ready;
    logic                  src2_ready;
    logic [TAG_W-1:0]      rob_idx;     // filled in by rename; sized for max
                                         // supported ROB_SIZE (see rob.sv)
  } iflight_t;

  // NOTE: a packed-struct "bubble" constant is deliberately not defined
  // here -- Icarus Verilog (used for local smoke tests) is picky about
  // localparam struct assignment patterns. Modules that need a bubble
  // value just zero-initialize (`= '0`), which is equivalent since
  // valid/dst_valid/src*.valid all sit at bit 0 of their fields.

  // ---------------------------------------------------------------------
  // HARD PORT-STYLE RULE (found the expensive way -- see docs/README.md
  // "Known issues" for the full story): single-bit unpacked-array ports,
  // i.e. `input logic foo[N]` where each element is 1 bit, do not
  // reliably trigger always_comb re-evaluation in either open-source
  // simulator we tested when an element's value changes after
  // elaboration -- confirmed via a minimal, tool-independent
  // reproduction, not just an artifact of one module. Any per-lane
  // BOOLEAN signal (valid, has, ready, fire flags) MUST be a packed
  // vector (`logic [N-1:0] foo`, indexed the same way with foo[i]) instead of an unpacked array of
  // 1-bit elements. Multi-bit per-lane DATA (tags, indices, seq_no,
  // op_type) is unaffected by this bug and stays as unpacked arrays
  // (`logic [W-1:0] foo[N]`) as originally designed.

  // ---------------------------------------------------------------------
  // Decoded instruction: raw trace fields, pre-rename. Lives in the DE
  // and RN pipeline registers (the boundary before and after the Decode
  // stage). Decode is a pure identity passthrough in this design -- the
  // trace format is already structured fields, there's no real
  // bit-encoding to split apart -- but it's still a genuine one-cycle
  // pipeline hop, matching the real per-instruction report format's
  // separate DE{} and RN{} timestamps.
  // ---------------------------------------------------------------------
  typedef struct packed {
    logic [SEQ_W-1:0]      seq_no;
    logic [PC_W-1:0]       pc;
    op_type_e              op_type;
    logic                  dst_has;
    logic [ARCH_REG_W-1:0] dst_areg;
    logic                  src1_has;
    logic [ARCH_REG_W-1:0] src1_areg;
    logic                  src2_has;
    logic [ARCH_REG_W-1:0] src2_areg;
  } decoded_instr_t;

endpackage : ooo_pkg

`endif

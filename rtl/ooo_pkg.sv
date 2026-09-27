//=============================================================================
// ooo_pkg.sv
//
// Shared types/parameters for the 9-stage out-of-order pipeline RTL.
//=============================================================================
`ifndef OOO_PKG_SV
`define OOO_PKG_SV

package ooo_pkg;

  // ---------------------------------------------------------------------
  // Architectural constants 
  // ---------------------------------------------------------------------
  localparam int NUM_ARCH_REGS = 67;          // r0..r66
  localparam int ARCH_REG_W    = 7;           // ceil(log2(67)) = 7
  localparam int SEQ_W         = 32;          // dynamic instruction count width
  localparam int PC_W          = 64;          // trace PCs are hex, store wide

  // ---------------------------------------------------------------------
  // Operation type -> execution latency
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
      default:  return 5; // unreachable
    endcase
  endfunction

  localparam int MAX_LATENCY = 5;

  localparam int TAG_W = 9;

  localparam int GEN_W = 32;

  typedef struct packed {
    logic                    valid;     // 0 => "-1" in the trace (no reg)
    logic                    is_rob;    // 1 => tag is a ROB index (renamed,
                                         //      not-yet-ready); 0 => tag is
                                         //      an architectural reg # that
                                         //      was already free (ready now)
    logic [TAG_W-1:0]        tag;       // ROB index OR architectural reg #
    logic [GEN_W-1:0]        gen;       // ROB slot generation at capture time
                                         // (only meaningful when is_rob=1);
                                         
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
                                         // not the hex trace PC 
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

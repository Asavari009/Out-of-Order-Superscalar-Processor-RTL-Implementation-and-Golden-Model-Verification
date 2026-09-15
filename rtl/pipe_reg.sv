//=============================================================================
// pipe_reg.sv -- generic WIDTH-wide pipeline bundle register
//
// Represents ONE pipeline register between two stages (e.g. DE, RN, DI).
// Mirrors the "all-or-nothing" advance rule used throughout the spec's
// Section 5.2 guide: a stage only pushes its WHOLE bundle into the next
// register if that register is empty (or being emptied this same cycle
// by its own downstream consumer) -- never a partial push.
//
// Two independent handshake signals, matching pipe_reg's two jobs:
//   in_fire  -- the PRODUCER (upstream) is pushing a new bundle in. Only
//               takes effect if this register can currently accept it
//               (see `avail` below) -- if not, the request is silently
//               ignored, so the caller must check `avail`/`occupied`
//               before asserting in_fire, exactly like a ready/valid bus.
//   consume  -- the CONSUMER (downstream) is taking the current bundle
//               out this cycle. This is what frees the register up,
//               possibly for immediate same-cycle refill by in_fire (the
//               same "vacate-and-refill in one edge" pattern already
//               used in issue_queue.sv and exec_units.sv).
//
// This module is deliberately generic over the payload type via
// `parameter type T` -- one well-tested module instantiated 6 times (for
// DE/RN/RR/DI/WB/RT) beats 6 bespoke ones, per the original project plan.
//=============================================================================
`include "ooo_pkg.sv"

module pipe_reg
  import ooo_pkg::*;
#(
  parameter int  WIDTH = 4,
  parameter type T     = logic [31:0]
)(
  input  logic clk,
  input  logic rst_n,
  input  logic flush,               // synchronous clear (e.g. branch misprediction; unused today but free to wire up later)

  // ---- producer side ------------------------------------------------
  input  logic [WIDTH-1:0] in_valid,
  input  T                 in_data [WIDTH],
  input  logic              in_fire, // "push in_valid/in_data now" -- only takes effect if avail

  // ---- consumer side --------------------------------------------------
  input  logic              consume, // "I'm taking the current contents this cycle"

  // ---- register contents (combinational read of current state) --------
  output logic [WIDTH-1:0] out_valid,
  output T                 out_data [WIDTH],
  output logic              occupied, // register currently holds an unconsumed bundle
  output logic              avail     // can accept a new push THIS cycle (empty, or being vacated by `consume` this same cycle)
);

  logic [WIDTH-1:0] valid_q;
  T                 data_q [WIDTH];

  assign out_valid = valid_q;
  assign out_data  = data_q;
  assign occupied  = |valid_q;
  assign avail     = (!occupied) | consume;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || flush) begin
      valid_q <= '0;
    end else if (avail && in_fire) begin
      // either the register was already empty, or `consume` is vacating
      // it this same edge -- either way, load the new bundle
      valid_q <= in_valid;
      data_q  <= in_data;
    end else if (consume) begin
      // consumed, and nothing new arrived to replace it
      valid_q <= '0;
    end
    // else: hold current contents (stalled)
  end

endmodule : pipe_reg

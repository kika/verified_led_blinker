// Exhaustive simulation of the Yosys models (techlibs/xilinx/cells_sim.v) of
// the primitives in lean/VeryFPGA/Prims.lean. Prints one line per input
// vector; test/PrimsTest.lean recomputes each line with the Lean definitions.
`timescale 1ns / 1ps
module prims_tb;
  integer v;

  // CARRY4: all 2^10 combinations of CI, CYINIT, DI[3:0], S[3:0].
  reg ci, cyinit;
  reg [3:0] di, s;
  wire [3:0] o, co;
  CARRY4 u_carry4 (.CO(co), .O(o), .CI(ci), .CYINIT(cyinit), .DI(di), .S(s));

  // INV, IBUF, OBUF, BUFG: both input values.
  reg a;
  wire inv_o, ibuf_o, obuf_o, bufg_o;
  INV  u_inv  (.O(inv_o),  .I(a));
  IBUF u_ibuf (.O(ibuf_o), .I(a));
  OBUF u_obuf (.O(obuf_o), .I(a));
  BUFG u_bufg (.O(bufg_o), .I(a));

  // FDRE: all 2^4 combinations of current Q, R, CE, D, one rising edge each.
  reg c, ce, d, r;
  wire q;
  FDRE #(.INIT(1'b0)) u_fdre (.Q(q), .C(c), .CE(ce), .D(d), .R(r));
  reg q0;

  initial begin
    for (v = 0; v < 1024; v = v + 1) begin
      {ci, cyinit, di, s} = v[9:0];
      #1;
      $display("CARRY4 %b %b %b %b %b %b", ci, cyinit, di, s, o, co);
    end
    for (v = 0; v < 2; v = v + 1) begin
      a = v[0];
      #1;
      $display("BUF %b %b %b %b %b", a, inv_o, ibuf_o, obuf_o, bufg_o);
    end
    c = 0;
    for (v = 0; v < 16; v = v + 1) begin
      // Load the wanted current Q, then apply R, CE, D and clock once.
      {r, ce, d} = 3'b010; d = v[3];
      #1 c = 1; #1 c = 0;
      q0 = q;
      {r, ce, d} = v[2:0];
      #1 c = 1; #1 c = 0;
      #1;
      $display("FDRE %b %b %b %b %b", q0, r, ce, d, q);
    end
    $finish(0);
  end
endmodule

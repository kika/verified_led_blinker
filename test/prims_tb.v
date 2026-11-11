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

  // LUT6: four fixed INIT values, all 64 input combinations each.
  // INIT_D is ALUT.INIT of tile CLBLL_L_X2Y47 in build/blinky.fasm.
  localparam [63:0] INIT_A = 64'h0123456789ABCDEF;
  localparam [63:0] INIT_B = 64'hF0E1D2C3B4A59687;
  localparam [63:0] INIT_C = 64'h8000000000000001;
  localparam [63:0] INIT_D = 64'hF0F0F0F0FFFF0000;
  reg [5:0] li;
  wire lo_a, lo_b, lo_c, lo_d;
  LUT6 #(.INIT(INIT_A)) u_lut_a (.O(lo_a), .I0(li[0]), .I1(li[1]), .I2(li[2]), .I3(li[3]), .I4(li[4]), .I5(li[5]));
  LUT6 #(.INIT(INIT_B)) u_lut_b (.O(lo_b), .I0(li[0]), .I1(li[1]), .I2(li[2]), .I3(li[3]), .I4(li[4]), .I5(li[5]));
  LUT6 #(.INIT(INIT_C)) u_lut_c (.O(lo_c), .I0(li[0]), .I1(li[1]), .I2(li[2]), .I3(li[3]), .I4(li[4]), .I5(li[5]));
  LUT6 #(.INIT(INIT_D)) u_lut_d (.O(lo_d), .I0(li[0]), .I1(li[1]), .I2(li[2]), .I3(li[3]), .I4(li[4]), .I5(li[5]));

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
    for (v = 0; v < 64; v = v + 1) begin
      li = v[5:0];
      #1;
      $display("LUT6 %b %b %b", INIT_A, li, lo_a);
      $display("LUT6 %b %b %b", INIT_B, li, lo_b);
      $display("LUT6 %b %b %b", INIT_C, li, lo_c);
      $display("LUT6 %b %b %b", INIT_D, li, lo_d);
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

/-
Semantics of the Xilinx 7-series primitives that appear in the blinky netlist.

Reference: AMD UG953 (7 Series FPGA Libraries Guide). Cross-checked against
Yosys `techlibs/xilinx/cells_sim.v` (oss-cad-suite 2026-11-04) and tested
exhaustively against an Icarus Verilog simulation of that file
(`lean/test/`, run by `make test-prims`).

This file is part of the trusted base: if a definition here is wrong, the
final theorem is about the wrong circuit.
-/
namespace VeryFPGA.Prims

/-- `INV`: `O = !I`. -/
def inv (i : Bool) : Bool := !i

/-- `IBUF`, `OBUF`, `BUFG`: `O = I`. Electrically these are pad drivers and a
clock-network driver; logically they pass the value through. -/
def buf (i : Bool) : Bool := i

/-- Entries at even positions 0, 2, 4, ... of a list. -/
def evens {α : Type} : List α → List α
  | a :: _ :: t => a :: evens t
  | [a] => [a]
  | [] => []

/-- Entries at odd positions 1, 3, 5, ... of a list. -/
def odds {α : Type} : List α → List α
  | _ :: b :: t => b :: odds t
  | _ => []

/-- A look-up table. `init` is the truth table, entry 0 first; `ins` are the
inputs `[A1, A2, ...]`. The output is entry number
`A1 + 2*A2 + 4*A3 + ...` (A1 least significant, as in UG953's `LUT6` with
`I0` = A1). Written as a Shannon expansion on A1: if A1 is 1 the entry
number is odd, so only the odd entries remain, indexed by the other
inputs; if 0, the even ones. Used for `LUT1`..`LUT6` and for the `O6`
(six inputs, 64 entries) and `O5` (five inputs, the lower 32 entries)
outputs of a 7-series slice LUT. -/
def lut : List Bool → List Bool → Bool
  | init, [] => init.headD false
  | init, a :: rest => if a then lut (odds init) rest else lut (evens init) rest

/-- `FDRE`: D flip-flop with clock enable and synchronous reset, rising edge.
This is the value `Q` takes at the next clock edge, given the current inputs
and the current `Q`. Only the default parameter values are modelled
(`IS_C_INVERTED = IS_D_INVERTED = IS_R_INVERTED = 0`); the parser rejects any
netlist that sets them. The power-up value is the `INIT` parameter. -/
def fdreNext (r ce d q : Bool) : Bool :=
  if r then false else if ce then d else q

/-- The eight outputs of a `CARRY4`. -/
structure Carry4Out where
  o0 : Bool
  o1 : Bool
  o2 : Bool
  o3 : Bool
  co0 : Bool
  co1 : Bool
  co2 : Bool
  co3 : Bool

/-- `CARRY4`: four stages of the slice carry chain.
The carry into stage 0 is `CI || CYINIT`. Each stage `i` outputs the sum bit
`O[i] = S[i] xor c_i` and the carry `CO[i] = if S[i] then c_i else DI[i]`
(a multiplexer: propagate the incoming carry, or generate `DI[i]`).

`let` names an intermediate value, as in a functional language; `^^` is
Boolean xor. -/
def carry4 (ci cyinit d0 d1 d2 d3 s0 s1 s2 s3 : Bool) : Carry4Out :=
  let c0 := ci || cyinit
  let c1 := if s0 then c0 else d0
  let c2 := if s1 then c1 else d1
  let c3 := if s2 then c2 else d2
  let c4 := if s3 then c3 else d3
  { o0 := s0 ^^ c0, o1 := s1 ^^ c1, o2 := s2 ^^ c2, o3 := s3 ^^ c3,
    co0 := c1, co1 := c2, co2 := c3, co3 := c4 }

end VeryFPGA.Prims

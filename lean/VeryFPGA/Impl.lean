/-
The meaning of a `Netlist` as a synchronous machine.

State: one `Bool` per `FDRE`, in the order the flops appear in the netlist.
Each clock cycle every flop loads the value its input logic computes from the
current state. The output is the value on the `led` port.

How the input logic is computed: starting from a flop's `D` (and `CE`, `R`)
net, follow each net back to the one cell that drives it, until reaching a
flop output or a constant. The result is an expression (`Sig`) over flop
outputs; evaluating it with the primitive functions from `Prims` gives the
next value.

`compile` returns `none`, so that no theorem about the netlist can be proved,
when any of these holds:
- a net that the logic reads is undriven or driven by more than one cell;
- the logic contains a combinational loop (tracing runs out of steps);
- the logic reads the clock network or an input pad;
- the clock structure is not: `clk` port -> one IBUF -> one BUFG -> the `C`
  pin of every flop.

Trusted: these definitions, with `Prims`, say what the netlist means.
-/
import VeryFPGA.Prims
import VeryFPGA.Netlist

namespace VeryFPGA

/-- Which of the eight `CARRY4` outputs. -/
inductive CarryPin where
  | o0 | o1 | o2 | o3 | co0 | co1 | co2 | co3
  deriving Repr, Lean.ToExpr

def CarryPin.get : CarryPin → Prims.Carry4Out → Bool
  | .o0, r => r.o0
  | .o1, r => r.o1
  | .o2, r => r.o2
  | .o3, r => r.o3
  | .co0, r => r.co0
  | .co1, r => r.co1
  | .co2, r => r.co2
  | .co3, r => r.co3

/-- A combinational signal as an expression over flop outputs. -/
inductive Sig where
  | const (b : Bool)
  /-- The current output `Q` of flop number `k`. -/
  | flop (k : Nat)
  | inv (a : Sig)
  | carry4 (pin : CarryPin) (ci cyinit d0 d1 d2 d3 s0 s1 s2 s3 : Sig)
  /-- The next value of a flop, from its `R`, `CE`, `D` inputs and current `Q`. -/
  | fdre (r ce d q : Sig)
  /-- A six-input LUT (`init` has 64 entries), inputs A1..A6. Used for the
  `O6` output of a slice LUT (M4). -/
  | lut6 (init : List Bool) (a1 a2 a3 a4 a5 a6 : Sig)
  /-- A five-input LUT (`init` has 32 entries), inputs A1..A5. Used for the
  `O5` output of a slice LUT, which reads the lower half of its INIT (M4). -/
  | lut5 (init : List Bool) (a1 a2 a3 a4 a5 : Sig)
  deriving Repr, Inhabited, Lean.ToExpr

/-- The value of a signal in state `st`. `List.getD st k false` is element
`k` of `st`, or `false` past the end; past the end cannot occur, because
`trace` only produces `flop k` for an existing flop `k`. -/
def Sig.eval (st : List Bool) : Sig → Bool
  | .const b => b
  | .flop k => st.getD k false
  | .inv a => Prims.inv (a.eval st)
  | .carry4 pin ci cyinit d0 d1 d2 d3 s0 s1 s2 s3 =>
    pin.get (Prims.carry4 (ci.eval st) (cyinit.eval st) (d0.eval st) (d1.eval st)
      (d2.eval st) (d3.eval st) (s0.eval st) (s1.eval st) (s2.eval st) (s3.eval st))
  | .fdre r ce d q => Prims.fdreNext (r.eval st) (ce.eval st) (d.eval st) (q.eval st)
  | .lut6 init a1 a2 a3 a4 a5 a6 =>
    Prims.lut init [a1.eval st, a2.eval st, a3.eval st, a4.eval st, a5.eval st, a6.eval st]
  | .lut5 init a1 a2 a3 a4 a5 =>
    Prims.lut init [a1.eval st, a2.eval st, a3.eval st, a4.eval st, a5.eval st]

/-- A signal with no flop leaves: its value does not depend on the state. -/
def Sig.closed : Sig → Bool
  | .const _ => true
  | .flop _ => false
  | .inv a => a.closed
  | .carry4 _ ci cyinit d0 d1 d2 d3 s0 s1 s2 s3 =>
    ci.closed && cyinit.closed && d0.closed && d1.closed && d2.closed && d3.closed &&
      s0.closed && s1.closed && s2.closed && s3.closed
  | .fdre r ce d q => r.closed && ce.closed && d.closed && q.closed
  | .lut6 _ a1 a2 a3 a4 a5 a6 =>
    a1.closed && a2.closed && a3.closed && a4.closed && a5.closed && a6.closed
  | .lut5 _ a1 a2 a3 a4 a5 => a1.closed && a2.closed && a3.closed && a4.closed && a5.closed

/-- What drives a net: a cell output, with the cell's inputs. -/
inductive Driver where
  | flopQ (k : Nat)
  | invO (i : Bit)
  | carry (pin : CarryPin) (ci cyinit : Bit) (di s : Bits4)
  | ibufO (i : Bit)
  | obufO (i : Bit)
  | bufgO (i : Bit)

/-- Every cell output with its driver. Flops are numbered from `k` in list order. -/
def outputs : List Cell → Nat → List (Bit × Driver)
  | [], _ => []
  | .fdre _ _ _ _ _ q :: cs, k => (q, .flopQ k) :: outputs cs (k + 1)
  | .carry4 ci cy di s o co :: cs, k =>
    [(o.b0, .carry .o0 ci cy di s), (o.b1, .carry .o1 ci cy di s),
     (o.b2, .carry .o2 ci cy di s), (o.b3, .carry .o3 ci cy di s),
     (co.b0, .carry .co0 ci cy di s), (co.b1, .carry .co1 ci cy di s),
     (co.b2, .carry .co2 ci cy di s), (co.b3, .carry .co3 ci cy di s)] ++ outputs cs k
  | .inv i o :: cs, k => (o, .invO i) :: outputs cs k
  | .ibuf i o :: cs, k => (o, .ibufO i) :: outputs cs k
  | .obuf i o :: cs, k => (o, .obufO i) :: outputs cs k
  | .bufg i o :: cs, k => (o, .bufgO i) :: outputs cs k

/-- All cells driving net `n` (a well-formed net has exactly one). -/
def driversOf (nl : Netlist) (n : Nat) : List Driver :=
  (outputs nl.cells 0).filterMap fun (b, d) => if b == .net n then some d else none

/-- Follow `b` back to flop outputs and constants. `fuel` bounds the number of
cells passed through; running out means a combinational loop. Inside the
`Option` `do` block, `← x` stops with `none` as soon as `x` is `none`. -/
def trace (nl : Netlist) : Nat → Bit → Option Sig
  | _, .const b => some (.const b)
  | 0, .net _ => none
  | fuel + 1, .net n =>
    match driversOf nl n with
    | [.flopQ k] => some (.flop k)
    | [.invO i] => do return .inv (← trace nl fuel i)
    | [.carry pin ci cy di s] => do
      return .carry4 pin (← trace nl fuel ci) (← trace nl fuel cy)
        (← trace nl fuel di.b0) (← trace nl fuel di.b1) (← trace nl fuel di.b2)
        (← trace nl fuel di.b3) (← trace nl fuel s.b0) (← trace nl fuel s.b1)
        (← trace nl fuel s.b2) (← trace nl fuel s.b3)
    | [.obufO i] => trace nl fuel i
    | _ => none

/-- The pins of one flop. -/
structure Flop where
  init : Bool
  c : Bit
  ce : Bit
  d : Bit
  r : Bit
  q : Bit

def flops (nl : Netlist) : List Flop :=
  nl.cells.filterMap fun
    | .fdre init c ce d r q => some { init, c, ce, d, r, q }
    | _ => none

/-- The net of the single design clock: the output of the only BUFG, whose
input is driven only by an IBUF from the `clk` port, which no cell drives. -/
def designClock (nl : Netlist) : Option Nat :=
  let bufgs : List (Bit × Bit) := nl.cells.filterMap fun
    | .bufg i o => some (i, o)
    | _ => none
  match bufgs, driversOf nl nl.clk with
  | [(.net bi, .net bo)], [] =>
    match driversOf nl bi with
    | [.ibufO (.net p)] => if p == nl.clk then some bo else none
    | _ => none
  | _, _ => none

/-- A netlist compiled to a machine: initial state, next-state expression of
each flop, and the output expression. -/
structure Machine where
  init : List Bool
  next : List Sig
  out : Sig
  deriving Repr, Inhabited, Lean.ToExpr

def compile (nl : Netlist) : Option Machine := do
  let fuel := nl.cells.length + 1
  let clk ← designClock nl
  let fs := flops nl
  -- `guard c` fails (gives `none`) unless `c` holds.
  guard (fs.all (·.c == .net clk))
  let next ← fs.mapM fun f => do
    return .fdre (← trace nl fuel f.r) (← trace nl fuel f.ce) (← trace nl fuel f.d)
      (← trace nl fuel f.q)
  let out ← trace nl fuel (.net nl.led)
  return { init := fs.map (·.init), next, out }

def Machine.step (m : Machine) (st : List Bool) : List Bool :=
  m.next.map (·.eval st)

/-- Flop values after `n` clock cycles. -/
def Machine.run (m : Machine) : Nat → List Bool
  | 0 => m.init
  | n + 1 => m.step (m.run n)

/-- Level of the `led` pin during cycle `n`. -/
def Machine.ledAt (m : Machine) (n : Nat) : Bool :=
  m.out.eval (m.run n)

/-- Level of the `led` pin of netlist `nl` during cycle `n`; `none` if the
netlist is not well formed in the sense of `compile`. -/
def Impl.ledAt (nl : Netlist) (n : Nat) : Option Bool :=
  (compile nl).map (·.ledAt n)

end VeryFPGA

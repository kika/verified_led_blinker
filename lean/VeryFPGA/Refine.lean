/-
Refinement: the netlist Yosys produced behaves like the specification.

Top-level theorems at the end of this file:
- `netlist_refines_spec`: at every cycle, the netlist's `led` pin equals the
  specification's LED.
- `netlist_blinks`: at cycle `n` the `led` pin is high exactly when
  `n mod 2^27 ≥ 2^26`.

Proof outline:
1. Compute the netlist's machine once, as a literal (`machine`), and let the
   kernel check that it really is `compile netlist`.
2. Relate machine states to specification states: `conc s` is the flop
   vector that holds counter value `s`.
3. Three lemmas: initial states match, one step matches, outputs match.
   The step lemma is checked by `bv_decide` (SAT).
4. Induction over cycles.
-/
import VeryFPGA.Blinky
import VeryFPGA.Impl
import VeryFPGA.Spec
import VeryFPGA.DefByEval

namespace VeryFPGA

/-! ### 1. The machine as a literal -/

-- The netlist's machine, computed while this file is compiled.
-- `def_by_eval` also adds `machine.eq_def_by_eval`, checked by the kernel.
def_by_eval machine : Machine := (compile netlist).getD default

/-- The netlist is well formed (`compile` succeeds) and its machine is
`machine`. `rfl` asks the kernel to evaluate `compile netlist` and compare.
This is where undriven nets, loops and clocking errors would be caught. -/
theorem compile_netlist : compile netlist = some machine := by rfl

/-! ### 2. The abstraction -/

/-- For each flop, its bit position in the Yosys net named `cnt`.
This only steers the proof; if it were wrong the proof would fail. -/
def flopBits (nl : Netlist) : List Nat :=
  match nl.names.lookup "cnt" with
  | some bus => (flops nl).map fun f => bus.idxOf f.q
  | none => []

def_by_eval bitOf : List Nat := flopBits netlist

/-- The flop vector that holds counter value `s`: flop `k` holds bit
`bitOf[k]` of `s`. `BitVec.getLsbD s i` is bit `i` of `s` (bit 0 least
significant).

The circuit lemmas below use the literal width 27 because `bv_decide` needs
literal widths. `Spec.State` is `BitVec Spec.N` with `Spec.N = 27`, so the
two types are equal by definition and Lean accepts one for the other. -/
def conc (s : BitVec 27) : List Bool := bitOf.map s.getLsbD

/-! ### 3. The three lemmas -/

/-- At power-up every flop holds its `INIT`, and that is counter value 0.
`decide` evaluates both sides (two concrete lists of 27 booleans). -/
theorem init_ok : machine.init = conc 0 := by decide

/-- One clock cycle of the netlist adds 1 to the counter.

`simp only [...]` rewrites with exactly the listed definitions: it unfolds
`machine` to its literal, evaluates every next-state expression (`Sig.eval`)
into a Boolean formula over the bits of `s` using the primitive definitions
from `Prims`, and splits the list equality into 27 Boolean equalities.
`bv_decide` then proves the remaining statement for all 2^27 values of `s`
with a SAT solver, whose certificate Lean checks. -/
theorem step_ok (s : BitVec 27) : machine.step (conc s) = conc (s + 1) := by
  simp only [machine, bitOf, conc, Machine.step, List.map, Sig.eval, CarryPin.get,
    Prims.carry4, Prims.fdreNext, Prims.inv, List.getD_cons_zero, List.getD_cons_succ,
    List.cons.injEq, and_true]
  bv_decide

/-- The `led` pin shows the counter's top bit. -/
theorem out_ok (s : BitVec 27) : machine.out.eval (conc s) = s.msb := by
  simp only [machine, bitOf, conc, List.map, Sig.eval, List.getD_cons_zero,
    List.getD_cons_succ]
  bv_decide

/-! ### 4. Induction over cycles -/

/-- After `n` cycles the netlist's flops hold the specification's state. -/
theorem run_ok (n : Nat) : machine.run n = conc (Spec.run n) := by
  induction n with
  | zero => exact init_ok
  | succ n ih =>
    -- `machine.run (n+1)` is by definition `machine.step (machine.run n)`,
    -- and `Spec.run (n+1)` is by definition `Spec.step (Spec.run n)`.
    show machine.step (machine.run n) = conc (Spec.step (Spec.run n))
    rw [ih]
    -- `exact` accepts `step_ok` at width 27 for a goal stated at width `Spec.N`,
    -- since the two are equal by definition.
    exact step_ok (Spec.run n)

/-! ### Top-level theorems -/

/-- **Refinement.** At every clock cycle `n`, the `led` pin of the netlist
Yosys produced has the value the specification gives. -/
theorem netlist_refines_spec (n : Nat) :
    Impl.ledAt netlist n = some (Spec.led (Spec.run n)) := by
  -- `Impl.ledAt netlist n` is `(compile netlist).map (·.ledAt n)`.
  rw [Impl.ledAt, compile_netlist, Option.map_some, Machine.ledAt, run_ok]
  exact congrArg some (out_ok (Spec.run n))

/-- **Blinky.** The `led` pin of the netlist is high at cycle `n` exactly
when `n mod 2^27 ≥ 2^26`: a square wave with period 2^27 cycles and 50 %
duty. LED0 is active high (`board/FACTS.md`), so pin high means LED lit. -/
theorem netlist_blinks (n : Nat) :
    Impl.ledAt netlist n = some true ↔ n % 2 ^ Spec.N ≥ 2 ^ (Spec.N - 1) := by
  -- `Option.some.injEq : (some a = some b) = (a = b)`.
  rw [netlist_refines_spec, Option.some.injEq]
  exact Spec.led_run n

end VeryFPGA

/-
Refinement for the routed design (M4a.4): the configuration nextpnr
produced (FASM), decoded through the X-Ray database and the site models,
behaves like the specification.

Top-level theorems at the end of this file:
- `phys_refines_spec`: at every cycle, the LED pad of the routed design has
  the specification's LED value.
- `phys_blinks`: the clock pad is G11, the LED pad is E11, and at cycle `n`
  the LED pad is high exactly when `n mod 2^27 ≥ 2^26`.

Same structure as `Refine.lean` (M3): the machine as a kernel-checked
literal (`physMachine`, `BlinkyPhys.lean`), an abstraction to counter
values, three lemmas, induction.
-/
import VeryFPGA.BlinkyPhys
import VeryFPGA.Spec

namespace VeryFPGA

/-! ### The abstraction -/

/-- Row of slice `i` in its carry chain: 0 if its carry-in is not `CIN`,
else one more than the row of the slice whose `COUT` drives its `CIN`.
`fuel` bounds the chain length. -/
def chainRow (d : Phys.PhysDesign) : Nat → Nat → Nat
  | 0, _ => 0
  | f + 1, i =>
    match d.sites[i]? with
    | some s =>
      if s.has "PRECYINIT.CIN" then
        match s.input "CIN" with
        | .pin j "COUT" => chainRow d f j + 1
        | _ => 0
      else 0
    | none => 0

/-- For each flip-flop of a routed design, its counter bit, guessed from its
place in the carry chain: four bits per slice row (A..D). This only steers
the proof; if it were wrong the proof would fail. -/
def chainBits (d : Phys.PhysDesign) : List Nat :=
  (Phys.flops d).map fun (i, n) => 4 * chainRow d d.sites.length i + n

def_by_eval physBitOf : List Nat := chainBits blinkyPhys

/-- The flip-flop values that hold counter value `s`. -/
def physConc (s : BitVec 27) : List Bool := physBitOf.map s.getLsbD

/-! ### The three lemmas -/

/-- At power-up every flip-flop holds its `INIT`, and that is counter value 0. -/
theorem phys_init_ok : physMachine.init = physConc 0 := by decide

/-- One clock cycle of the routed design adds 1 to the counter.

`simp only` unfolds the machine literal, every next-state expression
(`Sig.eval`), the primitive definitions including the LUT truth tables
(`Prims.lut` splits on one input at a time, `evens`/`odds` pick the
remaining table entries), and splits the list equality into 27 Boolean
equalities. `bv_decide` proves the result for all 2^27 values of `s`. -/
theorem phys_step_ok (s : BitVec 27) : physMachine.step (physConc s) = physConc (s + 1) := by
  simp only [physMachine, physBitOf, physConc, Machine.step, List.map, Sig.eval, CarryPin.get,
    Prims.carry4, Prims.fdreNext, Prims.lut, Prims.evens, Prims.odds, List.headD,
    List.getD_cons_zero, List.getD_cons_succ, List.cons.injEq, and_true]
  bv_decide

/-- The LED pad shows the counter's top bit. -/
theorem phys_out_ok (s : BitVec 27) : physMachine.out.eval (physConc s) = s.msb := by
  simp only [physMachine, physBitOf, physConc, List.map, Sig.eval,
    List.getD_cons_zero, List.getD_cons_succ]
  bv_decide

/-! ### Induction over cycles -/

theorem phys_run_ok (n : Nat) : physMachine.run n = physConc (Spec.run n) := by
  induction n with
  | zero => exact phys_init_ok
  | succ n ih =>
    show physMachine.step (physMachine.run n) = physConc (Spec.step (Spec.run n))
    rw [ih]
    exact phys_step_ok (Spec.run n)

/-! ### Top-level theorems -/

/-- **Refinement, routed design.** At every clock cycle `n`, the LED pad of
the design nextpnr produced (as decoded from its FASM) has the value the
specification gives. -/
theorem phys_refines_spec (n : Nat) :
    Phys.ledAt blinkyPhys n = some (Spec.led (Spec.run n)) := by
  rw [Phys.ledAt, physCompile_blinky, Option.map_some, Machine.ledAt, phys_run_ok]
  exact congrArg some (phys_out_ok (Spec.run n))

/-- **Blinky, routed design.** The clock enters at package pin G11, the LED
pad is package pin E11, and the LED pad is high at cycle `n` exactly when
`n mod 2^27 ≥ 2^26`. LED0 is active high (`board/FACTS.md`). -/
theorem phys_blinks :
    Phys.clockPad blinkyPhys = some "G11" ∧ Phys.ledPad blinkyPhys = some "E11" ∧
    ∀ n, Phys.ledAt blinkyPhys n = some true ↔ n % 2 ^ Spec.N ≥ 2 ^ (Spec.N - 1) := by
  refine ⟨blinky_pads.1, blinky_pads.2, fun n => ?_⟩
  rw [phys_refines_spec, Option.some.injEq]
  exact Spec.led_run n

end VeryFPGA

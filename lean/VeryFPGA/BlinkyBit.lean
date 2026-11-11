/-
The bitstream itself (M4b): `build/blinky.bit` decoded into X-Ray features
at build time (`load_bit`, `Bitstream.lean`), then the same routing, site
grouping and site models as for the FASM.

The kernel checks that the machine obtained from the bitstream is the very
machine `physMachine` proved correct in `PhysRefine.lean`; so the routed
design's theorem holds for the bitstream, with no second SAT proof.
-/
import VeryFPGA.Bitstream
import VeryFPGA.PhysRefine

namespace VeryFPGA

load_bit blinkyBit from "../build/blinky.bit" xray "spartan7" "xc7s50" "xc7s50ftgb196-1"

route_fasm blinkyBitRouting from blinkyBit xray "spartan7" "xc7s50"

load_phys blinkyBitPhys from blinkyBit blinkyBitRouting xray "spartan7" "xc7s50" "xc7s50ftgb196-1"

/-- The bitstream's machine is `physMachine`. `rfl` asks the kernel to
evaluate `physCompile` on the design decoded from the bits. -/
theorem physCompile_bit : Phys.physCompile blinkyBitPhys = some physMachine := by rfl

/-- **Refinement, bitstream.** At every clock cycle `n`, the LED pad of the
FPGA configured with `build/blinky.bit` has the value the specification
gives. -/
theorem bit_refines_spec (n : Nat) :
    Phys.ledAt blinkyBitPhys n = some (Spec.led (Spec.run n)) := by
  -- `Phys.ledAt d n` is `(physCompile d).map (·.ledAt n)`; both designs
  -- compile to `physMachine`, so the routed design's theorem applies.
  have h := phys_refines_spec n
  rw [Phys.ledAt, physCompile_blinky] at h
  rw [Phys.ledAt, physCompile_bit]
  exact h

/-- **Blinky, bitstream.** In the FPGA configured with `build/blinky.bit`,
the clock enters at package pin G11, the LED pad is package pin E11, and the
LED pad is high at cycle `n` exactly when `n mod 2^27 ≥ 2^26`. LED0 is
active high (`board/FACTS.md`). -/
theorem bit_blinks :
    Phys.clockPad blinkyBitPhys = some "G11" ∧ Phys.ledPad blinkyBitPhys = some "E11" ∧
    ∀ n, Phys.ledAt blinkyBitPhys n = some true ↔ n % 2 ^ Spec.N ≥ 2 ^ (Spec.N - 1) := by
  refine ⟨by decide, by decide, fun n => ?_⟩
  rw [bit_refines_spec, Option.some.injEq]
  exact Spec.led_run n

end VeryFPGA

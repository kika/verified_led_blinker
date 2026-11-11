/-
The routed blinky design as a machine (M4a.3): sites grouped from the FASM
and routing at build time (`load_phys`), interpreted by `physCompile`
(`PhysImpl.lean`). `physMachine` is computed at build time and the kernel
checks that it is what `physCompile` gives.
-/
import VeryFPGA.PhysImpl
import VeryFPGA.BlinkyRoute
import VeryFPGA.DefByEval

namespace VeryFPGA

load_phys blinkyPhys from blinkyFasm blinkyRouting xray "spartan7" "xc7s50" "xc7s50ftgb196-1"

-- The design's machine, computed while this file is compiled.
def_by_eval physMachine : Machine := (Phys.physCompile blinkyPhys).getD default

/-- The routed design is accepted by the model (every feature known, clock
structure as required, LED pad driving) and its machine is `physMachine`.
`rfl` asks the kernel to evaluate `physCompile`. -/
theorem physCompile_blinky : Phys.physCompile blinkyPhys = some physMachine := by rfl

/-- The clock enters at package pin G11 and the LED pad is package pin E11.
`decide` evaluates both sides. -/
theorem blinky_pads :
    Phys.clockPad blinkyPhys = some "G11" ∧ Phys.ledPad blinkyPhys = some "E11" := by
  decide

end VeryFPGA

/-
Specification of blinky: what "the LED blinks" means, with no hardware detail.

The state is an N-bit counter that starts at 0 and adds 1 every clock cycle.
The LED shows the counter's most significant bit.

Polarity: LED0 on the Astria board is active high (FPGA pin -> 110 ohm ->
LED -> GND, see board/FACTS.md), so `led s = true` means the pin is driven
high and the LED is lit. No inversion is hidden here.
-/
namespace VeryFPGA.Spec

/-- Counter width. At 100 MHz the period is 2^27 cycles = 1.342 s. -/
def N : Nat := 27

/-- `BitVec N` is Lean's built-in fixed-width bit vector. Its `+` wraps
modulo `2^N`, exactly like an N-bit hardware adder. -/
abbrev State := BitVec N

def init : State := 0

def step (s : State) : State := s + 1

/-- `BitVec.msb` is the most significant bit, as a `Bool`. -/
def led (s : State) : Bool := s.msb

/-- The state after `n` clock cycles: `step` applied `n` times to `init`.
Written as structural recursion on `n` (the pattern `n + 1` matches every
`n` except 0) so that each equation holds by definition. -/
def run : Nat → State
  | 0     => init
  | n + 1 => step (run n)

/-- After `n` cycles the counter holds `n` reduced modulo `2^N`.

`BitVec.ofNat N n` is the N-bit vector whose value is `n % 2^N`.

The proof is by `induction n`: Lean asks for the case `n = 0` and, assuming
the statement for `n` (named `ih`, the induction hypothesis), the case
`n + 1`. -/
theorem run_eq_ofNat (n : Nat) : run n = BitVec.ofNat N n := by
  induction n with
  | zero =>
    -- `run 0` unfolds to `init`, which is `0`; `BitVec.ofNat N 0` is also
    -- `0`. Both sides compute to the same value, so `rfl` (reflexivity:
    -- "these are equal by evaluation") closes the goal.
    rfl
  | succ n ih =>
    -- `show` restates the goal in a form that is equal by definition, here
    -- unfolding `run (n + 1)` to `run n + 1`.
    show run n + 1 = BitVec.ofNat N (n + 1)
    -- `rw [h]` rewrites the goal using the equation `h`, left to right.
    -- `ih : run n = BitVec.ofNat N n`.
    -- `BitVec.ofNat_add : BitVec.ofNat w (x + y) = BitVec.ofNat w x + BitVec.ofNat w y`.
    rw [ih, BitVec.ofNat_add]
    -- Left: `BitVec.ofNat N n + 1`; right: `BitVec.ofNat N n + BitVec.ofNat N 1`.
    -- The literal `1 : BitVec N` is by definition `BitVec.ofNat N 1`.
    rfl

/-- **The blinking theorem.** At clock cycle `n` the LED is on exactly when
`n mod 2^N ≥ 2^(N-1)`: off for the first half of every `2^N`-cycle period
and on for the second half. That is a square wave with period `2^N` cycles
and 50 % duty. -/
theorem led_run (n : Nat) : led (run n) = true ↔ n % 2 ^ N ≥ 2 ^ (N - 1) := by
  -- Unfold `led`, replace `run n` by `BitVec.ofNat N n`, then use:
  -- `BitVec.msb_eq_decide : x.msb = decide (2 ^ (w - 1) ≤ x.toNat)`
  --   (the top bit is set iff the value is at least half the range), and
  -- `BitVec.toNat_ofNat : (BitVec.ofNat w x).toNat = x % 2 ^ w`.
  rw [led, run_eq_ofNat, BitVec.msb_eq_decide, BitVec.toNat_ofNat]
  -- Goal: `decide (2 ^ (N - 1) ≤ n % 2 ^ N) = true ↔ n % 2 ^ N ≥ 2 ^ (N - 1)`.
  -- `decide p` turns a decidable proposition into a `Bool`;
  -- `decide_eq_true_iff : decide p = true ↔ p`. `a ≥ b` is by definition
  -- `b ≤ a`, so this closes the goal.
  exact decide_eq_true_iff

end VeryFPGA.Spec

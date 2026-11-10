# Trust ledger

Status: **M2**. The specification is proved about itself. Nothing connects it
to the hardware yet; that is M3.

## What is proved

`lean/VeryFPGA/Spec.lean`, Lean v4.35.0:

```lean
theorem VeryFPGA.Spec.led_run (n : Nat) :
    led (run n) = true ↔ n % 2 ^ N ≥ 2 ^ (N - 1)
```

with `N = 27`, `run 0 = 0`, `run (n+1) = run n + 1` on `BitVec 27`, and
`led s = s.msb`.

In words: an abstract 27-bit counter that starts at 0 and adds 1 per step has
its top bit set at step `n` exactly when `n mod 2^27 ≥ 2^26`. That is a square
wave with period 2^27 steps and 50 % duty. `led = true` stands for the pin
driven high, which lights LED0 (active high, `board/FACTS.md`).

## What it does not say

- Nothing about the netlist, the bitstream or the board. The Verilog, Yosys
  output and `.bit` are not referenced by any theorem yet.
- Nothing about wall-clock time. One step stands for one clock cycle; that the
  clock is 100 MHz is a board fact, not a theorem.

## Assumed, not proved

- Lean's kernel and the core library definitions of `BitVec`, `Nat`, `msb`.

## `#print axioms`

```
'VeryFPGA.Spec.led_run' depends on axioms: [propext, Quot.sound]
```

Both are standard axioms of Lean's logic. No `sorry`, no project axioms, no
`native_decide`.

## Negative check

The same proof script fails on two false variants: threshold `2^(N-2)`, and
inverted polarity (`<` instead of `≥`).

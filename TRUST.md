# Trust ledger

Status: **M3 (MVP complete)**, 2026-11-10.

## What is proved

`lean/VeryFPGA/Refine.lean`, Lean v4.35.0:

```lean
theorem VeryFPGA.netlist_refines_spec (n : Nat) :
    Impl.ledAt netlist n = some (Spec.led (Spec.run n))

theorem VeryFPGA.netlist_blinks (n : Nat) :
    Impl.ledAt netlist n = some true ↔ n % 2 ^ Spec.N ≥ 2 ^ (Spec.N - 1)
```

`netlist` is the Yosys netlist `build/blinky.json`, parsed into Lean data.
`Impl.ledAt netlist n` is the level of its `led` port during clock cycle
`n`, given by the meaning of each primitive (`Prims.lean`) and of a
synchronous netlist (`Impl.lean`). It is `none` if the netlist is malformed:
an undriven or multiply driven net in the logic, a combinational loop, logic
reading the clock network, or any flop not clocked by `clk` -> IBUF -> BUFG.
`Spec.N = 27`.

In words: **in the netlist Yosys produced, the `led` port is high during
cycle `n` exactly when `n mod 2^27 ≥ 2^26`**: a square wave with a period of
2^27 cycles and 50 % duty, starting low at power-up. LED0 is active high, so
port high means the LED is lit (`board/FACTS.md`). `netlist_refines_spec`
says the same through the specification of M2: cycle by cycle, the netlist's
output equals that of an abstract 27-bit counter's top bit.

Last proof run (`build/PROOF.txt`, `make proof`):

| Artifact | SHA-256 |
|---|---|
| `build/blinky.json` | `ee5d1dbceac4c1b8489e32fe7993674612edd7eb14695bdcf9786a94acec570c` |
| `build/blinky.bit` | `d484258181108ae15c316e1af4bf5fc771c98e0c4d3fa738aba35d310fe87df9` |

The `.bit` is the one loaded on the board and seen blinking in M1.
`lean/lakefile.toml` declares the JSON as an input of the Lean library, so a
changed netlist forces the proof to re-run (tested: a one-byte change rebuilds
`Blinky` and `Refine`; an unchanged file rebuilds nothing).

## What it does not say

- **Nothing below the netlist.** Packing, placement, routing, FASM, frames,
  `.bit` and JTAG loading are not covered. The `.bit` hash above records which
  bitstream was built from the proved netlist; nothing proves that the
  bitstream implements it. That is M4.
- **Nothing about time in seconds.** One step is one rising edge of `clk`.
  That the clock is 100 MHz (so the period is 1.342 s) is a board fact.
- **Nothing about electrical behaviour**: drive strength, IO standard, pin
  location. Those are in `board/astria.xdc` and are not part of the theorem.
- **Nothing about other ports.** The parser accepts only a netlist whose
  ports are exactly `clk` (input) and `led` (output).

## Assumed, not proved

Ordered from closest to the theorem to furthest.

1. **Primitive semantics** (`lean/VeryFPGA/Prims.lean`): `INV`, `IBUF`,
   `OBUF`, `BUFG`, `FDRE`, `CARRY4`. Reference: AMD UG953. Cross-checked by
   reading Yosys `cells_sim.v`, and tested on every input against an Icarus
   Verilog simulation of it (`make test-prims`: 1024 CARRY4, 2 INV/buffer,
   16 FDRE vectors, all match). Agreement with Yosys's model is evidence, not
   proof, that the definitions match the silicon.
2. **Netlist semantics** (`lean/VeryFPGA/Impl.lean`): a synchronous machine
   whose state is the FDRE outputs, updated together on every clock edge;
   combinational cells evaluated by tracing each flop input back to flop
   outputs and constants.
3. **The JSON parser** (`lean/VeryFPGA/Netlist.lean`) and its build-time
   loading (`load_netlist`), which reads the file, parses it with Lean's
   `Lean.Json.parse` and the project parser, and turns the result into a Lean
   term. Its specific choices:
   - accepts only the six cell types above, with exactly their port names,
     directions and widths; FDRE accepts only the `INIT` parameter (1-bit
     string), other cells no parameters; `x`/`z` bits and outputs tied to
     constants are rejected;
   - ignores `attributes` (`src`, `keep`, `module_not_derived`) and every
     module except the single one marked `top`;
   - rejects a wire with an `init` attribute;
   - a duplicate key inside one JSON object would be merged silently by
     `Lean.Json.parse` (Yosys does not write duplicate keys);
   - the bit order of multi-bit parameters (MSB first) is **not exercised**:
     the only parameter in this netlist is a 1-bit FDRE `INIT`. It needs a
     test when LUTs appear.
4. **The clock pin receives a clean 100 MHz clock**, and every flop sees each
   edge once.
5. **Timing is met.** nextpnr reports 391 MHz achievable against 100 MHz
   required; that report is not checked.
6. **Flops power up at their `INIT` values** when configuration completes.
7. **Everything downstream of the Yosys netlist**: pack, place, route, FASM
   generation, `fasm2frames`, `xc7frames2bit`, openFPGALoader, the X-Ray
   database, and the configuration logic of the FPGA.
8. **Lean**: the kernel; and, because `bv_decide` checks its SAT certificate
   with compiled code and the parser runs as compiled/interpreted code at
   build time, also **Lean's compiler, its runtime and the C compiler** that
   built the Lean toolchain.

Not trusted, because the kernel re-checks its output: `def_by_eval`
(`lean/VeryFPGA/DefByEval.lean`), which computes `compile netlist` at build
time; the kernel checks `compile netlist = some machine` by evaluation.

## Embedding choice

**Deep embedding.** The netlist is Lean data; its meaning is a Lean function
over that data; the proof evaluates that function on the literal netlist.
Trust lifted from the tools is the parser and the semantics, as listed above.
Cost: the semantics (`Impl.lean`) must be read and believed, and the build
runs the parser as compiled code. No generator emits Lean source.

## `#print axioms`

```
'VeryFPGA.netlist_blinks' depends on axioms: [propext, Classical.choice, Quot.sound, step_ok._native.bv_decide.ax_1_27]
'VeryFPGA.netlist_refines_spec' depends on axioms: [propext,
 Classical.choice,
 Quot.sound,
 step_ok._native.bv_decide.ax_1_27]
```

`propext`, `Classical.choice`, `Quot.sound` are Lean's standard axioms.
`step_ok._native.bv_decide.ax_1_27` is generated by `bv_decide` in the step
lemma `step_ok`. It states

```
Std.Tactic.BVDecide.Reflect.verifyBVExpr step_ok._expr_def_1_23 step_ok._cert_def_1_23 = true
```

that is: Lean's LRAT certificate checker, run as compiled code, accepted the
SAT solver's certificate for the step formula. This is the compiler trust of
item 8, in the form this Lean version records it (older versions showed
`Lean.ofReduceBool`). No `sorry`, no hand-written axiom, no `native_decide`.

## Mutation test

`make mutation` runs the unchanged `Refine.lean` against copies of the JSON:

| Copy | Change | Result |
|---|---|---|
| control | none | proof accepted |
| cyinit | first `CARRY4`: `CYINIT` 0 -> 1 | rejected at `step_ok` (SAT counterexample) |
| swap_d | `D` inputs of two FDREs swapped | rejected at `step_ok` (SAT counterexample) |
| flop_init | one FDRE `INIT` 0 -> 1 | rejected at `init_ok` |

The `CYINIT` and `INIT` mutations replace the planned "flip one bit of a LUT
`INIT`": this netlist has no LUTs.

## M2 result, still part of the chain

`Spec.led_run (n) : led (run n) = true ↔ n % 2^N ≥ 2^(N-1)`, axioms
`[propext, Quot.sound]`. The same script fails on a wrong threshold and on
inverted polarity.

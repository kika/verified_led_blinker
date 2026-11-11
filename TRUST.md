# Trust ledger

Status: **M3 (MVP complete)**, 2026-11-10. M4 in progress (see the M4
section at the end); nothing from M4 is part of any theorem yet.

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

## M4 in progress

**M4a.1 (2026-11-11): FASM parsed and checked against X-Ray.** Not yet part
of any theorem. New code that will become trusted once M4a.4 proves a
theorem about the decoded design:

- `lean/VeryFPGA/Fasm.lean`: FASM parser. Accepts only `TILE.FEATURE` and
  `TILE.FEATURE[hi:lo] = W'b...`; rejects other number bases, single-bit
  indexing, annotations and trailing comments.
- `lean/VeryFPGA/XRay.lean`: reads `tilegrid.json`, `segbits_*.db` and
  `ppips_*.db` (prjxray-db `a8b09269`, family `spartan7`, die `xc7s50`) and
  classifies every feature as bit-backed, `always` pseudo-PIP or `default`
  pseudo-PIP; follows the `*_SING` tile alias as prjxray's
  `tile_segbits_alias.py` does. Rejects unknown features, `hint` pseudo-PIPs
  and duplicate lines (tested on six broken copies).
- The X-Ray database itself. Lake does not track it; its revision is pinned
  in `TOOLS.md`. `PRJXRAY_DB_DIR` must be set (by `env.sh`) to build.

Result on `build/blinky.fasm`: all 503 features found (`make fasm-check`).

**M4a.2 (2026-11-11): physical wiring reconstructed.** Not yet part of any
theorem. `lean/VeryFPGA/Route.lean` (run at build time by `route_fasm` in
`BlinkyRoute.lean`) computes, for every input pin of every site in the
FASM's tiles, the site output pin that drives it. Trusted once M4a.4 uses
it; it rests on these readings of the X-Ray database, which are
interpretations and should be confirmed against the bitstream in M4b:

- Nodes are the closure of the `tileconn.json` joins, as in prjxray's
  `node_model.py`. Site pin directions come from `site_type_*.json`.
- A wire's driver is the enabled bit-backed PIPs and `always` pseudo-PIPs
  into it; if none, its `default` pseudo-PIP. `default` is read as "the
  connection a multiplexer makes when none of its PIPs is on", and `always`
  as a permanent connection, whether or not the FASM lists them.
- **Route-through rule:** a pseudo-PIP from an input-pin wire to an
  output-pin wire of the *same* site (e.g. BUFHCE `I` -> `O`) describes the
  path through that site, not routing. The site's output pin is taken as the
  driver, and the site's configuration is left to the site models (M4a.3).
  Without this rule the BUFHCE output node would have two drivers.
- Site input pins with no tile wire in X-Ray (`null`, e.g. `REV`) are
  recorded as unwired, not treated as driven.

Hard errors (each tested by a faulty FASM copy, `make route-check`): a node
with more than one driver; a FASM PIP on no traced path (a removed middle
hop, a stray PIP); a FASM `default` pseudo-PIP on a wire that has another
driver; a routing loop.

Result on `build/blinky.fasm`: 831 site inputs traced (702 driven, 129
undriven, all on unused sites), 23 unwired. The clock enters at G11
(`IOB_X0Y26`, the master pad of tile `LIOB33_X0Y25`), not at the
RP2040-driven F11 in the same tile, and reaches every slice `CLK` through
`ILOGICE3 -> BUFGCTRL -> BUFHCE`. The LED pad is driven from `SLICEL.CQ` of
tile `CLBLL_L_X2Y47` (counter bit 26) through `OLOGICE3.D1 -> OQ`.

Open for M4a.3: the pads of F11 (`IOB33S`) and others have their `O` and `T`
pins wired to output logic. That they do not drive is a property of their
(absent) configuration, which the site models must check.

**M4a.3 (2026-11-11): site models.** Not yet part of any theorem.
`lean/VeryFPGA/Phys.lean` groups the FASM features by site and attaches the
routing (build time, `load_phys`); `lean/VeryFPGA/PhysImpl.lean` defines
`physCompile : PhysDesign → Option Machine`, the meaning of the configured
sites. `physCompile blinkyPhys = some physMachine` is checked by the kernel
(`BlinkyPhys.lean`), as are `clockPad = some "G11"` and `ledPad = some "E11"`.
The new trusted content, with where each meaning comes from:

| Item | Meaning used | Source |
|---|---|---|
| LUT `INIT` | output = entry `A1 + 2*A2 + ... + 32*A6`; `O6` all 64 entries, `O5` the lower 32 with A1..A5 | UG953 LUT6 convention, UG474 for `O5`/`O6`; `Prims.lut` matches Yosys `LUT6` on 256 vectors. That the FASM `INIT[i]` is the LUT6 `INIT[i]` is prjxray's convention, not documented |
| `?FF.ZINI` | set: power-up value 0 | prjxray 011-clb-ffconfig |
| `?FF.ZRST`, `FFSYNC` | set: synchronous reset to 0 | 011-clb-ffconfig |
| `CEUSEDMUX`, `SRUSEDMUX` | absent: CE = 1, never reset | 011, 014-clb-ffsrcemux |
| `PRECYINIT.*` | carry-in from `CIN`, `AX`, 1; none set: 0 (the `C0` bit pattern is all zeros) | 017-clb-precyinit, `segbits_clbll_l.db` |
| `CARRY4.?CY0` | set: `DI` = `O5`, else the bypass pin | 013-clb-ncy0 |
| `?FFMUX.XOR`, `?FFMUX.O6` | flip-flop `D` from the carry sum / LUT `O6` | 015-clb-nffmux (names only) and UG474 |
| CARRY4 `S` = LUT `O6`; slice outputs `A`..`D` = `O6`; `?Q` = flip-flop | | UG474 |
| `NOCLKINV` | required on slices with used flip-flops (rising edge) | 011 (as `CLKINV`); conservative |
| `ZINV_X` | set means input `X` not inverted | feature names; consistent with the working board (BUFGCTRL `CE0` and OLOGIC `T1` both tied to 1) |
| OLOGIC `OMUX.D1` + `OQUSED` | `OQ = D1` | feature names only |
| OLOGIC `DATA_RATE_TQ.BUF` | `TQ = T1` (inverted unless `ZINV_T1`) | feature names only |
| LED pad | level = `O` input; tristate `T` must be the constant 0 | UG471 |
| BUFHCE, BUFGCTRL, ILOGICE3, IDELAYE2 | checked as pass-through, not modelled | decision of 2026-11-10 |
| IO electrical settings, clock tile enables | allow-lists | decision of 2026-11-10 |
| IOBs with no features (e.g. F11) | do not drive their pad | assumption: unconfigured IOB output buffers are off |

Tests: the decoded machine powers up at 0, counts 0..4999 from power-up,
and on 2000 random states one step adds 1 with the LED output equal to bit
26 (`make phys-check`, simulation). Five configuration changes are each
refused for the intended reason: an unmodelled output selector, a
falling-edge clock, 4 mA LED drive, the LED tristate no longer 0, and a
clock buffer that no longer passes its input.

# Trust ledger

Status: **M4b complete** (bitstream proved), 2026-11-11.

Three top-level results, about three artifacts of the same build:

| Theorem | About | File |
|---|---|---|
| `bit_blinks` | the bitstream loaded on the board (`build/blinky.bit`) | `lean/VeryFPGA/BlinkyBit.lean` |
| `phys_blinks` | the routed design nextpnr produced (`build/blinky.fasm`) | `lean/VeryFPGA/PhysRefine.lean` |
| `netlist_blinks` | the Yosys netlist (`build/blinky.json`) | `lean/VeryFPGA/Refine.lean` |

`bit_blinks` is the strongest: it covers packing, placement, routing, FASM
generation and frame assembly. It is obtained from `phys_blinks` by a kernel
check that the bitstream decodes to the identical machine (see section 0).
`netlist_blinks` stands on its own, against the same specification (M2).

Last proof run (`build/PROOF.txt`, `make proof`):

| Artifact | SHA-256 |
|---|---|
| `build/blinky.json` | `ee5d1dbceac4c1b8489e32fe7993674612edd7eb14695bdcf9786a94acec570c` |
| `build/blinky.fasm` | `0b4bbc76aa6e29d98a2ec81e4e43a948b001735fe4baf7c6502f619c013b874a` |
| `build/blinky.bit` | `d484258181108ae15c316e1af4bf5fc771c98e0c4d3fa738aba35d310fe87df9` |

The `.bit` is the one loaded on the board and seen blinking in M1.
`lean/lakefile.toml` declares the JSON, the FASM and the `.bit` as inputs of
the Lean library, so a changed file forces the proofs to re-run.

## 0. The bitstream (M4b)

```lean
theorem VeryFPGA.bit_blinks :
    Phys.clockPad blinkyBitPhys = some "G11" ∧ Phys.ledPad blinkyBitPhys = some "E11" ∧
    ∀ n, Phys.ledAt blinkyBitPhys n = some true ↔ n % 2 ^ Spec.N ≥ 2 ^ (Spec.N - 1)

theorem VeryFPGA.bit_refines_spec (n : Nat) :
    Phys.ledAt blinkyBitPhys n = some (Spec.led (Spec.run n))
```

`blinkyBitPhys` is `build/blinky.bit` decoded at build time
(`Bitstream.lean`, `load_bit`) into X-Ray features, then wired
(`Route.lean`) and grouped by site (`Phys.lean`) exactly as the FASM was.
The kernel checks `physCompile blinkyBitPhys = some physMachine`
(`physCompile_bit`, by `rfl`): the machine of the bitstream is the very
machine proved correct for the routed design, so the routed design's
theorem carries over without a second SAT proof.

In words: **in the FPGA configured with `build/blinky.bit`, the clock
enters at package pin G11, and the pad at package pin E11 is high during
cycle `n` exactly when `n mod 2^27 ≥ 2^26`**, under the assumptions below.

### What it does not say

- Nothing about JTAG loading: that openFPGALoader delivers this file intact
  is assumed (the device checks no CRC here: this bitstream writes none).
- Nothing about the configuration registers beyond what the reader checks
  (`IDCODE`, `FAR`, the write command, one frame data write): `COR0`,
  `COR1`, `CTL0`, `CTL1`, `MASK`, `TIMER`, `WBSTAR` and the startup commands
  are recorded (`make bit-check`) but not interpreted.
- Time in seconds, electrical behaviour beyond the IO allow-list, and other
  pads (assumed not to drive when unconfigured) as in section 1.

### Assumed, not proved

1. **The bitstream reader** (`lean/VeryFPGA/Bitstream.lean`): header part
   name; packets per AMD UG470 (only writes, only to the registers listed
   above; `IDCODE` = `0x362f093` from `part.json`; `FAR` = 0 and WCFG
   before the single `FDRI` write); frame addresses in the auto-increment
   order of `part.json` (block type, half, row, column, minor, two padding
   frames per row; padding and block RAM frames must be zero); bits 12..0
   of word 50 of each frame are the frame ECC and not configuration (no
   X-Ray feature uses them; checked); features decoded with prjxray's
   exact-match rule (`tile_segbits.py`), emitting only features with at
   least one positive bit; every set bit must be explained.
   The frame address order was cross-checked against `fasm2frames`: all
   4970 non-zero frames land at the same addresses with the same contents,
   apart from the ECC field.
2. **Everything in section 1 except the FASM parser**: the site models,
   the routing interpretation, the site grouping, the X-Ray database (now
   also `segbits_*.db` bit positions and `part.json`), the physical
   assumptions (clean clock, timing, power-up values), and Lean (kernel,
   compiler, C compiler).
3. **The configuration logic of the FPGA** loads the frames as UG470
   describes, and the ECC field does not affect the configured function.

Model changes made for M4b (both apply to section 1 as well):
- `NOCLKINV` is no longer required; the rising-edge condition is "`CLKINV`
  absent". A decoded bitstream never contains `NOCLKINV`: its only bit is a
  cleared one.
- Sites that drive an input of a configured site are included in the
  design even without features (e.g. the IDELAY on the clock path, whose
  only FASM feature `IDELAY_TYPE_FIXED` sets no bits), and a pad with no
  features is accepted as unconfigured (assumed not to drive, as before).

### `#print axioms`

```
'VeryFPGA.bit_blinks' depends on axioms: [propext, Classical.choice, Quot.sound, phys_step_ok._native.bv_decide.ax_1_38]
```

No axiom beyond those of `phys_blinks`.

### Tests (`make bit-check`)

The decode of `build/blinky.bit`: 1338 configuration bits set, all
explained by 281 features, every one of which is in the FASM (LUT `INIT`
words bit-identical). The FASM's 15 extra features are exactly its
features without positive bits (14 `NOCLKINV`, 1 `IDELAY_TYPE_FIXED`).

| Copy of the `.bit` | Change | Result |
|---|---|---|
| control | none | accepted; same machine |
| lut_bit | `CLBLL_L_X2Y44` `ALUT.INIT[58]` (segbit 35_02) flipped in the frame data | rejected by `physCompile_bit`: different machine |
| unknown_bit | a bit of a used tile that no segbits entry mentions, set | rejected by the reader: unexplained bit |
| padding | a bit of a row padding frame set | rejected by the reader |
| bram | a bit of a block RAM frame set | rejected by the reader |
| idcode | `IDCODE` value changed | rejected by the reader |

## 1. The routed design (M4a)

```lean
theorem VeryFPGA.phys_blinks :
    Phys.clockPad blinkyPhys = some "G11" ∧ Phys.ledPad blinkyPhys = some "E11" ∧
    ∀ n, Phys.ledAt blinkyPhys n = some true ↔ n % 2 ^ Spec.N ≥ 2 ^ (Spec.N - 1)

theorem VeryFPGA.phys_refines_spec (n : Nat) :
    Phys.ledAt blinkyPhys n = some (Spec.led (Spec.run n))
```

`blinkyPhys` is `build/blinky.fasm` read at build time: every feature checked
against the X-Ray database (`XRay.lean`), the physical wiring reconstructed
from the enabled PIPs and X-Ray's connectivity (`Route.lean`), and features
grouped by site (`Phys.lean`). `Phys.ledAt blinkyPhys n` is the level of the
LED pad during clock cycle `n` under the site models (`PhysImpl.lean`); it is
`none` if any feature is outside what the models cover, if the clock
structure is not pad -> ILOGIC -> BUFGCTRL -> BUFHCE -> every flip-flop, or if
the LED pad's tristate input is not the constant 0. `Spec.N = 27`.

In words: **in the configuration nextpnr produced, the clock enters at
package pin G11, and the pad at package pin E11 is high during cycle `n`
exactly when `n mod 2^27 ≥ 2^26`**: a square wave with a period of 2^27
cycles and 50 % duty, starting low at power-up. LED0 on E11 is active high
(`board/FACTS.md`), so pad high means the LED is lit.

### What it does not say

- **Nothing about the `.bit`.** The theorem is about the FASM file;
  section 0 carries it to the bitstream.
- **Nothing about time in seconds.** One step is one rising edge of the
  clock; 100 MHz (period 1.342 s) is a board fact.
- **Nothing electrical beyond an allow-list**: the IO settings are checked
  against `board/astria.xdc`, not modelled.
- **About other pads, only an assumption**: IOBs without features (e.g.
  F11, shared with the RP2040) are assumed not to drive.

### Assumed, not proved

Ordered from closest to the theorem to furthest.

1. **Site models** (`lean/VeryFPGA/PhysImpl.lean`, primitives in
   `Prims.lean`). Each feature's meaning and its source:

   | Item | Meaning used | Source |
   |---|---|---|
   | LUT `INIT` | output = entry `A1 + 2*A2 + ... + 32*A6`; `O6` all 64 entries, `O5` the lower 32 with A1..A5 | UG953 LUT6 convention, UG474 for `O5`/`O6`; `Prims.lut` matches Yosys `LUT6` on 256 vectors. That FASM `INIT[i]` is LUT6 `INIT[i]` is prjxray's convention, not documented |
   | `?FF.ZINI` | set: power-up value 0 | prjxray 011-clb-ffconfig |
   | `?FF.ZRST`, `FFSYNC` | set: synchronous reset to 0 | 011-clb-ffconfig |
   | `CEUSEDMUX`, `SRUSEDMUX` | absent: CE = 1, never reset | 011, 014-clb-ffsrcemux |
   | `PRECYINIT.*` | carry-in from `CIN`, `AX`, 1; none set: 0 (`C0` is the all-zero bit pattern) | 017-clb-precyinit, `segbits_clbll_l.db` |
   | `CARRY4.?CY0` | set: `DI` = `O5`, else the bypass pin | 013-clb-ncy0 |
   | `?FFMUX.XOR`, `?FFMUX.O6` | flip-flop `D` from the carry sum / LUT `O6` | 015-clb-nffmux (names only) and UG474 |
   | CARRY4 `S` = LUT `O6`; slice outputs `A`..`D` = `O6`; `?Q` = flip-flop | | UG474 |
   | CARRY4 itself | `Prims.carry4` | UG953; matches Yosys on all 1024 inputs |
   | `CLKINV` | must be absent (rising edge); `NOCLKINV` (the same bit cleared) accepted, not required | 011-clb-ffconfig |
   | Sites without features that drive a configured site | part of the design; a featureless pad is unconfigured | needed for the bitstream (M4b) |
   | `ZINV_X` | set means input `X` not inverted | feature names; consistent with the working board (BUFGCTRL `CE0` and OLOGIC `T1` both tied to 1) |
   | OLOGIC `OMUX.D1` + `OQUSED` | `OQ = D1` | feature names only |
   | OLOGIC `DATA_RATE_TQ.BUF` | `TQ = T1` (inverted unless `ZINV_T1`) | feature names only |
   | LED pad | level = `O` input; tristate `T` must be the constant 0 | UG471 |
   | BUFHCE, BUFGCTRL, ILOGICE3, IDELAYE2 | checked as pass-through, not modelled | decision of 2026-11-10 |
   | IO electrical settings, clock tile enables | allow-lists | decision of 2026-11-10 |
   | IOBs with no features (e.g. F11) | do not drive their pad | assumption: unconfigured IOB output buffers are off |

2. **Physical wiring** (`lean/VeryFPGA/Route.lean`), from these readings of
   the X-Ray database:
   - nodes are the closure of the `tileconn.json` joins (prjxray
     `node_model.py`); site pin directions from `site_type_*.json`;
   - a wire's driver is the enabled bit-backed PIPs and `always`
     pseudo-PIPs into it; if none, its `default` pseudo-PIP (read as the
     multiplexer's no-bits connection), listed in the FASM or not;
   - **route-through rule:** a pseudo-PIP from an input-pin wire to an
     output-pin wire of the same site is the path through that site, not
     routing; the site's output pin is the driver and the site model
     decides what it does (without this, the BUFHCE output would have two
     drivers);
   - site pins with no tile wire in X-Ray (`null`, e.g. `REV`) are
     unwired.
   Hard errors, each tested by a faulty FASM copy: a node with two drivers,
   an enabled PIP on no traced path, a listed `default` pseudo-PIP on a
   wire with another driver, a routing loop.
3. **Site grouping** (`lean/VeryFPGA/Phys.lean`): FASM site prefixes from
   prjxray's naming rules (`segmaker.py`) on global site names; global names
   matched to tile-local sites by type and coordinate order; package pins
   from `package_pins.csv`.
4. **FASM parser and feature check** (`Fasm.lean`, `XRay.lean`): only
   `TILE.FEATURE` and `TILE.FEATURE[hi:lo] = W'b...` lines; every feature
   must be in `segbits_*.db` or `ppips_*.db` (following `*_SING` tile
   aliases as prjxray's `tile_segbits_alias.py` does); duplicates, `hint`
   pseudo-PIPs and unknown features rejected.
5. **The X-Ray database** (prjxray-db `a8b09269`, `spartan7`, die
   `xc7s50`): `tilegrid.json`, `tileconn.json`, `tile_type_*.json`,
   `site_type_*.json`, `segbits_*.db`, `ppips_*.db`, `package_pins.csv`.
   Reverse-engineered by fuzzing the vendor tool. Not tracked by lake;
   pinned in `TOOLS.md`.
6. **The clock pad receives a clean 100 MHz clock**, and the clock network
   delivers each edge once to every flip-flop.
7. **Timing is met** (nextpnr reports 391 MHz achievable; not checked).
8. **Flip-flops power up at their configured values** when configuration
   completes.
9. **Everything after the FASM**: `fasm2frames`, `xc7frames2bit`,
   openFPGALoader, and the FPGA's configuration logic (section 0 removes
   the first two from the trusted base for `bit_blinks`).
10. **Lean**: the kernel; Lean's compiler, runtime and the C compiler, both
    for `bv_decide`'s certificate check and because the readers above run as
    compiled code at build time.

Not trusted, because the kernel re-checks: `def_by_eval`, which computes
`physCompile blinkyPhys` at build time (the kernel checks
`physCompile blinkyPhys = some physMachine` by evaluation), and the
abstraction `chainBits` (counter bit of each flip-flop from its carry-chain
position), which only steers the proof.

### `#print axioms`

```
'VeryFPGA.phys_blinks' depends on axioms: [propext,
 Classical.choice,
 Quot.sound,
 phys_step_ok._native.bv_decide.ax_1_38]
```

`phys_step_ok._native.bv_decide.ax_1_38` is generated by `bv_decide` in the
step lemma `phys_step_ok`: Lean's LRAT checker, run as compiled code,
accepted the SAT certificate for the routed design's step formula (item 10;
see the M3 section for its exact form). The same kind of axiom as the one
Kirill accepted for M3; this instance accepted by Kirill on 2026-11-11.
No `sorry`, no hand-written axiom, no `native_decide`.

### Tests

| Make target | What | Result |
|---|---|---|
| `fasm-check` | every FASM feature in the X-Ray database; six malformed copies rejected | 503/503 |
| `route-check` | wiring reconstructed; four faulty copies rejected by routing | all rejected, control accepted |
| `phys-check` | simulation of the decoded machine (counts 0..4999; 2000 random-state steps); five unsupported configurations refused by the models | all as required |
| `phys-mutation` | the unchanged routed-design proof against FASM copies | see below |

Routed-design mutation test (`make phys-mutation`); each copy passes the
FASM check, the routing and the site models, so only the proof can reject
it:

| Copy | Change | Result |
|---|---|---|
| control | none | proof accepted |
| lut_init | `CLBLL_L_X2Y44` ALUT `INIT` entry 58 (read by the design): 0 -> 1 | rejected at `phys_step_ok` (SAT counterexample) |
| reroute | `SLICE_X0Y45` input `D3` moved from `DQ` to its default (VCC): PIP and its pseudo-PIP removed | rejected at `phys_step_ok` (SAT counterexample) |
| ff_init | `CLBLL_L_X2Y43` `BFF.ZINI` removed (power-up 1) | rejected at `phys_init_ok` |

A swap of two flip-flop-to-LUT connections, as in M3, is not possible here:
no pair of such routes in this design can trade sources through a single
interconnect PIP each, so the reroute mutant moves one input to a constant
instead.

### Embedding

Deep, as in M3: the routed design is Lean data, `physCompile` gives its
meaning, the kernel evaluates it on the literal design. The readers (FASM,
X-Ray, routing, grouping) run at build time and are trusted like a parser.

## 2. The Yosys netlist (M3)

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

In words: in the netlist Yosys produced, the `led` port is high during cycle
`n` exactly when `n mod 2^27 ≥ 2^26`.

### What it does not say

Nothing below the netlist (pack, place, route, FASM, frames, `.bit`; the
routed design is covered by section 1, the `.bit` by nothing yet); nothing
about time in seconds, electrical behaviour, or ports other than `clk` and
`led`.

### Assumed, not proved

1. **Primitive semantics** (`Prims.lean`): `INV`, `IBUF`, `OBUF`, `BUFG`,
   `FDRE`, `CARRY4`, `LUT` (UG953), tested on every input against Icarus
   Verilog simulations of Yosys `cells_sim.v` (`make test-prims`: 1024
   CARRY4, 256 LUT6, 2 INV/buffer, 16 FDRE vectors). Agreement with Yosys's
   model is evidence, not proof, of agreement with the silicon.
2. **Netlist semantics** (`Impl.lean`): a synchronous machine whose state is
   the FDRE outputs; combinational cells evaluated by tracing each flop input
   back to flop outputs and constants.
3. **The JSON parser** (`Netlist.lean`, `load_netlist`):
   - accepts only the six cell types above, with exactly their port names,
     directions and widths; FDRE accepts only the `INIT` parameter (1-bit
     string), other cells no parameters; `x`/`z` bits and outputs tied to
     constants are rejected;
   - ignores `attributes` and every module except the one marked `top`;
   - rejects a wire with an `init` attribute;
   - a duplicate key inside one JSON object would be merged silently by
     `Lean.Json.parse` (Yosys does not write duplicate keys);
   - the bit order of multi-bit parameters is not exercised (the netlist has
     no LUTs).
4. Clean clock; timing met; flops power up at `INIT`; everything downstream
   of the netlist; Lean (as in section 1, items 6-10).

### `#print axioms`

```
'VeryFPGA.netlist_blinks' depends on axioms: [propext, Classical.choice, Quot.sound, step_ok._native.bv_decide.ax_1_29]
```

The generated axiom states

```
Std.Tactic.BVDecide.Reflect.verifyBVExpr step_ok._expr_def_... step_ok._cert_def_... = true
```

that is: Lean's LRAT certificate checker, run as compiled code, accepted the
SAT solver's certificate for the step formula. Lean names it with an internal
counter (it was `ax_1_27` at the M3 commit and became `ax_1_29` when `Sig`
gained constructors in M4a.3); the statement is the same kind.

### Mutation test

`make mutation` runs the unchanged `Refine.lean` against copies of the JSON:

| Copy | Change | Result |
|---|---|---|
| control | none | proof accepted |
| cyinit | first `CARRY4`: `CYINIT` 0 -> 1 | rejected at `step_ok` (SAT counterexample) |
| swap_d | `D` inputs of two FDREs swapped | rejected at `step_ok` (SAT counterexample) |
| flop_init | one FDRE `INIT` 0 -> 1 | rejected at `init_ok` |

## 3. The specification (M2)

`Spec.led_run (n) : led (run n) = true ↔ n % 2^N ≥ 2^(N-1)`, axioms
`[propext, Quot.sound]`. The same script fails on a wrong threshold and on
inverted polarity. Both top-level theorems compose with it.

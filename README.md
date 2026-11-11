# VeryFPGA: a blinking LED with a proof

This project makes an LED blink on an FPGA board, and then proves, in the
Lean theorem prover, that the configuration file actually loaded into the
chip makes the LED blink.

That sounds like a lot of machinery for a blinking LED, and it is. The LED is
deliberately trivial so that all the attention can go to the question this
project is really about: **how far down can a mathematical proof reach
towards the physical chip?**

## The problem

An FPGA is a chip whose logic is defined by a configuration file, the
*bitstream*: a few megabytes of bits that set up every logic cell, every
flip-flop and every programmable switch in the wiring. Nobody writes a
bitstream by hand. A chain of tools produces it from a hardware description:

```mermaid
flowchart LR
  V[Verilog source] --> Y[Yosys<br/>synthesis] --> N[nextpnr<br/>place and route] --> F[FASM<br/>feature list] --> B[bitstream .bit] --> C[the chip]
```

Each tool is a large program that can have bugs. When people "verify" a
hardware design, they usually check the source code, and then trust that the
tools translated it correctly. This project does not trust the tools. It
reads what the tools produced and checks *that* against a specification.

## The idea: tools as untrusted oracles

The tools are treated as oracles: they produce an artifact, and Lean checks
the artifact. A buggy tool can make a proof fail, but it cannot make a false
theorem appear.

Three things are written in Lean:

1. **A specification** of what "blinks" means, as plain mathematics: a
   27-bit counter that starts at 0 and adds 1 on every clock cycle; the LED
   shows its top bit. Proved: the LED is on at cycle `n` exactly when
   `n mod 2^27 ≥ 2^26`, a square wave with a period of 2^27 cycles (1.34 s at
   100 MHz) and 50 % duty.
2. **A meaning for the tools' output**: Lean reads the artifact (netlist,
   FASM or bitstream) as data, and Lean definitions say what each piece of
   configured hardware does.
3. **A refinement proof** that, for every clock cycle, the hardware described
   by the artifact drives the LED exactly as the specification says.

## What is proved

There are three theorems, one for each artifact the build produces. Each
goes further down the tool chain than the one before:

| Theorem | About | Covers |
|---|---|---|
| `netlist_blinks` | the netlist from Yosys | the design after synthesis |
| `phys_blinks` | the FASM from nextpnr | also packing, placement and routing |
| `bit_blinks` | the `.bit` loaded on the board | also bitstream generation |

The strongest one, in `lean/VeryFPGA/BlinkyBit.lean`:

```lean
theorem bit_blinks :
    Phys.clockPad blinkyBitPhys = some "G11" ∧ Phys.ledPad blinkyBitPhys = some "E11" ∧
    ∀ n, Phys.ledAt blinkyBitPhys n = some true ↔ n % 2 ^ Spec.N ≥ 2 ^ (Spec.N - 1)
```

In words: in the FPGA configured with this bitstream, the clock comes in on
package pin G11, and the pad at package pin E11, which drives the LED, is
high during clock cycle `n` exactly when `n mod 2^27 ≥ 2^26`.

To get there, Lean decodes the bitstream bit by bit: every set bit must be
explained by an entry in the Project X-Ray database, or the build fails. It
then reconstructs which wire drives which logic input, interprets each
configured logic cell, and checks that the result is the same machine
already proved correct.

## What is *not* proved

A theorem is only as good as its assumptions. `TRUST.md` lists them in
full; the main ones are:

- **The X-Ray database is right.** It maps bitstream bits to features. It was
  reverse-engineered by others, by fuzzing the vendor tools.
- **The hardware models are right.** Lean definitions say what a configured
  look-up table, carry chain or flip-flop does. They are taken from vendor
  documentation and prjxray notes, and tested against simulation models, but
  some feature meanings are inferred from their names.
- **The physical world behaves**: a clean clock arrives, timing is met, the
  flip-flops start at their configured values, the chip loads the bitstream
  as documented.
- **Lean itself**: its kernel, and its compiler, because the SAT solver's
  certificates are checked by compiled code.

"The LED is formally verified" is true only relative to that list.

## How the checks are themselves checked

A check that cannot fail verifies nothing. So every stage has *mutation
tests*: deliberately broken copies of the artifacts that must be rejected.
Examples: one bit of a look-up table flipped in the bitstream, a wire
rerouted in the FASM, a flip-flop's start value changed in the netlist, a
stray configuration bit that the database cannot explain. Each must make the
proof fail or the decoder refuse, while the unmodified copy passes.

## The hardware

- Board: Adiuvo Engineering Astria S7-50 (also sold as Leonidas)
- FPGA: AMD Spartan-7 XC7S50, package FTGB196
- Clock: on-board 100 MHz oscillator on pin G11
- LED: LED0 on pin E11, active high

Board facts and their sources are in `board/FACTS.md`.

## The tools

- **Yosys** (synthesis), **nextpnr-xilinx** (place and route), **Project
  X-Ray** (bitstream database and tools), packaged by **openXC7**; an
  open-source tool chain for AMD 7-series FPGAs. The vendor tool (Vivado) is
  not used.
- **openFPGALoader** to load the bitstream over JTAG.
- **Lean 4** with its `bv_decide` tactic, which proves statements about
  bit vectors with a SAT solver and checks the solver's certificate.

Exact versions are in `TOOLS.md`.

## Installing the tools

Tested on Ubuntu 24.04, x86-64. Everything installs into your home
directory; no root is needed except for the USB rule at the end. All tools
are prebuilt releases; nothing is compiled.

| Tool set | Provides | Source |
|---|---|---|
| openXC7 toolchain, release `2026-11-09` | nextpnr-xilinx, Project X-Ray database and tools, fasm2frames, xc7frames2bit | `github.com/cavearr/toolchain-openxc7-releases` |
| YosysHQ oss-cad-suite, release `2026-11-04` (the one the openXC7 release was validated with) | yosys, openFPGALoader, Icarus Verilog | `github.com/YosysHQ/oss-cad-suite-build` |
| elan, then Lean v4.35.0 | Lean and its build tool `lake` | `github.com/leanprover/elan` |

```sh
mkdir -p ~/opt/veryfpga && cd ~/opt/veryfpga

# 1. openXC7 toolchain (also includes the chip database for the XC7S50)
R=https://github.com/cavearr/toolchain-openxc7-releases/releases/download/2026-11-09
curl -LO $R/openxc7-toolchain-linux-x86-64-20261109.tgz
curl -LO $R/SHA256SUMS
sha256sum -c --ignore-missing SHA256SUMS
mkdir openxc7 && tar xzf openxc7-toolchain-linux-x86-64-20261109.tgz -C openxc7

# 2. oss-cad-suite
curl -LO https://github.com/YosysHQ/oss-cad-suite-build/releases/download/2026-11-04/oss-cad-suite-linux-x64-20261104.tgz
echo "8b4ee0a8071df1e20d3497c4fc11d66cc69991bd3e97903d56cc689c41fdea9a  oss-cad-suite-linux-x64-20261104.tgz" | sha256sum -c
tar xzf oss-cad-suite-linux-x64-20261104.tgz      # creates oss-cad-suite/

# 3. elan, without touching your shell profile (.envrc puts it on PATH)
curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh -o elan-init.sh
sh elan-init.sh -y --no-modify-path --default-toolchain none
```

The Lean version itself is pinned in `lean/lean-toolchain`; the first
`lake build` downloads it. Exact versions and hashes of everything are in
`TOOLS.md`.

`.envrc` at the repository root puts the tools on `PATH` and sets the
database locations. With [direnv](https://direnv.net), run `direnv allow`
once in the repository and it is loaded whenever you enter the directory,
in any shell direnv supports (bash, zsh, fish). Without direnv, load it by
hand in bash or zsh: `. ./.envrc`.

To load the board over its built-in FTDI FT232H JTAG adapter without root,
install the udev rule (the one host-level change):

```sh
sudo cp board/60-veryfpga-ft232h.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

Then replug the board and check with `openFPGALoader -c ft232 --detect`
(with `.envrc` loaded); it should report an xc7s50.

## Running it

With `.envrc` loaded (see above):

```sh
make                # Verilog -> netlist -> FASM -> bitstream
make verify         # build, run all proofs and all tests
make program        # load the bitstream into the FPGA (SRAM only)
```

`make verify` writes `build/PROOF.txt`, which records the SHA-256 of the
netlist, FASM and bitstream the proofs were run against, and the axioms each
theorem depends on. Lean re-runs the proofs whenever one of those files
changes, so a proof cannot be paired with a stale bitstream.

## Repository layout

```
.envrc                    tool paths and database locations (direnv)
rtl/blinky.v              the design (untrusted input)
board/                    board facts, pin constraints, udev rule
lean/VeryFPGA/
  Spec.lean               the specification and its theorem
  Prims.lean              meaning of the logic primitives
  Netlist.lean, Impl.lean netlist reader and its meaning
  Refine.lean             netlist proof
  Fasm.lean, XRay.lean    FASM reader, checked against the X-Ray database
  Route.lean              physical wiring from routing switches
  Phys.lean, PhysImpl.lean  configured sites and their meaning
  PhysRefine.lean         routed-design proof
  Bitstream.lean          bitstream reader
  BlinkyBit.lean          bitstream theorem
test/                     cross-checks and mutation tests
TRUST.md                  what is proved, what is assumed
PLAN.md                   milestones and decisions
TOOLS.md                  tool versions
```

## Where this is heading

The long-term goal is a hardware description language embedded in Lean,
with a checker that decodes the final bitstream and proves it equivalent to
the Lean source. This repository is the smallest end-to-end slice of that:
one LED, every step from specification to bits.

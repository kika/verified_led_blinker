/-
The meaning of a routed design (`Phys.PhysDesign`) as a synchronous machine,
the same `Machine` type as for the Yosys netlist in M3.

This is the trusted model of the configured silicon, as far as blinky uses
it. Every site feature and tile feature must be one this file knows;
anything else makes `physCompile` return `none`, so no theorem about the
design can be proved.

Sources for the meaning of each feature (see TRUST.md for the details):
- prjxray fuzzer notes (011-clb-ffconfig, 013-clb-ncy0, 014-clb-ffsrcemux,
  015-clb-nffmux, 017-clb-precyinit): `ZINI`, `ZRST`, `FFSYNC`,
  `CEUSEDMUX`, `SRUSEDMUX`, `?CY0`, `PRECYINIT.*`. In FASM a listed feature
  means its bits are 1, an unlisted one 0.
- AMD UG474 (CLB) for the slice structure the features configure: the LUT
  `O6`/`O5` outputs, the carry chain inputs, the flip-flop input selector,
  and that slice outputs `A`..`D` carry `O6`.
- Feature names only, with no prjxray documentation: the output logic
  (`OMUX.D1`, `OQUSED`, `OSERDES.DATA_RATE_TQ.BUF`), `ZINV_*` meaning "not
  inverted", the clock buffers and the IO settings.

What it models:
- SLICEL: four LUTs (`O6` six-input, `O5` the lower half, five-input), the
  CARRY4 with its carry-in selector `PRECYINIT` and its `DI` selectors
  `?CY0`, four flip-flops `AFF`..`DFF` with `D` from the carry XOR or the
  LUT `O6`.
- OLOGICE3 in bypass: `OQ = D1`, `TQ = T1` (inverted unless `ZINV_T1`).
- The LED pad: an IOB with the output settings of `board/astria.xdc`; its
  level is its `O` input, and its tristate input `T` must be the constant 0.

What it only checks (decision of 2026-11-10: structure, not semantics):
- the clock: every used slice `CLK` comes from one BUFHCE, fed by one
  BUFGCTRL selecting its `I0`, fed by one ILOGICE3, fed by the clock pad;
  each buffer is in a pass-through configuration;
- IO electrical settings: exactly the `board/astria.xdc` allow-list;
- clock network enables in clock tiles: an allow-list.
-/
import VeryFPGA.Phys
import VeryFPGA.Impl

namespace VeryFPGA.Phys

def PSite.has (s : PSite) (f : String) : Bool := s.features.contains f

def PSite.input (s : PSite) (pin : String) : Src :=
  (s.inputs.lookup pin).getD (.none s!"no pin {pin}")

def PSite.word (s : PSite) (w : String) : Option (List Bool) := s.words.lookup w

/-- Slice letters A..D for LUT, flip-flop and carry stage 0..3. -/
def letter : Nat → String
  | 0 => "A" | 1 => "B" | 2 => "C" | _ => "D"

/-! ### Allow-lists -/

def sliceFeatures : List String :=
  ["FFSYNC", "NOCLKINV", "CEUSEDMUX", "SRUSEDMUX",
   "PRECYINIT.CIN", "PRECYINIT.AX", "PRECYINIT.C1"] ++
  ((List.range 4).flatMap fun n =>
    let l := letter n
    [s!"{l}FF.ZINI", s!"{l}FF.ZRST", s!"{l}FFMUX.XOR", s!"{l}FFMUX.O6", s!"CARRY4.{l}CY0"])

def ologicFeatures : List String := ["OMUX.D1", "OQUSED", "OSERDES.DATA_RATE_TQ.BUF", "ZINV_T1"]

/-- The clock pad: LVCMOS33 input, input only, no pull (`board/astria.xdc`). -/
def clockPadFeatures : List String :=
  ["LVCMOS25_LVCMOS33_LVTTL.IN",
   "LVCMOS12_LVCMOS15_LVCMOS18_LVCMOS25_LVCMOS33_LVDS_25_LVTTL_SSTL135_SSTL15_TMDS_33.IN_ONLY",
   "PULLTYPE.NONE"]

/-- The LED pad: LVCMOS33 output, 12 mA, slow slew, no pull (`board/astria.xdc`). -/
def ledPadFeatures : List String :=
  ["LVCMOS33_LVTTL.DRIVE.I12_I16",
   "LVCMOS12_LVCMOS15_LVCMOS18_LVCMOS25_LVCMOS33_LVTTL_SSTL135_SSTL15.SLEW.SLOW",
   "PULLTYPE.NONE"]

/-- Clock network enables in the clock tiles (`HCLK_CMT`, `HCLK_R`,
`CLK_HROW_*`, `CLK_BUFG_REBUF`). They switch on buffers along the clock
route and carry no logic. -/
def clockTileFeatures : List String :=
  ["HCLK_CMT_CCIO0_ACTIVE", "HCLK_CMT_CCIO0_USED", "HCLK_CMT_CK_BUFHCLK0_USED",
   "ENABLE_BUFFER.HCLK_CK_BUFHCLK0", "CLK_HROW_R_CK_GCLK0_ACTIVE", "CLK_HROW_CK_IN_L3_ACTIVE",
   "GCLK0_ENABLE_ABOVE", "GCLK0_ENABLE_BELOW"]

/-- Same elements, ignoring order and repetition. -/
def sameSet (a b : List String) : Bool := a.all b.contains && b.all a.contains

/-- Is flip-flop `n` of slice `s` used, i.e. configured at all? -/
def ffUsed (s : PSite) (n : Nat) : Bool :=
  let l := letter n
  s.has s!"{l}FF.ZINI" || s.has s!"{l}FF.ZRST" || s.has s!"{l}FFMUX.XOR" || s.has s!"{l}FFMUX.O6"

def siteOk (s : PSite) : Bool :=
  match s.siteType with
  | "SLICEL" =>
    s.features.all sliceFeatures.contains &&
    s.words.all (fun (w, bits) => w ∈ ["ALUT.INIT", "BLUT.INIT", "CLUT.INIT", "DLUT.INIT"] &&
      bits.length == 64) &&
    -- at most one carry-in selection
    (["PRECYINIT.CIN", "PRECYINIT.AX", "PRECYINIT.C1"].filter s.has).length ≤ 1 &&
    (List.range 4).all (fun n =>
      let l := letter n
      -- a used flip-flop has exactly one D source
      !ffUsed s n || ([s!"{l}FFMUX.XOR", s!"{l}FFMUX.O6"].filter s.has).length == 1) &&
    -- a used reset must be synchronous to 0 (FDRE)
    (!s.has "SRUSEDMUX" || (s.has "FFSYNC" &&
      (List.range 4).all (fun n => !ffUsed s n || s.has s!"{letter n}FF.ZRST"))) &&
    -- used flip-flops clock on the rising edge
    ((List.range 4).all (fun n => !ffUsed s n) || s.has "NOCLKINV")
  | "OLOGICE3" => s.features.all ologicFeatures.contains && s.words.isEmpty
  | "ILOGICE3" => s.features.all (· ∈ ["ZINV_D"]) && s.words.isEmpty
  | "IDELAYE2" => s.features.all (· ∈ ["IDELAY_TYPE_FIXED"]) && s.words.isEmpty
  | "IOB33" | "IOB33M" | "IOB33S" =>
    (sameSet s.features clockPadFeatures || sameSet s.features ledPadFeatures) && s.words.isEmpty
  | "BUFGCTRL" =>
    s.features.all (· ∈ ["IN_USE", "IS_IGNORE1_INVERTED", "ZINV_CE0", "ZINV_S0"]) &&
    s.words.isEmpty
  | "BUFHCE" => s.features.all (· ∈ ["IN_USE", "ZINV_CE"]) && s.words.isEmpty
  | _ => false

def designOk (d : PhysDesign) : Bool :=
  d.sites.all siteOk && d.tileFeatures.all (clockTileFeatures.contains ·.2)

/-! ### Flip-flops -/

/-- Every used flip-flop as `(site index, letter 0..3)`, in site order. Its
position in this list is its index in the machine state. -/
def flops (d : PhysDesign) : List (Nat × Nat) :=
  d.sites.zipIdx.flatMap fun (s, i) =>
    if s.siteType == "SLICEL" then (List.range 4).filter (ffUsed s) |>.map (i, ·) else []

/-- Power-up value: `ZINI` set means 0 (011-clb-ffconfig). -/
def ffInit (d : PhysDesign) (f : Nat × Nat) : Bool :=
  match d.sites[f.1]? with
  | some s => !s.has s!"{letter f.2}FF.ZINI"
  | none => false

/-! ### Signals -/

/-- What to compute. -/
inductive Req where
  /-- the value driving an input pin -/
  | src (s : Src)
  /-- `O6` of LUT `n` of slice `i` -/
  | o6 (i n : Nat)
  /-- `O5` of LUT `n` of slice `i` -/
  | o5 (i n : Nat)
  /-- an output of the CARRY4 of slice `i` -/
  | carry (i : Nat) (pin : CarryPin)
  /-- the next value of flip-flop `n` of slice `i` -/
  | ffNext (i n : Nat)

def sumPin : Nat → CarryPin
  | 0 => .o0 | 1 => .o1 | 2 => .o2 | _ => .o3

/-- Compute a signal as a `Sig` over flip-flop outputs. `fuel` bounds the
number of steps; running out means a loop. `fl` is `flops d`. Every case
not modelled gives `none`. -/
def ev (d : PhysDesign) (fl : List (Nat × Nat)) : Nat → Req → Option Sig
  | 0, _ => none
  | _ + 1, .src (.const b) => some (.const b)
  | _ + 1, .src (.none _) => none
  | f + 1, .src (.pin i p) => do
    let s ← d.sites[i]?
    match s.siteType with
    | "SLICEL" =>
      if p ∈ ["AQ", "BQ", "CQ", "DQ"] then
        let n := if p == "AQ" then 0 else if p == "BQ" then 1 else if p == "CQ" then 2 else 3
        if ffUsed s n then some (.flop (← fl.idxOf? (i, n))) else none
      else if p ∈ ["A", "B", "C", "D"] then
        ev d fl f (.o6 i (if p == "A" then 0 else if p == "B" then 1 else if p == "C" then 2 else 3))
      else if p == "COUT" then ev d fl f (.carry i .co3)
      else none
    | "OLOGICE3" =>
      if p == "OQ" && s.has "OMUX.D1" && s.has "OQUSED" then ev d fl f (.src (s.input "D1"))
      else if p == "TQ" && s.has "OSERDES.DATA_RATE_TQ.BUF" then do
        let t ← ev d fl f (.src (s.input "T1"))
        if s.has "ZINV_T1" then some t else some (.inv t)
      else none
    | _ => none
  | f + 1, .o6 i n => do
    let s ← d.sites[i]?
    let init ← s.word s!"{letter n}LUT.INIT"
    let a (k : Nat) := ev d fl f (.src (s.input s!"{letter n}{k}"))
    return .lut6 init (← a 1) (← a 2) (← a 3) (← a 4) (← a 5) (← a 6)
  | f + 1, .o5 i n => do
    let s ← d.sites[i]?
    let init ← s.word s!"{letter n}LUT.INIT"
    let a (k : Nat) := ev d fl f (.src (s.input s!"{letter n}{k}"))
    return .lut5 (init.take 32) (← a 1) (← a 2) (← a 3) (← a 4) (← a 5)
  | f + 1, .carry i pin => do
    let s ← d.sites[i]?
    -- carry into stage 0 (017-clb-precyinit; no feature means C0 = 0)
    let ci ← if s.has "PRECYINIT.CIN" then ev d fl f (.src (s.input "CIN"))
      else if s.has "PRECYINIT.AX" then ev d fl f (.src (s.input "AX"))
      else if s.has "PRECYINIT.C1" then some (.const true)
      else some (.const false)
    -- DI of stage n: O5 if ?CY0 is set, else the bypass pin ?X (013-clb-ncy0)
    let di (n : Nat) := if s.has s!"CARRY4.{letter n}CY0" then ev d fl f (.o5 i n)
      else ev d fl f (.src (s.input s!"{letter n}X"))
    -- S of stage n is O6 of LUT n (UG474)
    let si (n : Nat) := ev d fl f (.o6 i n)
    return .carry4 pin ci (.const false) (← di 0) (← di 1) (← di 2) (← di 3)
      (← si 0) (← si 1) (← si 2) (← si 3)
  | f + 1, .ffNext i n => do
    let s ← d.sites[i]?
    let l := letter n
    let dIn ← if s.has s!"{l}FFMUX.XOR" then ev d fl f (.carry i (sumPin n))
      else if s.has s!"{l}FFMUX.O6" then ev d fl f (.o6 i n)
      else none
    -- CE and SR: from the pins only if CEUSEDMUX / SRUSEDMUX (014-clb-ffsrcemux)
    let r ← if s.has "SRUSEDMUX" then ev d fl f (.src (s.input "SR")) else some (.const false)
    let ce ← if s.has "CEUSEDMUX" then ev d fl f (.src (s.input "CE")) else some (.const true)
    return .fdre r ce dIn (.flop (← fl.idxOf? (i, n)))

/-! ### Clock structure and pads -/

/-- The constant driving input `pin` of `s`, if it is a constant. -/
def constIn (s : PSite) (pin : String) : Option Bool :=
  match s.input pin with
  | .const b => some b
  | _ => none

/-- Index of the site driving `pin` of `s` through its output `out`. -/
def driverIdx (s : PSite) (pin out : String) : Option Nat :=
  match s.input pin with
  | .pin j p => if p == out then some j else none
  | _ => none

/-- The package pin of the clock pad, if the clock structure is as required:
every used slice `CLK` <- BUFHCE `O` (in use, `CE` effectively 1)
<- BUFGCTRL `O` (in use, selecting `I0`: `S0` and `CE0` effectively 1, not
both `S1` and `CE1`) <- ILOGICE3 `O` (`D` not inverted; `D` and, through the
IDELAYE2, `DDLY` both from the pad) <- the clock pad. `ZINV_X` set means `X`
is not inverted. -/
def clockPad (d : PhysDesign) : Option String := do
  let slices := (flops d).map (·.1) |>.eraseDups
  let bufhs ← slices.mapM fun i => do driverIdx (← d.sites[i]?) "CLK" "O"
  let h ← match bufhs.eraseDups with
    | [h] => some h
    | _ => none
  let bh ← d.sites[h]?
  guard (bh.siteType == "BUFHCE" && bh.has "IN_USE")
  let ce ← constIn bh "CE"
  guard (if bh.has "ZINV_CE" then ce else !ce)
  let g ← driverIdx bh "I" "O"
  let bg ← d.sites[g]?
  guard (bg.siteType == "BUFGCTRL" && bg.has "IN_USE")
  let eff (pin : String) : Option Bool := do
    let v ← constIn bg pin
    some (if bg.has s!"ZINV_{pin}" then v else !v)
  guard ((← eff "S0") && (← eff "CE0") && !((← eff "S1") && (← eff "CE1")))
  let il ← driverIdx bg "I0" "O"
  let si ← d.sites[il]?
  guard (si.siteType == "ILOGICE3" && si.has "ZINV_D")
  let pad ← driverIdx si "D" "I"
  let dl ← driverIdx si "DDLY" "DATAOUT"
  let sd ← d.sites[dl]?
  guard (sd.siteType == "IDELAYE2" && driverIdx sd "IDATAIN" "I" == some pad)
  let sp ← d.sites[pad]?
  guard (sameSet sp.features clockPadFeatures)
  sp.packagePin

/-- The LED pad: the only site with the output pad settings. -/
def ledPadIdx (d : PhysDesign) : Option Nat :=
  match d.sites.zipIdx.filter (fun (s, _) => sameSet s.features ledPadFeatures) with
  | [(_, i)] => some i
  | _ => none

def ledPad (d : PhysDesign) : Option String := do (← d.sites[← ledPadIdx d]?).packagePin

/-! ### The machine -/

def physCompile (d : PhysDesign) : Option Machine := do
  guard (designOk d)
  let _ ← clockPad d
  let fl := flops d
  let fuel := 8 * d.sites.length + 16
  let next ← fl.mapM fun (i, n) => ev d fl fuel (.ffNext i n)
  let pad ← d.sites[← ledPadIdx d]?
  let out ← ev d fl fuel (.src (pad.input "O"))
  -- the LED pad must drive: its tristate input is the constant 0
  let t ← ev d fl fuel (.src (pad.input "T"))
  guard (t.closed && !t.eval [])
  return { init := fl.map (ffInit d), next, out }

/-- Level of the LED pad of routed design `d` during clock cycle `n`; `none`
if the model does not accept the design. -/
def ledAt (d : PhysDesign) (n : Nat) : Option Bool :=
  (physCompile d).map (·.ledAt n)

end VeryFPGA.Phys

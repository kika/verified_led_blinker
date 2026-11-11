/-
A routed design as Lean data: its configured sites, each with its FASM
features and, for each input pin, what drives it.

Built at build time (`load_phys`) from the resolved FASM features
(`load_fasm`, M4a.1) and the routing (`route_fasm`, M4a.2). This step only
groups and renames; what the features mean is defined in `PhysImpl.lean`.

Site naming. FASM names a site's features with a prefix derived by prjxray
from the site's *global* name (`segmaker.py`): `SLICEL_X0`/`SLICEL_X1` by the
parity of the global X, `IOB_Y0`/`IOB_Y1` (and `ILOGIC`, `OLOGIC`, `IDELAY`)
by the parity of the global Y, and `BUFGCTRL.<global name>`,
`BUFHCE.<global name>` for clock buffers. Global names come from
`tilegrid.json`; they are matched to the tile-local sites of
`tile_type_*.json` by site type and coordinate order.

Trusted, like the other build-time readers.
-/
import Lean
import VeryFPGA.XRay
import VeryFPGA.Route

open Lean

namespace VeryFPGA.Phys

/-- What drives a site input pin: a constant (a `TIEOFF` output), an output
pin of another site in the design (by index), or nothing usable, with the
reason (undriven, unwired, or driven by a site that has no features). -/
inductive Src where
  | const (b : Bool)
  | pin (site : Nat) (pin : String)
  | none (why : String)
  deriving Repr, Inhabited, Lean.ToExpr

/-- A configured site. `features` have the FASM site prefix removed
(`AFF.ZINI`); `words` are the multi-bit features with their bits, entry 0
first (`ALUT.INIT` with 64 bits). -/
structure PSite where
  tile : String
  siteType : String
  name : String
  fasm : String
  packagePin : Option String
  features : List String
  words : List (String × List Bool)
  inputs : List (String × Src)
  deriving Repr, Inhabited, Lean.ToExpr

/-- The design: configured sites, and the features that belong to a tile
rather than to a site (clock network enables). -/
structure PhysDesign where
  sites : List PSite
  tileFeatures : List (String × String)
  deriving Repr, Inhabited, Lean.ToExpr

/-- `PREFIX_X<x>Y<y>` -> `(PREFIX, x, y)`. -/
def parseSiteName (n : String) : Option (String × Nat × Nat) :=
  match n.splitOn "_X" with
  | [pre, rest] =>
    match rest.splitOn "Y" with
    | [x, y] => do pure (pre, ← x.toNat?, ← y.toNat?)
    | _ => none
  | _ => none

/-- The FASM prefix of a site, from its type and global name. -/
def fasmPrefix (siteType global : String) : String :=
  match parseSiteName global with
  | none => ""
  | some (pre, x, y) =>
    if siteType == "SLICEL" || siteType == "SLICEM" then s!"{siteType}_X{x % 2}"
    else if pre ∈ ["IOB", "ILOGIC", "OLOGIC", "IDELAY"] then s!"{pre}_Y{y % 2}"
    else if siteType == "BUFGCTRL" || siteType == "BUFHCE" then s!"{siteType}.{global}"
    else ""

/-- Tile-local site `(type, x, y)` to global site name, for one tile. -/
def globalNames (tile : String) (gridSites : List (String × String))
    (local_ : List (String × Nat × Nat)) : IO (List ((String × Nat × Nat) × String)) := do
  let types := (local_.map (·.1)).eraseDups
  let mut out := []
  for ty in types do
    let ls := (local_.filter (·.1 == ty)).mergeSort fun a b =>
      a.2.1 < b.2.1 || (a.2.1 == b.2.1 && a.2.2 ≤ b.2.2)
    let gs ← (gridSites.filter (·.2 == ty)).mapM fun (g, _) => do
      match parseSiteName g with
      | some (_, x, y) => pure (g, x, y)
      | none => throw (IO.userError s!"{tile}: cannot parse site name {g}")
    let gs := gs.mergeSort fun a b => a.2.1 < b.2.1 || (a.2.1 == b.2.1 && a.2.2 ≤ b.2.2)
    unless ls.length == gs.length do
      throw (IO.userError s!"{tile}: {ls.length} local and {gs.length} global sites of type {ty}")
    out := out ++ ls.zip (gs.map (·.1))
  pure out

/-- Group features by site and attach routing. -/
def build (root device part : String) (feats : List XRay.Feature) (routing : Route.Routing) :
    IO PhysDesign := do
  let (_, rest) ← Route.splitPips root feats
  let grid ← IO.ofExcept (Json.parse (← IO.FS.readFile s!"{root}/{device}/tilegrid.json"))
  let pins ← IO.FS.readFile s!"{root}/{part}/package_pins.csv"
  let pinOf : List (String × String) := (pins.splitOn "\n").filterMap fun l =>
    match l.splitOn "," with
    | pin :: _ :: site :: _ => if pin == "pin" then none else some (site, pin)
    | _ => none
  -- Every site that appears in the routing, with its global name and prefix.
  let allPins := routing.conns.map (·.input) ++ routing.conns.map (·.source) ++
    routing.undriven ++ routing.unwired
  let siteKeys := (allPins.map fun p => (p.tile, p.siteType, p.x, p.y)).eraseDups
  let tiles := (siteKeys.map (·.1)).eraseDups
  let mut named : List ((String × String × Nat × Nat) × String) := []
  for t in tiles do
    let gj ← IO.ofExcept (grid.getObjVal? t)
    let gsites ← match gj.getObjVal? "sites" with
      | .ok (.obj kv) => kv.toList.mapM fun (g, v) => do pure (g, ← IO.ofExcept v.getStr?)
      | _ => pure []
    -- All sites of the tile type, not only those the routing touched.
    let ty ← IO.ofExcept (gj.getObjValAs? String "type")
    let tj ← IO.ofExcept (Json.parse (← IO.FS.readFile s!"{root}/tile_type_{ty}.json"))
    let local_ ← (← IO.ofExcept (tj.getObjValAs? (Array Json) "sites")).toList.mapM fun sj => do
      pure (← Route.getStr sj "type", ← Route.getNat sj "x_coord", ← Route.getNat sj "y_coord")
    for ((ty, x, y), g) in ← globalNames t gsites local_ do
      named := ((t, ty, x, y), g) :: named
  let nameOf (t ty : String) (x y : Nat) : String := (named.lookup (t, ty, x, y)).getD ""
  -- Assign each non-PIP feature to the site whose prefix it starts with.
  let prefixed := siteKeys.map fun k@(t, ty, x, y) => (k, fasmPrefix ty (nameOf t ty x y))
  let mut siteFeats : List ((String × String × Nat × Nat) × String) := []
  let mut siteWords : List ((String × String × Nat × Nat) × String × List Bool) := []
  let mut tileFeatures := []
  for f in rest do
    let owners := prefixed.filter fun ((t, _, _, _), p) =>
      t == f.tile && p != "" && f.feature.startsWith (p ++ ".")
    match owners with
    | [(k, p)] =>
      let name := (f.feature.drop (p.length + 1)).toString
      if f.bits.isEmpty then siteFeats := (k, name) :: siteFeats
      else
        let hi := (f.bits.map (·.1)).foldl max 0
        let word ← (List.range (hi + 1)).mapM fun i =>
          match f.bits.lookup i with
          | some b => pure b
          | none => throw (IO.userError s!"{f.tile}.{f.feature}: bit {i} missing")
        siteWords := (k, name, word) :: siteWords
    | [] => tileFeatures := (f.tile, f.feature) :: tileFeatures
    | _ => throw (IO.userError s!"{f.tile}.{f.feature}: matches more than one site")
  -- Configured sites: those with at least one feature.
  let configured := siteKeys.filter fun k =>
    siteFeats.any (·.1 == k) || siteWords.any (·.1 == k)
  let index (t ty : String) (x y : Nat) : Option Nat := configured.idxOf? (t, ty, x, y)
  let srcOf (p : Route.SitePin) : Src :=
    if p.siteType == "TIEOFF" then
      if p.pin == "HARD1" then .const true
      else if p.pin == "HARD0" then .const false
      else .none s!"TIEOFF pin {p.pin}"
    else match index p.tile p.siteType p.x p.y with
      | some i => .pin i p.pin
      | none => .none s!"driven by {p.tile}/{nameOf p.tile p.siteType p.x p.y}.{p.pin}, a site with no features"
  let sites := configured.map fun k@(t, ty, x, y) =>
    let g := nameOf t ty x y
    let driven := (routing.conns.filter fun c =>
      (c.input.tile, c.input.siteType, c.input.x, c.input.y) == k).map fun c => (c.input.pin, srcOf c.source)
    let undriven := (routing.undriven.filter fun p => (p.tile, p.siteType, p.x, p.y) == k).map
      fun p => (p.pin, Src.none "undriven")
    let unwired := (routing.unwired.filter fun p => (p.tile, p.siteType, p.x, p.y) == k).map
      fun p => (p.pin, Src.none "unwired")
    { tile := t, siteType := ty, name := g, fasm := fasmPrefix ty g,
      packagePin := pinOf.lookup g,
      features := (siteFeats.filter (·.1 == k)).map (·.2) |>.reverse,
      words := (siteWords.filter (·.1 == k)).map (·.2) |>.reverse,
      inputs := driven ++ undriven ++ unwired : PSite }
  pure { sites, tileFeatures := tileFeatures.reverse }

end VeryFPGA.Phys

namespace VeryFPGA

open Lean Elab Command in
/-- `load_phys foo from feats routing xray "<family>" "<die>" "<part>"` builds the
`PhysDesign` of a design at build time from its resolved FASM features and
its routing, and defines `foo`. -/
elab "load_phys " id:ident " from " fs:ident rt:ident " xray " fam:str dev:str part:str :
    command => do
  let some dbRoot ← IO.getEnv "PRJXRAY_DB_DIR"
    | throwError "load_phys: PRJXRAY_DB_DIR is not set (source env.sh)"
  let feats ← unsafe evalConst (List XRay.Feature)
    (← liftCoreM <| realizeGlobalConstNoOverloadWithInfo fs)
  let routing ← unsafe evalConst Route.Routing
    (← liftCoreM <| realizeGlobalConstNoOverloadWithInfo rt)
  let d ← try Phys.build s!"{dbRoot}/{fam.getString}" dev.getString part.getString feats routing
    catch e => throwError "load_phys: {e.toMessageData}"
  let name := (← getCurrNamespace) ++ id.getId
  liftCoreM do
    addAndCompile <| .defnDecl {
      name, levelParams := [], type := mkConst ``Phys.PhysDesign, value := toExpr d,
      hints := .regular 0, safety := .safe }
    enableRealizationsForConst name

end VeryFPGA

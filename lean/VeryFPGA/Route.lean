/-
Physical wiring of a routed design: for every input pin of every site in the
tiles the FASM uses, which site output pin drives it.

X-Ray model (prjxray `connections.py`, `node_model.py`):
- A *wire* is a piece of metal inside one tile, `(tile, wire name)`.
- A *node* is a set of wires joined across tiles. `tileconn.json` lists the
  joins as rules "wire A of tile type T at grid (x, y) is joined to wire B of
  tile type U at (x + dx, y + dy)"; a node is the closure of these joins.
- A *PIP* is a programmable switch inside a tile driving one wire from
  another. Bit-backed PIPs are on when the FASM lists them. Pseudo-PIPs have
  no bits: `always` ones are permanent connections; a `default` one is the
  connection a multiplexer makes when none of its bit-backed PIPs is on.
- A *site pin* (direction from `site_type_*.json`) sits on one tile wire.

Driver of a wire `(t, w)`: the enabled bit-backed PIPs and `always`
pseudo-PIPs into it; if there are none, its `default` pseudo-PIP, if any.
Driver of a node: the site output pins on its wires together with the
drivers of its wires; there must be exactly one.

Hard errors: a node with more than one driver; a loop; a FASM PIP that is
not on the traced path of any site input pin; a FASM `default` pseudo-PIP
whose wire also has an enabled PIP.

Trusted, like the parsers: this code and the X-Ray files it reads decide
which pin drives which.
-/
import Lean
import Std.Data.HashMap
import VeryFPGA.XRay

open Lean

namespace VeryFPGA.Route

/-- A site pin. `site` is the site's name within its tile type (`X0Y0`),
`x`, `y` its coordinates within the tile. -/
structure SitePin where
  tile : String
  site : String
  siteType : String
  x : Nat
  y : Nat
  pin : String
  deriving Repr, Inhabited, BEq, Hashable, Lean.ToExpr

/-- A PIP that a traced path went through: tile, destination wire, source wire. -/
structure Pip where
  tile : String
  dst : String
  src : String
  deriving Repr, Inhabited, BEq, Hashable, Lean.ToExpr

/-- A site input pin and the site output pin that drives it. -/
structure Conn where
  input : SitePin
  source : SitePin
  pips : List Pip
  deriving Repr, Lean.ToExpr

structure Routing where
  conns : List Conn
  /-- Site input pins with no driver at all. -/
  undriven : List SitePin
  /-- Site input pins that X-Ray lists with no tile wire (`null` in
  `tile_type_*.json`); they connect to nothing outside the site. -/
  unwired : List SitePin
  deriving Repr, Lean.ToExpr

/-! ### Database tables -/

structure SiteInfo where
  name : String
  siteType : String
  x : Nat
  y : Nat
  pins : List (String × Option String)   -- pin, tile wire (`none`: no wire)

structure TileType where
  /-- `(dst, src, directional)` for every PIP in `tile_type_*.json`. -/
  pips : List (String × String × Bool)
  sites : List SiteInfo

abbrev Grid := Std.HashMap String (String × Int × Int)

structure Db where
  grid : Grid
  coord : Std.HashMap (Int × Int) String
  joins : Std.HashMap (String × String) (List (Int × Int × String × String))
  tileTypes : IO.Ref (Std.HashMap String TileType)
  siteDirs : IO.Ref (Std.HashMap String (List (String × String)))
  ppips : IO.Ref (Std.HashMap String (List (String × String × String)))
  root : String

def jsonObj (j : Json) (what : String) : IO (List (String × Json)) :=
  match j with
  | .obj kv => pure kv.toList
  | _ => throw (IO.userError s!"{what}: expected a JSON object")

def getAs [FromJson α] (j : Json) (k : String) : IO α :=
  IO.ofExcept ((j.getObjValAs? α k).mapError fun e => s!"key '{k}' in {j.compress.take 120}: {e}")
def getStr (j : Json) (k : String) : IO String := getAs j k
def getInt (j : Json) (k : String) : IO Int := getAs j k
def getNat (j : Json) (k : String) : IO Nat := getAs j k

def loadGrid (root device : String) : IO (Grid × Std.HashMap (Int × Int) String) := do
  let j ← IO.ofExcept (Json.parse (← IO.FS.readFile s!"{root}/{device}/tilegrid.json"))
  let mut grid : Grid := {}
  let mut coord : Std.HashMap (Int × Int) String := {}
  for (name, t) in ← jsonObj j "tilegrid" do
    let ty ← getStr t "type"
    let x ← getInt t "grid_x"
    let y ← getInt t "grid_y"
    grid := grid.insert name (ty, x, y)
    coord := coord.insert (x, y) name
  pure (grid, coord)

/-- Both directions of every `tileconn.json` rule, keyed by `(tile type, wire)`. -/
def loadJoins (root device : String) :
    IO (Std.HashMap (String × String) (List (Int × Int × String × String))) := do
  let j ← IO.ofExcept (Json.parse (← IO.FS.readFile s!"{root}/{device}/tileconn.json"))
  let rules ← IO.ofExcept j.getArr?
  let mut m : Std.HashMap (String × String) (List (Int × Int × String × String)) := {}
  for r in rules do
    let deltas ← IO.ofExcept (r.getObjValAs? (Array Int) "grid_deltas")
    let types ← IO.ofExcept (r.getObjValAs? (Array String) "tile_types")
    let pairs ← IO.ofExcept (r.getObjValAs? (Array (Array String)) "wire_pairs")
    let (dx, dy, ta, tb) ← match deltas.toList, types.toList with
      | [dx, dy], [ta, tb] => pure (dx, dy, ta, tb)
      | _, _ => throw (IO.userError "tileconn: malformed rule")
    for p in pairs do
      let (wa, wb) ← match p.toList with
        | [wa, wb] => pure (wa, wb)
        | _ => throw (IO.userError "tileconn: malformed wire pair")
      m := m.insert (ta, wa) ((dx, dy, tb, wb) :: m.getD (ta, wa) [])
      m := m.insert (tb, wb) ((-dx, -dy, ta, wa) :: m.getD (tb, wb) [])
  pure m

def Db.tileType (db : Db) (ty : String) : IO TileType := do
  if let some t := (← db.tileTypes.get).get? ty then return t
  let j ← IO.ofExcept (Json.parse (← IO.FS.readFile s!"{db.root}/tile_type_{ty}.json"))
  let pipsJ ← match j.getObjVal? "pips" with
    | .ok p => jsonObj p s!"tile_type_{ty}.pips"
    | .error _ => pure []
  let pips ← pipsJ.mapM fun (_, p) => do
    pure (← getStr p "dst_wire", ← getStr p "src_wire", (← getStr p "is_directional") == "1")
  let sitesJ ← IO.ofExcept (j.getObjValAs? (Array Json) "sites")
  let sites ← sitesJ.toList.mapM fun s => do
    let pins ← (← jsonObj (← IO.ofExcept (s.getObjVal? "site_pins")) "site_pins").mapM
      fun (pin, pj) => do
        if pj.isNull then pure (pin, none) else pure (pin, some (← getStr pj "wire"))
    pure { name := ← getStr s "name", siteType := ← getStr s "type",
           x := ← getNat s "x_coord", y := ← getNat s "y_coord", pins : SiteInfo }
  let t : TileType := { pips, sites }
  db.tileTypes.modify (·.insert ty t)
  pure t

def Db.siteDir (db : Db) (siteType pin : String) : IO String := do
  let dirs ← match (← db.siteDirs.get).get? siteType with
    | some d => pure d
    | none =>
      let j ← IO.ofExcept (Json.parse (← IO.FS.readFile s!"{db.root}/site_type_{siteType}.json"))
      let d ← (← jsonObj (← IO.ofExcept (j.getObjVal? "site_pins")) "site_pins").mapM
        fun (p, pj) => do pure (p, ← getStr pj "direction")
      db.siteDirs.modify (·.insert siteType d)
      pure d
  match dirs.lookup pin with
  | some d => pure d
  | none => throw (IO.userError s!"site type {siteType} has no pin {pin}")

/-- `(dst, src, kind)` pseudo-PIPs of a tile type. -/
def Db.ppipsOf (db : Db) (ty : String) : IO (List (String × String × String)) := do
  if let some p := (← db.ppips.get).get? ty then return p
  let path := s!"{db.root}/ppips_{ty.toLower}.db"
  let text ← if ← System.FilePath.pathExists path then IO.FS.readFile path else pure ""
  let entries ← IO.ofExcept (XRay.ppipsEntries text)
  let p ← entries.mapM fun (name, kind) => do
    match name.splitOn "." with
    | [_, dst, src] => pure (dst, src, kind)
    | _ => throw (IO.userError s!"ppips_{ty.toLower}.db: unexpected name {name}")
  db.ppips.modify (·.insert ty p)
  pure p

/-! ### Nodes and drivers -/

def Db.typeOf (db : Db) (tile : String) : IO (String × Int × Int) :=
  match db.grid.get? tile with
  | some t => pure t
  | none => throw (IO.userError s!"tile {tile} not in tilegrid")

/-- All wires joined to `(tile, wire)`, by breadth-first search over the
`tileconn.json` joins. -/
def Db.node (db : Db) (tile wire : String) : IO (List (String × String)) := do
  let mut seen : Std.HashMap (String × String) Unit := {}
  let mut todo := [(tile, wire)]
  let mut out := []
  while true do
    match todo with
    | [] => break
    | (t, w) :: rest =>
      todo := rest
      if seen.contains (t, w) then continue
      seen := seen.insert (t, w) ()
      out := (t, w) :: out
      let (ty, x, y) ← db.typeOf t
      for (dx, dy, ty', w') in db.joins.getD (ty, w) [] do
        if let some t' := db.coord.get? (x + dx, y + dy) then
          if (← db.typeOf t').1 == ty' then
            todo := (t', w') :: todo
  pure out

/-- One way a node can be driven. -/
inductive Drive where
  | site (p : SitePin)
  | pip (p : Pip)
  deriving Inhabited

/-- Enabled PIPs from the FASM, keyed by `(tile, dst)`: `(src, kind)`. -/
abbrev Enabled := Std.HashMap (String × String) (List (String × XRay.Kind))

/-- Is `src -> dst` a route-through: from an input-pin wire to an
output-pin wire of the same site? X-Ray lists the path through a site as a
pseudo-PIP; it is not routing, and the site's output pin is the driver. -/
def Db.isRouteThrough (db : Db) (ty src dst : String) : IO Bool := do
  for s in (← db.tileType ty).sites do
    let mut inSrc := false
    let mut outDst := false
    for (pin, pw) in s.pins do
      if pw == some src && (← db.siteDir s.siteType pin) == "IN" then inSrc := true
      if pw == some dst && (← db.siteDir s.siteType pin) == "OUT" then outDst := true
    if inSrc && outDst then return true
  return false

def Db.wireDrivers (db : Db) (en : Enabled) (t w : String) : IO (List Pip) := do
  let (ty, _, _) ← db.typeOf t
  let pp ← (← db.ppipsOf ty).filterM fun (d, s, _) => do
    return d != w || !(← db.isRouteThrough ty s d)
  let enabled := (en.getD (t, w) []).filter (·.2 == .bits) |>.map (·.1)
  let always := pp.filter (fun (d, _, k) => d == w && k == "always") |>.map (·.2.1)
  let primary := enabled ++ always
  if !primary.isEmpty then
    if (en.getD (t, w) []).any (·.2 == .default) then
      throw (IO.userError s!"{t}.{w}: FASM lists a default pseudo-PIP but the wire has another driver")
    return primary.map fun src => { tile := t, dst := w, src }
  let defaults := pp.filter (fun (d, _, k) => d == w && k == "default") |>.map (·.2.1)
  return defaults.map fun src => { tile := t, dst := w, src }

def Db.nodeDrivers (db : Db) (en : Enabled) (node : List (String × String)) : IO (List Drive) := do
  let mut ds := []
  for (t, w) in node do
    let (ty, _, _) ← db.typeOf t
    for s in (← db.tileType ty).sites do
      for (pin, pw) in s.pins do
        if pw == some w && (← db.siteDir s.siteType pin) == "OUT" then
          ds := .site { tile := t, site := s.name, siteType := s.siteType, x := s.x, y := s.y, pin } :: ds
    for p in ← db.wireDrivers en t w do
      ds := .pip p :: ds
  pure ds

/-- Follow drivers back from `(tile, wire)` to a site output pin. Returns
the source and the PIPs passed, or `none` if some node on the way has no
driver. -/
partial def Db.trace (db : Db) (en : Enabled) (t w : String) (visited : List (String × String))
    (pips : List Pip) : IO (Option (SitePin × List Pip)) := do
  let node ← db.node t w
  if node.any visited.contains then
    throw (IO.userError s!"{t}.{w}: routing loop")
  match ← db.nodeDrivers en node with
  | [] => pure none
  | [.site p] => pure (some (p, pips))
  | [.pip p] => db.trace en p.tile p.src (node ++ visited) (p :: pips)
  | ds =>
    let show1 : Drive → String
      | .site p => s!"site pin {p.tile}/{p.site}.{p.pin}"
      | .pip p => s!"PIP {p.tile}.{p.dst}.{p.src}"
    throw (IO.userError s!"{t}.{w}: node has {ds.length} drivers: {", ".intercalate (ds.map show1)}")

/-! ### The whole design -/

/-- Wire the design: trace every input pin of every site in the FASM's tiles,
then check that every FASM PIP was used. `pipFeatures` are the FASM features
that are PIPs, as `(tile, dst, src, kind)`. -/
def route (root device : String) (tiles : List String)
    (pipFeatures : List (String × String × String × XRay.Kind)) : IO Routing := do
  let (grid, coord) ← loadGrid root device
  let joins ← loadJoins root device
  let db : Db := { grid, coord, joins, root, tileTypes := ← IO.mkRef {},
                   siteDirs := ← IO.mkRef {}, ppips := ← IO.mkRef {} }
  let mut en : Enabled := {}
  for (t, dst, src, k) in pipFeatures do
    en := en.insert (t, dst) ((src, k) :: en.getD (t, dst) [])
  let mut conns := []
  let mut undriven := []
  let mut unwired := []
  for t in tiles do
    let (ty, _, _) ← db.typeOf t
    for s in (← db.tileType ty).sites do
      for (pin, pw) in s.pins do
        if (← db.siteDir s.siteType pin) != "IN" then continue
        let input : SitePin := { tile := t, site := s.name, siteType := s.siteType, x := s.x, y := s.y, pin }
        let some w := pw
          | unwired := input :: unwired; continue
        match ← db.trace en t w [] [] with
        | some (source, pips) => conns := { input, source, pips } :: conns
        | none => undriven := input :: undriven
  -- Every FASM PIP must be on some traced path.
  let used : Std.HashMap Pip Unit :=
    conns.foldl (fun m c => c.pips.foldl (fun m p => m.insert p ()) m) {}
  for (t, dst, src, _) in pipFeatures do
    unless used.contains { tile := t, dst, src } do
      throw (IO.userError s!"{t}.{dst}.{src}: enabled in the FASM but on no traced path")
  pure { conns := conns.reverse, undriven := undriven.reverse, unwired := unwired.reverse }

/-- Split the resolved FASM features into PIPs and the rest. A feature
`DST.SRC` is a PIP if its tile type has a PIP or pseudo-PIP from `SRC` to
`DST` (in either orientation for a bidirectional PIP). -/
def splitPips (root : String) (feats : List XRay.Feature) :
    IO (List (String × String × String × XRay.Kind) × List XRay.Feature) := do
  let types ← IO.mkRef ({} : Std.HashMap String (List (String × String)))
  let pipsOf (ty : String) : IO (List (String × String)) := do
    if let some p := (← types.get).get? ty then return p
    let j ← IO.ofExcept (Json.parse (← IO.FS.readFile s!"{root}/tile_type_{ty}.json"))
    let pipsJ ← match j.getObjVal? "pips" with
      | .ok p => jsonObj p s!"tile_type_{ty}.pips"
      | .error _ => pure []
    let mut ps := []
    for (_, p) in pipsJ do
      let d ← getStr p "dst_wire"
      let s ← getStr p "src_wire"
      ps := (d, s) :: ps
      if (← getStr p "is_directional") != "1" then ps := (s, d) :: ps
    let path := s!"{root}/ppips_{ty.toLower}.db"
    let text ← if ← System.FilePath.pathExists path then IO.FS.readFile path else pure ""
    for (name, _) in ← IO.ofExcept (XRay.ppipsEntries text) do
      if let [_, d, s] := name.splitOn "." then ps := (d, s) :: ps
    types.modify (·.insert ty ps)
    pure ps
  let mut pips := []
  let mut rest := []
  for f in feats do
    match f.feature.splitOn "." with
    | [dst, src] =>
      if (← pipsOf f.tileType).contains (dst, src) then
        pips := (f.tile, dst, src, f.kind) :: pips
      else rest := f :: rest
    | _ => rest := f :: rest
  pure (pips.reverse, rest.reverse)

end VeryFPGA.Route

namespace VeryFPGA

open Lean Elab Command in
/-- `route_fasm foo from feats xray "<family dir>" "<die>"` computes the
physical wiring of the resolved FASM features `feats` (defined by
`load_fasm`) at build time and defines `foo : Route.Routing`. Any routing
error stops the build.

Site naming note for the site models: the `site` and `x`/`y` fields are the
tile-local names from `tile_type_*.json`. FASM names sites differently
(`IOB_Y0`, `ILOGIC_Y0`, `SLICEL_X0`), following prjxray's rule on *global*
site coordinates; for example in `LIOB33_X0Y25` the tile-local `X0Y1` site
is global `IOB_X0Y26`, which FASM calls `IOB_Y0`. -/
elab "route_fasm " id:ident " from " src:ident " xray " fam:str dev:str : command => do
  let some dbRoot ← IO.getEnv "PRJXRAY_DB_DIR"
    | throwError "route_fasm: PRJXRAY_DB_DIR is not set (source env.sh)"
  let srcName ← liftCoreM <| realizeGlobalConstNoOverloadWithInfo src
  let feats ← unsafe evalConst (List XRay.Feature) srcName
  let root := s!"{dbRoot}/{fam.getString}"
  let (pips, _) ← Route.splitPips root feats
  let tiles := (feats.map (·.tile)).eraseDups
  let routing ← try Route.route root dev.getString tiles pips
    catch e => throwError "routing rejected: {e.toMessageData}"
  let name := (← getCurrNamespace) ++ id.getId
  liftCoreM do
    addAndCompile <| .defnDecl {
      name, levelParams := [], type := mkConst ``Route.Routing, value := toExpr routing,
      hints := .regular 0, safety := .safe }
    enableRealizationsForConst name

end VeryFPGA

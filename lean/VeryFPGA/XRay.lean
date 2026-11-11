/-
Project X-Ray database access, and resolution of FASM features against it.

For each FASM line this checks that the feature exists in the X-Ray database
for that tile, and classifies it:
- `bits`: backed by configuration bits (an entry in `segbits_<type>.db`);
- `always`: a pseudo-PIP marked `always` in `ppips_<type>.db`, a hard-wired
  connection with no configuration bits;
- `default`: a pseudo-PIP marked `default`, a connection that holds when
  nothing else drives the wire, also without bits.
Any other feature, a `hint` pseudo-PIP, or a duplicate line is a hard error.

Single-site tiles (`*_SING`) use the segbits of an alias tile type, with a
site renaming, as recorded in `tilegrid.json`; this follows prjxray's
`tile_segbits_alias.py`.

Trusted: the database files, and that this code reads them as prjxray does.
-/
import Lean
import VeryFPGA.Fasm

open Lean

namespace VeryFPGA.XRay

inductive Kind where
  | bits
  | always
  | default
  deriving Repr, BEq, DecidableEq, Lean.ToExpr

/-- A FASM line checked against the database. `tileType` is the tile's own
type; `bits` as in `Fasm.Line`. -/
structure Feature where
  tile : String
  tileType : String
  feature : String
  kind : Kind
  bits : List (Nat × Bool)
  deriving Repr, Lean.ToExpr

structure Alias where
  tileType : String
  sites : List (String × String)
  deriving Repr

structure TileInfo where
  tileType : String
  alias : Option Alias
  deriving Repr

/-- What the resolver needs from the database, for the tiles a design uses. -/
structure Db where
  tiles : List (String × TileInfo)
  segbits : List (String × List String)
  ppips : List (String × List (String × String))
  deriving Repr

abbrev P := Except String

def jsonObj (j : Json) (what : String) : P (List (String × Json)) :=
  match j with
  | .obj kv => pure kv.toList
  | _ => throw s!"{what}: expected a JSON object"

/-- Tile type and alias from one `tilegrid.json` entry. All bit blocks of a
tile must agree on the alias. -/
def tileInfo (name : String) (j : Json) : P TileInfo := do
  let tileType ← (← j.getObjVal? "type").getStr?
  let blocks ← match j.getObjVal? "bits" with
    | .ok b => jsonObj b s!"tile {name}.bits"
    | .error _ => pure []
  let aliases ← blocks.filterMapM fun (_, blk) => do
    match blk.getObjVal? "alias" with
    | .error _ => pure none
    | .ok a =>
      let t ← (← a.getObjVal? "type").getStr?
      let sites ← (← jsonObj (← a.getObjVal? "sites") s!"tile {name} alias sites").mapM
        fun (k, v) => do pure (k, ← v.getStr?)
      pure (some ({ tileType := t, sites } : Alias))
  match aliases with
  | [] => pure { tileType, alias := none }
  | a :: rest =>
    unless rest.all (fun b => b.tileType == a.tileType && b.sites == a.sites) do
      throw s!"tile {name}: bit blocks disagree on the alias"
    pure { tileType, alias := some a }

/-- First word of every non-empty line of a `segbits_*.db` file. -/
def segbitsNames (text : String) : List String :=
  (text.splitOn "\n").filterMap fun l =>
    match (l.splitOn " ").filter (· ≠ "") with
    | name :: _ => some name
    | [] => none

/-- `(feature, kind)` from a `ppips_*.db` file. -/
def ppipsEntries (text : String) : P (List (String × String)) :=
  (text.splitOn "\n").filterMapM fun l =>
    match (l.splitOn " ").filter (· ≠ "") with
    | [] => pure none
    | [name, kind] => pure (some (name, kind))
    | _ => throw s!"malformed ppips line: {l}"

/-- Read the database files needed for the given tiles. `root` is the
family directory (e.g. `.../prjxray-db/spartan7`), `device` the die
(e.g. `xc7s50`). Missing segbits or ppips files mean "no entries". -/
def load (root device : String) (tiles : List String) : IO Db := do
  let gridText ← IO.FS.readFile s!"{root}/{device}/tilegrid.json"
  let grid ← IO.ofExcept (Json.parse gridText)
  let tileInfos ← tiles.mapM fun t => do
    let j ← IO.ofExcept (grid.getObjVal? t |>.mapError (s!"tile {t} not in tilegrid: " ++ ·))
    pure (t, ← IO.ofExcept (tileInfo t j))
  let ownTypes := tileInfos.map (·.2.tileType) |>.eraseDups
  let segTypes := (tileInfos.map fun (_, i) => (i.alias.map (·.tileType)).getD i.tileType).eraseDups
  let readOpt (path : String) : IO String := do
    if ← System.FilePath.pathExists path then IO.FS.readFile path else pure ""
  let segbits ← segTypes.mapM fun ty => do
    pure (ty, segbitsNames (← readOpt s!"{root}/segbits_{ty.toLower}.db"))
  let ppips ← ownTypes.mapM fun ty => do
    pure (ty, ← IO.ofExcept (ppipsEntries (← readOpt s!"{root}/ppips_{ty.toLower}.db")))
  pure { tiles := tileInfos, segbits, ppips }

/-- Bit index as X-Ray writes it: zero-padded to the digit count of `hi`. -/
def indexName (hi i : Nat) : String :=
  let width := (toString hi).length
  let s := toString i
  "".pushn '0' (width - s.length) ++ s

def resolve (db : Db) (l : Fasm.Line) : P Feature := do
  let what := s!"{l.tile}.{l.feature}"
  let some info := db.tiles.lookup l.tile | throw s!"{what}: unknown tile"
  let own := info.tileType
  let ppips := (db.ppips.lookup own).getD []
  -- Name of the feature in the segbits file: alias type, renamed site.
  let (segType, segFeature) := match info.alias with
    | none => (own, l.feature)
    | some a =>
      match l.feature.splitOn "." with
      | site :: rest =>
        let site' := (a.sites.lookup site).getD site
        (a.tileType, ".".intercalate (site' :: rest))
      | [] => (a.tileType, l.feature)
  let seg := (db.segbits.lookup segType).getD []
  let mk (kind : Kind) : Feature :=
    { tile := l.tile, tileType := own, feature := l.feature, kind, bits := l.bits }
  if l.bits.isEmpty then
    match ppips.lookup s!"{own}.{l.feature}" with
    | some "always" => return mk .always
    | some "default" => return mk .default
    | some k => throw s!"{what}: pseudo-PIP of kind '{k}' is not supported"
    | none =>
      unless seg.contains s!"{segType}.{segFeature}" do
        throw s!"{what}: not in segbits_{segType.toLower}.db or ppips_{own.toLower}.db"
      return mk .bits
  else
    for (i, _) in l.bits do
      let name := s!"{segType}.{segFeature}[{indexName l.hi i}]"
      unless seg.contains name do
        throw s!"{what}: bit {name} not in segbits_{segType.toLower}.db"
    return mk .bits

/-- Resolve every line; the same tile and feature may not appear twice. -/
def resolveAll (db : Db) (lines : List Fasm.Line) : P (List Feature) := do
  let keys := lines.map fun l => (l.tile, l.feature)
  for (k, i) in keys.zipIdx do
    if keys.drop (i + 1) |>.contains k then
      throw s!"{k.1}.{k.2}: appears more than once"
  lines.mapM (resolve db)

end VeryFPGA.XRay

namespace VeryFPGA

open Lean Elab Command in
/-- `load_fasm foo from "design.fasm" db "<family dir>" device "<die>"` parses
the FASM file at build time, resolves every feature against the X-Ray
database and defines `foo : List XRay.Feature`. Any error stops the build.
A relative `db` path is taken relative to `$PRJXRAY_DB_DIR`. -/
elab "load_fasm " id:ident " from " path:str " db " fam:str " device " dev:str : command => do
  let some dbRoot ← IO.getEnv "PRJXRAY_DB_DIR"
    | throwError "load_fasm: PRJXRAY_DB_DIR is not set (source env.sh)"
  let lines ← match Fasm.parse (← IO.FS.readFile path.getString) with
    | .ok ls => pure ls
    | .error e => throwError "FASM rejected: {e}"
  let tiles := (lines.map (·.tile)).eraseDups
  let db ← XRay.load s!"{dbRoot}/{fam.getString}" dev.getString tiles
  let feats ← match XRay.resolveAll db lines with
    | .ok fs => pure fs
    | .error e => throwError "FASM rejected: {e}"
  let name := (← getCurrNamespace) ++ id.getId
  liftCoreM do
    addAndCompile <| .defnDecl {
      name, levelParams := [], type := toTypeExpr (List XRay.Feature), value := toExpr feats,
      hints := .regular 0, safety := .safe }
    enableRealizationsForConst name

end VeryFPGA

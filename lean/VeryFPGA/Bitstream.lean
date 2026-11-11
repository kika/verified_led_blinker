/-
Reading a 7-series `.bit` file and decoding its configuration bits into
X-Ray features (M4b).

Steps, each with hard errors:
1. Header: the part name field must be the expected part.
2. Packets after the sync word `0xAA995566` (AMD UG470, chapter 5): type 1
   and type 2 packets. Only writes to an allow-list of registers; no reads.
   `IDCODE` must be written with the part's IDCODE (from `part.json`),
   `FAR` with 0, and `CMD` with WCFG (1) before the one and only frame data
   write (`FDRI`).
3. Frames: the frame data is split into frames of 101 words. Frame
   addresses follow the device's auto-increment order from `part.json`:
   block type (CLB_IO_CLK, then BLOCK_RAM), half (top, then bottom), row,
   column, minor frame, with two padding frames after each row. The frame
   count must match exactly; padding frames must be zero.
4. ECC: bits 12..0 of word 50 of every frame hold the frame's ECC check
   bits, written by `xc7frames2bit`; they are not configuration and are
   excluded. No X-Ray feature may use them (checked).
5. Features: in every tile that has a set bit, a feature is present if all
   its positive bits are 1 and all its negative bits are 0 (prjxray
   `tile_segbits.py`, `match_bitdata`). Only features with at least one
   positive bit are emitted: a feature made of negative bits only (e.g.
   `NOCLKINV`) holds in every unconfigured tile and carries no information.
   Single-site tiles use their alias type's segbits, as in M4a.1.
6. Every set configuration bit must be a positive bit of some emitted
   feature. BLOCK_RAM frames must be all zero (block RAM is not modelled).

The result has the same type as `load_fasm`'s: a list of `XRay.Feature`,
bit-backed, with multi-bit features (`ALUT.INIT`) reassembled.

Trusted, like the other readers. Configuration registers other than the
ones checked here (`COR0`, `COR1`, `CTL0`, `CTL1`, `MASK`, `TIMER`, `WBSTAR`)
are recorded but not interpreted.
-/
import Lean
import Std.Data.HashMap
import VeryFPGA.XRay
import VeryFPGA.Route

open Lean

namespace VeryFPGA.Bitstream

def frameWords : Nat := 101
def eccWord : Nat := 50
def eccMask : UInt32 := 0x1FFF

/-! ### Header and packets -/

def u16 (b : ByteArray) (i : Nat) : Nat := b[i]!.toNat * 256 + b[i+1]!.toNat
def u32 (b : ByteArray) (i : Nat) : UInt32 :=
  (b[i]!.toUInt32 <<< 24) ||| (b[i+1]!.toUInt32 <<< 16) ||| (b[i+2]!.toUInt32 <<< 8) ||| b[i+3]!.toUInt32

/-- Header fields `(key, value)` and the offset of the configuration data.
Layout: a 2-byte length and that many bytes, a 2-byte length (1), then
fields `a`..`d` (key byte, 2-byte length, bytes) and `e` (key byte, 4-byte
length of the configuration data). -/
def header (b : ByteArray) : Except String (List (Char × String) × Nat × Nat) := do
  if b.size < 16 then throw "file too short"
  let n0 := u16 b 0
  let mut i := 2 + n0
  unless u16 b i == 1 do throw "unexpected header"
  i := i + 2
  let mut fields := []
  for _ in [0:4] do
    let key := Char.ofNat b[i]!.toNat
    let len := u16 b (i + 1)
    let bytes := (b.extract (i + 3) (i + 3 + len)).toList.filter (· != 0)
    fields := (key, String.ofList (bytes.map fun x => Char.ofNat x.toNat)) :: fields
    i := i + 3 + len
  unless Char.ofNat b[i]!.toNat == 'e' do throw "header field e missing"
  let dataLen := (u32 b (i + 1)).toNat
  let start := i + 5
  unless start + dataLen == b.size do throw "configuration length does not match the file size"
  pure (fields.reverse, start, dataLen)

/-- Configuration registers (UG470 table 5-23). -/
def regName : Nat → String
  | 0 => "CRC" | 1 => "FAR" | 2 => "FDRI" | 3 => "FDRO" | 4 => "CMD" | 5 => "CTL0"
  | 6 => "MASK" | 7 => "STAT" | 8 => "LOUT" | 9 => "COR0" | 10 => "MFWR" | 11 => "CBC"
  | 12 => "IDCODE" | 13 => "AXSS" | 14 => "COR1" | 16 => "WBSTAR" | 17 => "TIMER"
  | 19 => "RBCRC_SW" | 22 => "BOOTSTS" | 24 => "CTL1" | 31 => "BSPI" | n => s!"reg{n}"

/-- Registers this reader accepts writes to. -/
def allowedRegs : List String :=
  ["FAR", "FDRI", "CMD", "CTL0", "MASK", "COR0", "IDCODE", "COR1", "WBSTAR", "TIMER",
   "RBCRC_SW", "CTL1"]

/-- The writes of the packet stream after the sync word, as
`(register, words)` in order; the frame data is the `FDRI` write. -/
def packets (b : ByteArray) (start len : Nat) : Except String (List (String × Array UInt32)) := do
  -- find the sync word
  let mut i := start
  let stop := start + len
  while i + 4 ≤ stop && u32 b i != 0xAA995566 do i := i + 1
  if i + 4 > stop then throw "no sync word"
  i := i + 4
  let mut out := []
  let mut lastReg := 0
  while i + 4 ≤ stop do
    let h := u32 b i
    i := i + 4
    let ty := (h >>> 29).toNat
    let op := ((h >>> 27) &&& 3).toNat
    if ty == 1 then
      let reg := ((h >>> 13) &&& 0x1F).toNat
      let cnt := (h &&& 0x7FF).toNat
      lastReg := reg
      if op == 0 then
        unless cnt == 0 do throw "NOP packet with data"
        continue
      unless op == 2 do throw s!"type 1 packet with opcode {op} (only writes are accepted)"
      unless i + 4 * cnt ≤ stop do throw "packet runs past the end"
      let words := (List.range cnt).toArray.map fun k => u32 b (i + 4 * k)
      i := i + 4 * cnt
      out := (regName reg, words) :: out
    else if ty == 2 then
      unless op == 2 do throw s!"type 2 packet with opcode {op}"
      let cnt := (h &&& 0x7FFFFFF).toNat
      unless i + 4 * cnt ≤ stop do throw "packet runs past the end"
      let words := (List.range cnt).toArray.map fun k => u32 b (i + 4 * k)
      i := i + 4 * cnt
      out := (regName lastReg, words) :: out
    else throw s!"packet header {h} is neither type 1 nor type 2"
  let ws := out.reverse
  for (r, _) in ws do
    unless allowedRegs.contains r do throw s!"write to register {r} is not accepted"
  pure (ws.filter fun (r, w) => !(r == "FDRI" && w.isEmpty))

/-! ### Frame addresses -/

/-- The frame addresses in auto-increment order, `none` for a padding frame. -/
def frameOrder (part : Json) : Except String (List (Option Nat)) := do
  let gcr ← part.getObjVal? "global_clock_regions"
  let mut out := []
  for (bt, btName) in [(0, "CLB_IO_CLK"), (1, "BLOCK_RAM")] do
    for (hb, half) in [(0, "top"), (1, "bottom")] do
      let rows ← match (← gcr.getObjVal? half).getObjVal? "rows" with
        | .ok (.obj kv) => pure kv.toList
        | _ => throw s!"part.json: no rows in {half}"
      let rows := (rows.filterMap fun (r, v) => r.toNat?.map (·, v)).mergeSort (·.1 ≤ ·.1)
      for (r, row) in rows do
        match (← row.getObjVal? "configuration_buses").getObjVal? btName with
        | .error _ => continue
        | .ok bus =>
          let cols ← match bus.getObjVal? "configuration_columns" with
            | .ok (.obj kv) => pure kv.toList
            | _ => throw "part.json: no columns"
          let cols := (cols.filterMap fun (c, v) => c.toNat?.map (·, v)).mergeSort (·.1 ≤ ·.1)
          for (c, col) in cols do
            let n ← col.getObjValAs? Nat "frame_count"
            for m in List.range n do
              out := some (bt * 2^23 + hb * 2^22 + r * 2^17 + c * 2^7 + m) :: out
          out := none :: none :: out
  pure out.reverse

/-! ### Segbits -/

/-- A segbits entry: `(frame offset, bit index within the tile, value)`. -/
abbrev SegBit := Nat × Nat × Bool

def parseSegBit (s : String) : Except String SegBit := do
  let (neg, body) := if s.startsWith "!" then (true, (s.drop 1).toString) else (false, s)
  match body.splitOn "_" with
  | [f, b] =>
    match f.toNat?, b.toNat? with
    | some f, some b => pure (f, b, !neg)
    | _, _ => throw s!"bad segbit {s}"
  | _ => throw s!"bad segbit {s}"

def readSegbits (path : String) : IO (List (String × List SegBit)) := do
  if !(← System.FilePath.pathExists path) then return []
  let text ← IO.FS.readFile path
  (text.splitOn "\n").filterMapM fun l => do
    match (l.splitOn " ").filter (· ≠ "") with
    | [] => pure none
    | name :: bits => pure (some (name, ← IO.ofExcept (bits.mapM parseSegBit)))

/-- Tile bit layout from `tilegrid.json` (CLB_IO_CLK block). -/
structure TileBits where
  tile : String
  tileType : String
  base : Nat
  frames : Nat
  offset : Nat
  words : Nat
  alias : Option XRay.Alias
  startOffset : Nat
  deriving Inhabited

def hex (s : String) : Option Nat :=
  let s := if s.startsWith "0x" then (s.drop 2).toString else s
  s.toList.foldlM (fun acc c =>
    if c.isDigit then some (acc * 16 + (c.toNat - '0'.toNat))
    else if 'a' ≤ c && c ≤ 'f' then some (acc * 16 + (c.toNat - 'a'.toNat + 10))
    else if 'A' ≤ c && c ≤ 'F' then some (acc * 16 + (c.toNat - 'A'.toNat + 10))
    else none) 0

/-! ### Decoding -/

structure Result where
  features : List XRay.Feature
  /-- register writes other than the frame data, for the record -/
  registers : List (String × List Nat)
  setBits : Nat
  deriving Repr

def decode (root device part : String) (path : String) : IO Result := do
  let b ← IO.FS.readBinFile path
  let (fields, start, len) ← IO.ofExcept (header b)
  match fields.lookup 'b' with
  | some p => unless p == part do throw (IO.userError s!"bitstream is for part {p}, expected {part}")
  | none => throw (IO.userError "bitstream header has no part field")
  let partJ ← IO.ofExcept (Json.parse (← IO.FS.readFile s!"{root}/{part}/part.json"))
  let idcode ← IO.ofExcept (partJ.getObjValAs? Nat "idcode")
  let writes ← IO.ofExcept (packets b start len)
  -- the frame data write and what must precede it
  let some fdriIdx := writes.findIdx? (·.1 == "FDRI")
    | throw (IO.userError "no frame data (FDRI) write")
  unless (writes.filter (·.1 == "FDRI")).length == 1 do
    throw (IO.userError "more than one FDRI write")
  let before := writes.take fdriIdx
  unless before.any (fun (r, w) => r == "IDCODE" && w.toList.map (·.toNat) == [idcode]) do
    throw (IO.userError s!"IDCODE {idcode} not written before the frame data")
  unless (before.filter (·.1 == "FAR")).getLast?.map (·.2.toList) == some [0] do
    throw (IO.userError "FAR is not 0 before the frame data")
  unless (before.filter (·.1 == "CMD")).getLast?.map (·.2.toList) == some [1] do
    throw (IO.userError "the last command before the frame data is not WCFG")
  -- A FAR write after the frame data (the startup sequence parks it at an
  -- unused address) writes no frames: FDRI is written exactly once and MFWR
  -- (multi-frame write) is not an accepted register.
  let data := writes[fdriIdx]!.2
  let order ← IO.ofExcept (frameOrder partJ)
  unless data.size == frameWords * order.length do
    throw (IO.userError s!"{data.size} frame data words, expected {frameWords * order.length}")
  -- set configuration bits, by frame address: (word index * 32 + bit)
  let mut setBits : Std.HashMap Nat (List Nat) := {}
  let mut total := 0
  for (addr?, n) in order.zipIdx do
    for w in List.range frameWords do
      let v := data[frameWords * n + w]!
      let v := if w == eccWord then v &&& ~~~eccMask else v
      if v == 0 then continue
      match addr? with
      | none => throw (IO.userError s!"padding frame {n} is not zero")
      | some a =>
        if a ≥ 2^23 then throw (IO.userError s!"block RAM frame {a} is not zero")
        for k in List.range 32 do
          if (v >>> k.toUInt32) &&& 1 == 1 then
            setBits := setBits.insert a ((w * 32 + k) :: setBits.getD a [])
            total := total + 1
  -- tiles and which (frame, word) they own
  let grid ← IO.ofExcept (Json.parse (← IO.FS.readFile s!"{root}/{device}/tilegrid.json"))
  let tilesJ ← match grid with
    | .obj kv => pure kv.toList
    | _ => throw (IO.userError "tilegrid: expected an object")
  let mut tiles : Array TileBits := #[]
  let mut owner : Std.HashMap (Nat × Nat) (List Nat) := {}
  for (name, tj) in tilesJ do
    let some blk := (tj.getObjVal? "bits" >>= (·.getObjVal? "CLB_IO_CLK")).toOption | continue
    let ty ← IO.ofExcept (tj.getObjValAs? String "type")
    let some base := hex (← IO.ofExcept (blk.getObjValAs? String "baseaddr"))
      | throw (IO.userError s!"{name}: bad baseaddr")
    let frames ← IO.ofExcept (blk.getObjValAs? Nat "frames")
    let offset ← IO.ofExcept (blk.getObjValAs? Nat "offset")
    let words ← IO.ofExcept (blk.getObjValAs? Nat "words")
    let (alias, startOffset) ← match blk.getObjVal? "alias" with
      | .error _ => pure (none, 0)
      | .ok a =>
        let t ← IO.ofExcept (a.getObjValAs? String "type")
        let so ← IO.ofExcept (a.getObjValAs? Nat "start_offset")
        let sites ← match a.getObjVal? "sites" with
          | .ok (.obj kv) => kv.toList.mapM fun (k, v) => do pure (k, ← IO.ofExcept v.getStr?)
          | _ => pure []
        pure (some ({ tileType := t, sites } : XRay.Alias), so)
    let idx := tiles.size
    tiles := tiles.push { tile := name, tileType := ty, base, frames, offset, words, alias, startOffset }
    for f in List.range frames do
      for w in List.range words do
        owner := owner.insert (base + f, offset + w) (idx :: owner.getD (base + f, offset + w) [])
  -- tiles with at least one set bit
  let mut touched : Std.HashMap Nat Unit := {}
  for (a, bits) in setBits.toList do
    for bit in bits do
      match owner.get? (a, bit / 32) with
      | some ts => for t in ts do touched := touched.insert t ()
      | none => throw (IO.userError s!"set bit {bit} of frame {a} belongs to no tile")
  let isSet (a bit : Nat) : Bool := (setBits.getD a []).contains bit
  let segCache ← IO.mkRef ({} : Std.HashMap String (List (String × List SegBit)))
  let mut explained : Std.HashMap (Nat × Nat) Unit := {}
  let mut feats : List XRay.Feature := []
  for (t, _) in touched.toList do
    let tb := tiles[t]!
    let segType := (tb.alias.map (·.tileType)).getD tb.tileType
    let seg ← match (← segCache.get).get? segType with
      | some s => pure s
      | none =>
        let s ← readSegbits s!"{root}/segbits_{segType.toLower}.db"
        segCache.modify (·.insert segType s)
        pure s
    let wordOffset := tb.offset - tb.startOffset
    let mut words : List (String × List (Nat × Bool)) := []
    for (name, bits) in seg do
      -- no feature may use the ECC bits
      for (_, bit, _) in bits do
        if wordOffset + bit / 32 == eccWord && bit % 32 < 13 then
          throw (IO.userError s!"{name} uses ECC bit {bit} of tile {tb.tile}")
      -- bits outside the alias's word range are not this tile's (prjxray match_filter)
      if bits.any fun (_, bit, _) => bit / 32 < tb.startOffset || bit / 32 - tb.startOffset ≥ tb.words then
        continue
      if !bits.any (·.2.2) then continue
      let isMatch := bits.all fun (f, bit, v) => isSet (tb.base + f) (wordOffset * 32 + bit) == v
      if !isMatch then continue
      for (f, bit, v) in bits do
        if v then explained := explained.insert (tb.base + f, wordOffset * 32 + bit) ()
      -- feature name without the tile type, alias site renamed back
      let parts := name.splitOn "."
      let rest := match parts.drop 1, tb.alias with
        | site :: more, some a =>
          let rev := (a.sites.map fun (k, v) => (v, k)).lookup site
          (rev.getD site) :: more
        | ps, _ => ps
      let fname := ".".intercalate rest
      -- `NAME[i]`: one bit of a multi-bit feature
      match fname.splitOn "[" with
      | [base, idx] =>
        let some i := (idx.dropEnd 1).toString.toNat? | throw (IO.userError s!"bad index in {name}")
        words := (base, (i, true) :: (words.lookup base).getD []) :: words.filter (·.1 != base)
      | _ =>
        feats := { tile := tb.tile, tileType := tb.tileType, feature := fname, kind := .bits,
                   bits := [] } :: feats
    -- reassemble multi-bit features: every index the database knows, 0 where unset
    for (base, ones) in words do
      let known := seg.filterMap fun (n, _) =>
        match ((".".intercalate ((n.splitOn ".").drop 1))).splitOn "[" with
        | [b, idx] => if b == base || ((b.splitOn ".").drop 1 == (base.splitOn ".").drop 1 &&
            tb.alias.isSome) then (idx.dropEnd 1).toString.toNat? else none
        | _ => none
      let hi := known.foldl max 0
      let bits := (List.range (hi + 1)).reverse.map fun i => (i, (ones.lookup i).isSome)
      feats := { tile := tb.tile, tileType := tb.tileType, feature := base, kind := .bits, bits } :: feats
  -- every set bit explained
  let mut unexplained := []
  for (a, bits) in setBits.toList do
    for bit in bits do
      unless explained.contains (a, bit) do unexplained := (a, bit) :: unexplained
  unless unexplained.isEmpty do
    let show1 := unexplained.take 5 |>.map fun (a, bit) => s!"frame {a} word {bit / 32} bit {bit % 32}"
    throw (IO.userError s!"{unexplained.length} set bits explained by no feature, e.g. {show1}")
  let registers := (writes.filter (·.1 != "FDRI")).map fun (r, w) => (r, w.toList.map (·.toNat))
  pure { features := feats.reverse, registers, setBits := total }

end VeryFPGA.Bitstream

namespace VeryFPGA

open Lean Elab Command in
/-- `load_bit foo from "design.bit" xray "<family>" "<die>" "<part>"` decodes a
bitstream at build time into X-Ray features (same type as `load_fasm`) and
defines `foo`. Any error stops the build. -/
elab "load_bit " id:ident " from " path:str " xray " fam:str dev:str part:str : command => do
  let some dbRoot ← IO.getEnv "PRJXRAY_DB_DIR"
    | throwError "load_bit: PRJXRAY_DB_DIR is not set (source env.sh)"
  let r ← try Bitstream.decode s!"{dbRoot}/{fam.getString}" dev.getString part.getString path.getString
    catch e => throwError "bitstream rejected: {e.toMessageData}"
  let name := (← getCurrNamespace) ++ id.getId
  liftCoreM do
    addAndCompile <| .defnDecl {
      name, levelParams := [], type := toTypeExpr (List XRay.Feature), value := toExpr r.features,
      hints := .regular 0, safety := .safe }
    enableRealizationsForConst name

end VeryFPGA

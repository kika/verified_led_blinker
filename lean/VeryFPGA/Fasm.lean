/-
FASM (FPGA Assembly) parser.

A FASM file lists enabled features, one per line:
  `TILE.FEATURE`                      the feature is on (value 1)
  `TILE.FEATURE[hi:lo] = W'bVALUE`    a multi-bit feature, e.g. a LUT INIT
`#` starts a comment line. Only these forms are accepted; anything else
(other number bases, single-bit indexing, annotations in braces, trailing
comments) is a hard error, because a form we do not read is a feature we
might silently drop.

Trusted, like the JSON parser of M3.
-/
namespace VeryFPGA.Fasm

/-- One FASM line. `bits` is empty for a plain feature; for
`NAME[hi:lo] = W'b...` it lists `(index, value)` for every bit, so
`bits` holds bit `hi` first (the binary literal is written MSB first). -/
structure Line where
  tile : String
  feature : String
  hi : Nat
  lo : Nat
  bits : List (Nat × Bool)
  deriving Repr, BEq

abbrev P := Except String

def isIdentChar (c : Char) : Bool :=
  c.isAlphanum || c == '_'

/-- `TILE` is everything before the first `.`; it must look like
`NAME_X<n>Y<n>`, the X-Ray tile naming. -/
def splitTile (s : String) (what : String) : P (String × String) := do
  match s.splitOn "." with
  | tile :: rest@(_ :: _) =>
    unless tile.all isIdentChar && (tile.splitOn "_X").length ≥ 2 do
      throw s!"{what}: '{tile}' is not a tile name"
    pure (tile, ".".intercalate rest)
  | _ => throw s!"{what}: missing '.' between tile and feature"

def parseNat (s : String) (what : String) : P Nat :=
  match s.toNat? with
  | some n => pure n
  | none => throw s!"{what}: '{s}' is not a number"

/-- `NAME[hi:lo]` -> `(NAME, hi, lo)`. -/
def parseRange (s : String) (what : String) : P (String × Nat × Nat) := do
  match s.splitOn "[" with
  | [name, rng] =>
    unless rng.endsWith "]" do throw s!"{what}: malformed range"
    match (rng.dropEnd 1).toString.splitOn ":" with
    | [h, l] =>
      let hi ← parseNat h what
      let lo ← parseNat l what
      unless lo ≤ hi do throw s!"{what}: range [{hi}:{lo}] is reversed"
      pure (name, hi, lo)
    | _ => throw s!"{what}: only [hi:lo] ranges are supported"
  | _ => throw s!"{what}: malformed range"

/-- `W'bDDDD` -> list of bits, MSB first; the width must equal the digit count. -/
def parseBinary (s : String) (what : String) : P (List Bool) := do
  match s.splitOn "'b" with
  | [w, digits] =>
    let width ← parseNat w what
    let bs ← digits.toList.mapM fun
      | '0' => pure false
      | '1' => pure true
      | c => throw s!"{what}: '{c}' is not a binary digit"
    unless bs.length == width do
      throw s!"{what}: literal has {bs.length} digits, width says {width}"
    pure bs
  | _ => throw s!"{what}: only W'b binary values are supported"

def parseLine (lineNo : Nat) (raw : String) : P (Option Line) := do
  let what := s!"FASM line {lineNo}"
  let s := raw.trimAscii.toString
  if s.isEmpty || s.startsWith "#" then return none
  if s.contains '#' || s.contains '{' then
    throw s!"{what}: trailing comments and annotations are not supported"
  match s.splitOn "=" with
  | [lhs] =>
    if lhs.contains ' ' || lhs.contains '[' then
      throw s!"{what}: a plain feature must be a single word without a range"
    let (tile, feature) ← splitTile lhs what
    return some { tile, feature, hi := 0, lo := 0, bits := [] }
  | [lhs, rhs] =>
    let (tile, rest) ← splitTile lhs.trimAscii.toString what
    let (feature, hi, lo) ← parseRange rest what
    let value ← parseBinary rhs.trimAscii.toString what
    unless value.length == hi - lo + 1 do
      throw s!"{what}: value width {value.length} does not match [{hi}:{lo}]"
    -- `List.range n` is `[0, ..., n-1]`; bit `hi - i` gets the i-th digit.
    let bits := (List.range value.length).zip value |>.map fun (i, b) => (hi - i, b)
    return some { tile, feature, hi, lo, bits }
  | _ => throw s!"{what}: more than one '='"

def parse (text : String) : P (List Line) := do
  let lines := text.splitOn "\n"
  let parsed ← (List.range lines.length).zip lines |>.mapM fun (i, l) => parseLine (i + 1) l
  pure parsed.reduceOption

end VeryFPGA.Fasm

/-
Compare `VeryFPGA.Prims` with an Icarus Verilog simulation of Yosys's
`cells_sim.v` (`test/prims_tb.v`), on every input vector it printed.
Run by `make test-prims`; any mismatch is an error.

Verilog `%b` prints a vector most significant bit first, so for a 4-bit
field the string's character 0 is bit 3.
-/
import VeryFPGA.Prims

open VeryFPGA

def bitOfChar : Char → Except String Bool
  | '0' => pure false
  | '1' => pure true
  | c => throw s!"bad bit {c}"

/-- A Verilog `%b` field as a list of bits, least significant first. -/
def field (s : String) : Except String (List Bool) :=
  s.toList.reverse.mapM bitOfChar

def checkLine (line : String) : Except String Unit := do
  match line.splitOn " " with
  | ["CARRY4", ci, cy, di, s, o, co] =>
    let [ci] ← field ci | throw "CI width"
    let [cy] ← field cy | throw "CYINIT width"
    let [d0, d1, d2, d3] ← field di | throw "DI width"
    let [s0, s1, s2, s3] ← field s | throw "S width"
    let r := Prims.carry4 ci cy d0 d1 d2 d3 s0 s1 s2 s3
    unless [r.o0, r.o1, r.o2, r.o3] == (← field o) &&
        [r.co0, r.co1, r.co2, r.co3] == (← field co) do
      throw s!"CARRY4 mismatch: {line}"
  | ["BUF", a, inv, ibuf, obuf, bufg] =>
    let [a] ← field a | throw "width"
    unless [Prims.inv a, Prims.buf a, Prims.buf a, Prims.buf a] ==
        (← [inv, ibuf, obuf, bufg].mapM fun x => do
          let [b] ← field x | throw "width"
          pure b) do
      throw s!"INV/IBUF/OBUF/BUFG mismatch: {line}"
  | ["LUT6", init, ins, o] =>
    -- `field` gives LSB first: INIT entry 0 first, inputs [I0 = A1, ..., I5 = A6].
    let initBits ← field init
    let inBits ← field ins
    let [o] ← field o | throw "width"
    unless initBits.length == 64 && inBits.length == 6 do throw s!"LUT6 widths: {line}"
    unless Prims.lut initBits inBits == o do
      throw s!"LUT6 mismatch: {line}"
  | ["FDRE", q0, r, ce, d, q] =>
    let [q0] ← field q0 | throw "width"
    let [r] ← field r | throw "width"
    let [ce] ← field ce | throw "width"
    let [d] ← field d | throw "width"
    let [q] ← field q | throw "width"
    unless Prims.fdreNext r ce d q0 == q do
      throw s!"FDRE mismatch: {line}"
  | _ => throw s!"unrecognised line: {line}"

#eval show IO Unit from do
  let text ← IO.FS.readFile "../build/prims/vectors.txt"
  let lines := (text.splitOn "\n").filter (· ≠ "")
  for line in lines do
    match checkLine line with
    | .ok () => pure ()
    | .error e => throw (IO.userError e)
  let count (p : String) := (lines.filter (·.startsWith p)).length
  IO.println s!"Prims match cells_sim.v on all {lines.length} vectors \
    (CARRY4 {count "CARRY4 "}, LUT6 {count "LUT6 "}, INV/IBUF/OBUF/BUFG {count "BUF "}, \
    FDRE {count "FDRE "})"

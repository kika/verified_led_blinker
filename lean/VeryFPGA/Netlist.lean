/-
A flat gate-level netlist as Lean data, and a parser from Yosys `write_json`.

Trusted: the parser must turn the JSON into a `Netlist` that means the same
thing as the JSON. It accepts only the six primitive types blinky uses, with
exactly the ports and parameters it knows, and rejects anything else with an
error, which stops the build.

What the parser deliberately does not read:
- `attributes` on modules and cells (`src`, `keep`, `module_not_derived`,
  `top` apart from finding the top module). They carry no logic.
- Every module except the top one. Yosys also writes empty stub modules for
  the whole Xilinx primitive library.
-/
import Lean

open Lean

namespace VeryFPGA

/-- One wire bit: a numbered net, or a constant 0/1. -/
inductive Bit where
  | net (id : Nat)
  | const (b : Bool)
  deriving Repr, BEq, DecidableEq, Lean.ToExpr

/-- Four bits, for the 4-bit ports of `CARRY4`. Index 0 is the least
significant (the stage nearest the carry input). -/
structure Bits4 where
  b0 : Bit
  b1 : Bit
  b2 : Bit
  b3 : Bit
  deriving Repr, Lean.ToExpr

/-- A primitive instance with its port connections. Port names follow UG953. -/
inductive Cell where
  | fdre (init : Bool) (c ce d r q : Bit)
  | carry4 (ci cyinit : Bit) (di s o co : Bits4)
  | inv (i o : Bit)
  | ibuf (i o : Bit)
  | obuf (i o : Bit)
  | bufg (i o : Bit)
  deriving Repr, Lean.ToExpr

/-- The top module. `clk` and `led` are the nets of the two top-level ports.
`names` are Yosys's net names with their bits; they carry no meaning and
are used only as hints inside proofs (a wrong hint makes a proof fail, it
cannot make a false theorem). -/
structure Netlist where
  clk : Nat
  led : Nat
  cells : List Cell
  names : List (String × List Bit)
  deriving Repr, Lean.ToExpr

namespace Parse

abbrev P := Except String

def obj (j : Json) (what : String) : P (List (String × Json)) :=
  match j with
  | .obj kv => pure kv.toList
  | _ => throw s!"{what}: expected a JSON object"

def field (kv : List (String × Json)) (key what : String) : P Json :=
  match kv.lookup key with
  | some v => pure v
  | none => throw s!"{what}: missing key '{key}'"

def onlyKeys (kv : List (String × Json)) (allowed : List String) (what : String) : P Unit := do
  for (k, _) in kv do
    unless allowed.contains k do
      throw s!"{what}: unexpected key '{k}'"

/-- A net number, or the constant strings "0" and "1". "x" and "z" are
rejected: an undefined value would be a hole in the theorem. -/
def bit (j : Json) (what : String) : P Bit :=
  match j with
  | .str "0" => pure (.const false)
  | .str "1" => pure (.const true)
  | .str s => throw s!"{what}: unsupported constant bit '{s}'"
  | _ => match j.getNat? with
    | .ok n => pure (.net n)
    | .error _ => throw s!"{what}: expected a net number or \"0\"/\"1\""

def bits (j : Json) (what : String) : P (List Bit) := do
  let arr ← j.getArr?
  arr.toList.mapM (bit · what)

/-- Ports of each supported cell type: name, direction, width. -/
def cellPorts : String → Option (List (String × String × Nat))
  | "FDRE" => some [("C", "input", 1), ("CE", "input", 1), ("D", "input", 1),
                    ("Q", "output", 1), ("R", "input", 1)]
  | "CARRY4" => some [("CI", "input", 1), ("CO", "output", 4), ("CYINIT", "input", 1),
                      ("DI", "input", 4), ("O", "output", 4), ("S", "input", 4)]
  | "INV" | "IBUF" | "OBUF" | "BUFG" => some [("I", "input", 1), ("O", "output", 1)]
  | _ => none

/-- Read the connections of a cell, checking port names, directions and
widths against `cellPorts`. Outputs must be nets, never constants. -/
def connections (cell : List (String × Json)) (ports : List (String × String × Nat))
    (what : String) : P (List (String × List Bit)) := do
  let dirs ← obj (← field cell "port_directions" what) s!"{what}.port_directions"
  let conns ← obj (← field cell "connections" what) s!"{what}.connections"
  onlyKeys dirs (ports.map (·.1)) s!"{what}.port_directions"
  onlyKeys conns (ports.map (·.1)) s!"{what}.connections"
  ports.mapM fun (name, dir, width) => do
    let d ← (← field dirs name s!"{what}.port_directions").getStr?
    unless d == dir do
      throw s!"{what}: port {name} has direction {d}, expected {dir}"
    let bs ← bits (← field conns name s!"{what}.connections") s!"{what}.{name}"
    unless bs.length == width do
      throw s!"{what}: port {name} has width {bs.length}, expected {width}"
    if dir == "output" then
      for b in bs do
        if let .const _ := b then
          throw s!"{what}: output {name} is tied to a constant"
    pure (name, bs)

def one (conns : List (String × List Bit)) (name what : String) : P Bit :=
  match conns.lookup name with
  | some [b] => pure b
  | _ => throw s!"{what}: port {name} must be 1 bit wide"

def four (conns : List (String × List Bit)) (name what : String) : P Bits4 :=
  match conns.lookup name with
  | some [b0, b1, b2, b3] => pure { b0, b1, b2, b3 }
  | _ => throw s!"{what}: port {name} must be 4 bits wide"

/-- FDRE's only accepted parameter is `INIT`, given by Yosys as a 1-bit
string. Anything else (including `IS_*_INVERTED`) is rejected. -/
def fdreInit (params : List (String × Json)) (what : String) : P Bool := do
  onlyKeys params ["INIT"] s!"{what}.parameters"
  match ← field params "INIT" s!"{what}.parameters" with
  | .str "0" => pure false
  | .str "1" => pure true
  | j => throw s!"{what}: unsupported INIT value {j.compress}"

def cell (name : String) (j : Json) : P Cell := do
  let what := s!"cell {name}"
  let kv ← obj j what
  onlyKeys kv ["hide_name", "type", "parameters", "attributes", "port_directions",
    "connections"] what
  let ty ← (← field kv "type" what).getStr?
  let some ports := cellPorts ty | throw s!"{what}: unsupported cell type {ty}"
  let params ← obj (← field kv "parameters" what) s!"{what}.parameters"
  let c ← connections kv ports what
  match ty with
  | "FDRE" =>
    return .fdre (← fdreInit params what) (← one c "C" what) (← one c "CE" what)
      (← one c "D" what) (← one c "R" what) (← one c "Q" what)
  | _ =>
    onlyKeys params [] s!"{what}.parameters"
    match ty with
    | "CARRY4" =>
      return .carry4 (← one c "CI" what) (← one c "CYINIT" what) (← four c "DI" what)
        (← four c "S" what) (← four c "O" what) (← four c "CO" what)
    | "INV" => return .inv (← one c "I" what) (← one c "O" what)
    | "IBUF" => return .ibuf (← one c "I" what) (← one c "O" what)
    | "OBUF" => return .obuf (← one c "I" what) (← one c "O" what)
    | "BUFG" => return .bufg (← one c "I" what) (← one c "O" what)
    | _ => throw s!"{what}: unsupported cell type {ty}"

/-- A top-level port: direction and a single net. -/
def port (ports : List (String × Json)) (name dir : String) : P Nat := do
  let what := s!"port {name}"
  let kv ← obj (← field ports name "ports") what
  onlyKeys kv ["direction", "bits"] what
  let d ← (← field kv "direction" what).getStr?
  unless d == dir do throw s!"{what}: direction {d}, expected {dir}"
  match ← bits (← field kv "bits" what) what with
  | [.net n] => pure n
  | _ => throw s!"{what}: expected exactly one net"

/-- A module is the top one if its `top` attribute is a 0/1 string equal to 1. -/
def isTop (m : Json) : Bool :=
  match m.getObjVal? "attributes" >>= (·.getObjVal? "top") >>= (·.getStr?) with
  | .ok s => s.any (· == '1') && s.all (fun ch => ch == '0' || ch == '1') &&
      s.dropWhile (· == '0') == "1"
  | .error _ => false

def netlist (j : Json) : P Netlist := do
  let top ← obj j "netlist"
  onlyKeys top ["creator", "modules"] "netlist"
  let mods ← obj (← field top "modules" "netlist") "modules"
  let (name, m) ← match mods.filter (isTop ·.2) with
    | [nm] => pure nm
    | l => throw s!"expected exactly one top module, found {l.length}"
  let what := s!"module {name}"
  let kv ← obj m what
  onlyKeys kv ["attributes", "ports", "cells", "netnames"] what
  let ports ← obj (← field kv "ports" what) s!"{what}.ports"
  onlyKeys ports ["clk", "led"] s!"{what}.ports"
  let clk ← port ports "clk" "input"
  let led ← port ports "led" "output"
  let cells ← (← obj (← field kv "cells" what) s!"{what}.cells").mapM fun (n, c) => cell n c
  let names ← (← obj (← field kv "netnames" what) s!"{what}.netnames").mapM fun (n, v) => do
    let nkv ← obj v s!"netname {n}"
    -- A wire `init` attribute would be an initial value outside any FDRE INIT.
    if let .ok attrs := v.getObjVal? "attributes" then
      if (attrs.getObjVal? "init").toOption.isSome then
        throw s!"netname {n}: unsupported init attribute"
    pure (n, ← bits (← field nkv "bits" s!"netname {n}") s!"netname {n}")
  return { clk, led, cells, names }

end Parse

/-- `load_netlist foo from "path.json"` reads a Yosys JSON netlist while this
file is compiled, parses it, and defines `foo : Netlist` as the resulting
value. A parse error stops the build. -/
elab "load_netlist " id:ident " from " path:str : command => do
  let text ← IO.FS.readFile path.getString
  let json ← match Json.parse text with
    | .ok j => pure j
    | .error e => throwError "JSON parse error in {path.getString}: {e}"
  let nl ← match Parse.netlist json with
    | .ok nl => pure nl
    | .error e => throwError "netlist rejected: {e}"
  let name := (← getCurrNamespace) ++ id.getId
  Elab.Command.liftCoreM do
    addAndCompile <| .defnDecl {
      name, levelParams := [], type := mkConst ``Netlist, value := toExpr nl,
      hints := .regular 0, safety := .safe }
    enableRealizationsForConst name

end VeryFPGA

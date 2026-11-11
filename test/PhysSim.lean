/-
M4a.3 sanity check (simulation, not proof): the machine decoded from the
FASM counts like the specification. Physical flip-flops are mapped to counter
bits by their carry-chain position: slices ordered bottom to top by global
Y, four bits per slice (A..D). Run by `make phys-check`.
-/
import VeryFPGA.BlinkyPhys

open VeryFPGA

/-- Counter bit held by each physical flip-flop. -/
def bitOfFlop : List Nat :=
  let fl := Phys.flops blinkyPhys
  let ys := fl.map fun (i, _) =>
    match blinkyPhys.sites[i]? >>= (Phys.parseSiteName ·.name) with
    | some (_, _, y) => y
    | none => 0
  let rows := (ys.eraseDups.mergeSort (· ≤ ·))
  (fl.zip ys).map fun ((_, n), y) => 4 * rows.idxOf y + n

def conc (v : Nat) : List Bool := bitOfFlop.map fun b => v.testBit b

def value (st : List Bool) : Nat :=
  (st.zip bitOfFlop).foldl (fun acc (q, b) => if q then acc + 2 ^ b else acc) 0

#eval show IO Unit from do
  let m := physMachine
  let sorted := bitOfFlop.mergeSort (· ≤ ·)
  unless sorted == List.range 27 do throw (IO.userError s!"bit mapping is not a permutation: {bitOfFlop}")
  unless value m.init == 0 do throw (IO.userError "power-up value is not 0")
  -- run from power-up
  let mut st := m.init
  for n in [0:5000] do
    unless value st == n % 2 ^ 27 do throw (IO.userError s!"cycle {n}: counter is {value st}")
    st := m.step st
  -- random states (linear congruential generator)
  let mut x := 12345
  for _ in [0:2000] do
    x := (x * 1103515245 + 12345) % 2 ^ 31
    let v := x % 2 ^ 27
    unless value (m.step (conc v)) == (v + 1) % 2 ^ 27 do
      throw (IO.userError s!"state {v}: step gives {value (m.step (conc v))}")
    unless m.out.eval (conc v) == v.testBit 26 do
      throw (IO.userError s!"state {v}: LED output is not bit 26")
  IO.println "Decoded FASM machine: power-up value 0; counts 0..4999 from power-up; \
    on 2000 random states one step adds 1 and the LED output is bit 26."

/- Summary of the resolved FASM features, printed by `make fasm-check`. -/
import VeryFPGA.BlinkyFasm

open VeryFPGA

#eval show IO Unit from do
  let fs := blinkyFasm
  let kindName : XRay.Kind → String
    | .bits => "bits" | .always => "always (pseudo-PIP)" | .default => "default (pseudo-PIP)"
  let keys := (fs.map fun f => (f.tileType, kindName f.kind)).eraseDups
  IO.println s!"{fs.length} FASM features, all found in the X-Ray database:"
  for (ty, k) in keys do
    let n := (fs.filter fun f => f.tileType == ty && kindName f.kind == k).length
    IO.println s!"  {n}\t{ty}\t{k}"

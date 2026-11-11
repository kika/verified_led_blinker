/- Summary of the bitstream decode, printed by `make bit-check`. -/
import VeryFPGA.Bitstream
import VeryFPGA.BlinkyFasm

open VeryFPGA

#eval show IO Unit from do
  let root := (← IO.getEnv "PRJXRAY_DB_DIR").get! ++ "/spartan7"
  let r ← Bitstream.decode root "xc7s50" "xc7s50ftgb196-1" "../build/blinky.bit"
  IO.println s!"build/blinky.bit: {r.setBits} configuration bits set, all explained by \
    {r.features.length} decoded features."
  IO.println s!"Register writes (recorded, not interpreted): {r.registers}"
  let key (f : XRay.Feature) :=
    s!"{f.tile}.{f.feature}{if f.bits.isEmpty then "" else
      "=" ++ String.ofList (f.bits.map fun (_, b) => if b then '1' else '0')}"
  let fromBit := r.features.map key
  let fromFasm := (blinkyFasm.filter (·.kind == .bits)).map key
  let onlyBit := fromBit.filter (!fromFasm.contains ·)
  let onlyFasm := fromFasm.filter (!fromBit.contains ·)
  IO.println s!"Compared with the FASM's bit-backed features: {onlyBit.length} only in the \
    bitstream, {onlyFasm.length} only in the FASM:"
  for k in onlyFasm do IO.println s!"  FASM only: {k}"

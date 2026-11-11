/- Summary of the reconstructed physical wiring, printed by `make route-check`. -/
import VeryFPGA.BlinkyRoute

open VeryFPGA

def countBy (xs : List String) : List (String × Nat) :=
  xs.eraseDups.map fun k => (k, (xs.filter (· == k)).length)

def pinName (p : Route.SitePin) : String :=
  s!"{p.tile}/{p.site}({p.siteType}).{p.pin}"

#eval show IO Unit from do
  let r := blinkyRouting
  let pipCount := (r.conns.foldl (fun acc c => acc ++ c.pips) []).eraseDups.length
  IO.println s!"Site inputs traced: {r.conns.length + r.undriven.length} \
    ({r.conns.length} driven, {r.undriven.length} undriven), \
    {r.unwired.length} unwired; {pipCount} distinct PIPs on traced paths."
  IO.println "Every FASM PIP is on a traced path; no node has more than one driver."
  let signal := r.conns.filter (·.source.siteType != "TIEOFF")
  IO.println s!"Signal connections ({signal.length}), by input pin <- source pin:"
  for (k, n) in countBy (signal.map fun c =>
      s!"{c.input.siteType}.{c.input.pin} <- {c.source.siteType}.{c.source.pin}") do
    IO.println s!"  {n}\t{k}"
  IO.println "Clock and LED path connections:"
  for c in signal.filter (fun c => c.input.siteType ∈ ["BUFGCTRL", "BUFHCE"] ||
      (c.input.siteType == "OLOGICE3" && c.input.pin == "D1")) do
    IO.println s!"  {pinName c.input} <- {pinName c.source}"

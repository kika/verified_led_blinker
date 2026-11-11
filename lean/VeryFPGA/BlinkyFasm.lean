/-
The blinky FASM produced by nextpnr-xilinx, parsed while this file is
compiled and checked feature by feature against the X-Ray database
(`$PRJXRAY_DB_DIR/spartan7`, die `xc7s50`). `lakefile.toml` declares
`build/blinky.fasm` as an input, so a new FASM forces a rebuild. The X-Ray
database is not tracked by lake; its revision is pinned in TOOLS.md.
-/
import VeryFPGA.XRay

namespace VeryFPGA

load_fasm blinkyFasm from "../build/blinky.fasm" xray "spartan7" "xc7s50"

end VeryFPGA

/-
The blinky netlist produced by Yosys, read into Lean while this file is
compiled. `lakefile.toml` declares `build/blinky.json` as an input of this
library, so a new netlist forces this file and every proof about it to be
rebuilt.
-/
import VeryFPGA.Netlist

namespace VeryFPGA

load_netlist netlist from "../build/blinky.json"

end VeryFPGA

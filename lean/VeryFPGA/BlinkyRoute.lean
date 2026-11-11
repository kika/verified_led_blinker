/-
Physical wiring of the blinky FASM, computed at build time by `route_fasm`
from the resolved features in `BlinkyFasm.lean` and the X-Ray connectivity
data (`tileconn.json`, `tile_type_*.json`, `site_type_*.json`,
`ppips_*.db`).
-/
import VeryFPGA.Route
import VeryFPGA.BlinkyFasm

namespace VeryFPGA

route_fasm blinkyRouting from blinkyFasm xray "spartan7" "xc7s50"

end VeryFPGA

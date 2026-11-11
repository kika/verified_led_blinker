/- Printed into build/PROOF.txt by `make proof`. -/
import VeryFPGA

open VeryFPGA

-- M3: the Yosys netlist
#check @netlist_blinks
#print axioms netlist_blinks
-- M4a: the routed design, decoded from the FASM
#check @phys_blinks
#print axioms phys_blinks

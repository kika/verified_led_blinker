/- Printed into build/PROOF.txt by `make proof`. -/
import VeryFPGA

open VeryFPGA

#check @netlist_blinks
#check @netlist_refines_spec
#print axioms netlist_blinks
#print axioms netlist_refines_spec

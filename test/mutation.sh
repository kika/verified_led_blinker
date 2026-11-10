#!/usr/bin/env bash
# M3 mutation test: run the unchanged refinement proof against mutated copies
# of the netlist. The control copy must pass; every mutant must fail.
# Run from the repository root with env.sh sourced.
set -u
OUT=build/mutation
python3 -I test/mutate.py build/blinky.json "$OUT" || exit 1
status=0
for name in control cyinit swap_d flop_init; do
  lean_file="$OUT/$name.lean"
  {
    echo "import VeryFPGA.Netlist"
    echo "namespace VeryFPGA"
    echo "load_netlist netlist from \"../$OUT/$name.json\""
    echo "end VeryFPGA"
    grep -v '^import VeryFPGA.Blinky$' lean/VeryFPGA/Refine.lean
  } > "$lean_file"
  # The Refine.lean imports must come first in a Lean file: hoist them.
  python3 -I - "$lean_file" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().split("\n")
imports = [l for l in lines if l.startswith("import ")]
rest = [l for l in lines if not l.startswith("import ")]
open(p, "w").write("\n".join(imports + rest))
PY
  log="$OUT/$name.log"
  (cd lean && lake env lean "../$lean_file") > "$log" 2>&1
  rc=$?
  first_error=$(grep -m1 -E 'error' "$log" | cut -c1-200)
  if [ "$name" = control ]; then
    if [ $rc -eq 0 ]; then echo "control:   PASS (proof accepted, as required)"; else echo "control:   FAIL (proof should pass): $first_error"; status=1; fi
  else
    if [ $rc -ne 0 ]; then echo "$name: proof REJECTED, as required: $first_error"; else echo "$name: proof ACCEPTED, test FAILED"; status=1; fi
  fi
done
exit $status

#!/usr/bin/env bash
# M4a.4 mutation test: the unchanged routed-design proof (BlinkyPhys.lean +
# PhysRefine.lean) must fail on FASM copies with one logic change that the
# FASM check, the routing and the site models all accept. The unchanged copy
# must pass. Run from the repository root with .envrc loaded.
set -u
OUT=build/phys_proof_mutation
mkdir -p "$OUT"
F=build/blinky.fasm
cp "$F" "$OUT/control.fasm"

# lut_init: CLBLL_L_X2Y44 ALUT computes O6 = A3 (its own flip-flop AQ) with
# A1=0, A2=A4=A5=A6=1, so it reads INIT entry 58 or 62. Entry 58 (character 5
# of the MSB-first literal) is 0; set it to 1.
python3 -I - "$F" "$OUT/lut_init.fasm" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
out, done = [], False
for l in open(src).read().split("\n"):
    key = "CLBLL_L_X2Y44.SLICEL_X0.ALUT.INIT[63:0] = 64'b"
    if l.startswith(key):
        bits = list(l[len(key):])
        assert len(bits) == 64 and bits[63 - 58] == "0", "unexpected INIT"
        bits[63 - 58] = "1"
        l = key + "".join(bits)
        done = True
    out.append(l)
assert done
open(dst, "w").write("\n".join(out))
PY

# reroute: SLICE_X0Y45 input D3 no longer from DQ: remove its interconnect PIP
# and the pseudo-PIP only that route used; D3 falls back to its default, VCC.
grep -vxF -e 'INT_L_X2Y45.IMUX_L38.LOGIC_OUTS_L7' -e 'CLBLL_L_X2Y45.CLBLL_LOGIC_OUTS7.CLBLL_LL_DQ' \
  "$F" > "$OUT/reroute.fasm"

# ff_init: flip-flop BFF of CLBLL_L_X2Y43 powers up at 1 instead of 0.
grep -vxF 'CLBLL_L_X2Y43.SLICEL_X0.BFF.ZINI' "$F" > "$OUT/ff_init.fasm"

status=0
for name in control lut_init reroute ff_init; do
  if [ "$name" != control ] && cmp -s "$F" "$OUT/$name.fasm"; then
    echo "$name: mutation did not change the file, test FAILED"; status=1; continue
  fi
  lean_file="$OUT/$name.lean"
  {
    echo "import VeryFPGA.PhysImpl"
    echo "import VeryFPGA.Route"
    echo "import VeryFPGA.DefByEval"
    echo "import VeryFPGA.Spec"
    echo "namespace VeryFPGA"
    echo "load_fasm blinkyFasm from \"../$OUT/$name.fasm\" xray \"spartan7\" \"xc7s50\""
    echo "route_fasm blinkyRouting from blinkyFasm xray \"spartan7\" \"xc7s50\""
    echo "end VeryFPGA"
    grep -v '^import ' lean/VeryFPGA/BlinkyPhys.lean
    grep -v '^import ' lean/VeryFPGA/PhysRefine.lean
  } > "$lean_file"
  log="$OUT/$name.log"
  (cd lean && lake lean "../$lean_file") > "$log" 2>&1
  rc=$?
  first=$(grep -m1 -E 'error' "$log" | sed -E 's/^[^:]*:([0-9]+):[0-9]+: error: /line \1: /' | cut -c1-150)
  if [ "$name" = control ]; then
    if [ $rc -eq 0 ]; then echo "control:  proof accepted, as required"; else echo "control:  proof FAILED: $first"; status=1; fi
  elif grep -qE 'FASM rejected|routing rejected|load_phys:' "$log"; then
    printf '%-9s rejected before the proof (%s), test FAILED\n' "$name:" "$first"; status=1
  elif [ $rc -ne 0 ]; then
    printf '%-9s proof REJECTED, as required: %s\n' "$name:" "$first"
  else
    printf '%-9s proof ACCEPTED, test FAILED\n' "$name:"; status=1
  fi
done
exit $status

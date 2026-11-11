#!/usr/bin/env bash
# M4b test: faulty copies of the bitstream must be rejected, either by the
# bitstream reader or by the theorem that the bitstream's machine is
# physMachine. The unchanged copy must pass. Run from the repository root
# with .envrc loaded.
set -u
OUT=build/bit_mutation
mkdir -p "$OUT"
cp build/blinky.bit "$OUT/control.bit"
echo "control: unchanged copy"
python3 -I test/bit_mutate.py build/blinky.bit "$PRJXRAY_DB_DIR/spartan7" xc7s50 xc7s50ftgb196-1 "$OUT" || exit 1
status=0
for name in control lut_bit unknown_bit padding bram idcode; do
  lean_file="$OUT/$name.lean"
  cat > "$lean_file" <<EOF
import VeryFPGA.Bitstream
import VeryFPGA.BlinkyPhys
namespace VeryFPGA
load_bit bits from "../$OUT/$name.bit" xray "spartan7" "xc7s50" "xc7s50ftgb196-1"
route_fasm routing from bits xray "spartan7" "xc7s50"
load_phys design from bits routing xray "spartan7" "xc7s50" "xc7s50ftgb196-1"
theorem same_machine : Phys.physCompile design = some physMachine := by rfl
end VeryFPGA
EOF
  log="$OUT/$name.log"
  (cd lean && lake lean "../$lean_file") > "$log" 2>&1
  rc=$?
  reader=$(grep -m1 -oE 'bitstream rejected: .*' "$log" | cut -c1-120)
  if [ "$name" = control ]; then
    if [ $rc -eq 0 ]; then echo "control:      accepted, same machine"; else echo "control:      FAILED: $(grep -m1 error "$log")"; status=1; fi
  elif [ -n "$reader" ]; then
    printf '%-13s rejected by the reader: %s\n' "$name:" "$reader"
  elif [ $rc -ne 0 ] && grep -q 'same_machine\|rfl' "$log"; then
    printf '%-13s rejected by the theorem: the machine differs from physMachine\n' "$name:"
  else
    printf '%-13s NOT rejected, test FAILED: %s\n' "$name:" "$(grep -m1 error "$log")"; status=1
  fi
done
exit $status

#!/usr/bin/env bash
# M4a.2 routing test: the router must reject faulty copies of the FASM.
# The unchanged copy (control) must be accepted. Run from the repository
# root with env.sh sourced.
set -u
OUT=build/route_mutation
mkdir -p "$OUT"
cp build/blinky.fasm "$OUT/control.fasm"
echo "control: unchanged copy"
python3 -I test/route_mutate.py build/blinky.fasm "$PRJXRAY_DB_DIR/spartan7" "$OUT" || exit 1
status=0
for name in control drop_mid conflict stray default_clash; do
  lean_file="$OUT/$name.lean"
  cat > "$lean_file" <<EOF
import VeryFPGA.Route
import VeryFPGA.XRay
namespace VeryFPGA
load_fasm feats from "../$OUT/$name.fasm" xray "spartan7" "xc7s50"
route_fasm routing from feats xray "spartan7" "xc7s50"
end VeryFPGA
EOF
  log="$OUT/$name.log"
  (cd lean && lake lean "../$lean_file") > "$log" 2>&1
  rc=$?
  msg=$(grep -m1 -oE '(routing|FASM) rejected: .*' "$log" | cut -c1-160)
  if [ "$name" = control ]; then
    if [ $rc -eq 0 ]; then echo "control:       ACCEPTED, as required"; else echo "control:       REJECTED (should pass): $(grep -m1 error "$log")"; status=1; fi
  else
    if [ $rc -ne 0 ] && [ -n "$msg" ]; then printf '%-14s REJECTED, as required: %s\n' "$name:" "$msg"
    else printf '%-14s NOT rejected by routing, test FAILED: %s\n' "$name:" "$(grep -m1 error "$log")"; status=1; fi
  fi
done
exit $status

#!/usr/bin/env bash
# M4a.3 model test: physCompile must refuse FASM copies whose configuration
# differs from what the site models accept. The unchanged copy must be
# accepted. Each mutation is a real X-Ray feature, so every copy gets past
# the FASM check (M4a.1) and the routing (M4a.2). Run from the repository
# root with .envrc loaded.
set -u
OUT=build/phys_mutation
mkdir -p "$OUT"
F=build/blinky.fasm
cp "$F" "$OUT/control.fasm"
# An output-selector setting the slice model does not cover.
{ cat "$F"; echo "CLBLL_L_X2Y41.SLICEL_X0.AOUTMUX.O6"; } > "$OUT/outmux.fasm"
# Falling-edge clock on a used slice.
sed 's/^CLBLL_L_X2Y41\.SLICEL_X0\.NOCLKINV$/CLBLL_L_X2Y41.SLICEL_X0.CLKINV/' "$F" > "$OUT/clkinv.fasm"
# LED pad drive 4 mA instead of the 12 mA in board/astria.xdc.
sed 's/IOB_Y1\.LVCMOS33_LVTTL\.DRIVE\.I12_I16$/IOB_Y1.LVCMOS33_LVTTL.DRIVE.I4/' "$F" > "$OUT/drive.fasm"
# T1 no longer inverted: the LED pad's tristate input becomes 1.
{ cat "$F"; echo "LIOI3_SING_X0Y49.OLOGIC_Y1.ZINV_T1"; } > "$OUT/tristate.fasm"
# BUFGCTRL CE0 inverted: the clock buffer no longer passes I0.
grep -v '^CLK_BUFG_BOT_R_X60Y48\.BUFGCTRL\.BUFGCTRL_X0Y0\.ZINV_CE0$' "$F" > "$OUT/bufg_ce.fasm"
status=0
for name in control outmux clkinv drive tristate bufg_ce; do
  if [ "$name" != control ] && cmp -s "$F" "$OUT/$name.fasm"; then
    echo "$name: mutation did not change the file, test FAILED"; status=1; continue
  fi
  lean_file="$OUT/$name.lean"
  cat > "$lean_file" <<EOF
import VeryFPGA.PhysImpl
import VeryFPGA.Route
namespace VeryFPGA
load_fasm feats from "../$OUT/$name.fasm" xray "spartan7" "xc7s50"
route_fasm routing from feats xray "spartan7" "xc7s50"
load_phys design from feats routing xray "spartan7" "xc7s50" "xc7s50ftgb196-1"
#eval s!"ACCEPTED={(Phys.physCompile design).isSome} [features known: {Phys.designOk design}, clock pad: {Phys.clockPad design}, LED pad: {Phys.ledPad design}]"
end VeryFPGA
EOF
  log="$OUT/$name.log"
  (cd lean && lake lean "../$lean_file") > "$log" 2>&1
  verdict=$(grep -oE 'ACCEPTED=(true|false)' "$log")
  if [ "$name" = control ]; then
    [ "$verdict" = ACCEPTED=true ] && echo "control:  accepted, as required" || { echo "control:  NOT accepted: $(grep -m1 error "$log")"; status=1; }
  else
    if [ "$verdict" = ACCEPTED=false ]; then printf '%-9s refused by the model, as required %s\n' "$name:" "$(grep -oE '\[features known.*\]' "$log")"
    else printf '%-9s NOT refused (%s), test FAILED\n' "$name:" "${verdict:-$(grep -m1 error "$log")}"; status=1; fi
  fi
done
exit $status

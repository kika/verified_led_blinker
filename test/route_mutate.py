"""Write faulty copies of a FASM file for the M4a.2 routing test.

Usage: python3 -I test/route_mutate.py <design.fasm> <xray family dir> <outdir>

Each copy has one fault that the router (lean/VeryFPGA/Route.lean) must
reject. Mutations are chosen to be valid X-Ray PIPs, so that each copy gets
past the feature resolver (M4a.1) and is rejected by the routing checks.
The input file is only read.
"""
import json
import os
import re
import sys


def load_pips(db, tile_type):
    t = json.load(open(f"{db}/tile_type_{tile_type}.json"))
    return {(p["dst_wire"], p["src_wire"]) for p in t["pips"].values()}


def ppips(db, tile_type):
    out = {}
    path = f"{db}/ppips_{tile_type.lower()}.db"
    for line in open(path):
        name, kind = line.split()
        _, dst, src = name.split(".")
        out[(dst, src)] = kind
    return out


def main():
    fasm, db, out = sys.argv[1], sys.argv[2], sys.argv[3]
    os.makedirs(out, exist_ok=True)
    lines = open(fasm).read().split("\n")
    int_l = load_pips(db, "INT_L")
    int_pp = ppips(db, "INT_L")
    pip_re = re.compile(r"^(INT_L_X\d+Y\d+)\.([A-Z0-9_]+)\.([A-Z0-9_]+)$")
    enabled = []  # (index, tile, dst, src) for bit-backed INT_L PIPs
    for i, l in enumerate(lines):
        m = pip_re.match(l)
        if m and (m.group(2), m.group(3)) in int_l and (m.group(2), m.group(3)) not in int_pp:
            enabled.append((i, m.group(1), m.group(2), m.group(3)))
    by_dst = {(t, d): s for _, t, d, s in enabled}
    mutants = {}

    # drop_mid: a non-final hop, i.e. a PIP onto a routing wire ("...BEG...")
    # that a later PIP of the path reads (possibly in another tile). Without
    # it the rest of the path has no source.
    for i, t, d, s in enabled:
        if "BEG" in d:
            mutants["drop_mid"] = (lines[:i] + lines[i + 1:], f"removed {lines[i]}")
            break

    # conflict: a second bit-backed PIP into the destination of an enabled
    # IMUX PIP (not a pseudo-PIP, so the two-driver check is what fires).
    for i, t, d, s in enabled:
        if not d.startswith("IMUX"):
            continue
        others = sorted(src for (dst, src) in int_l
                        if dst == d and src != s and (dst, src) not in int_pp)
        if others:
            extra = f"{t}.{d}.{others[0]}"
            mutants["conflict"] = (lines + [extra], f"added {extra}")
            break

    # stray: a long-wire start driven from a slice output that is already
    # routed, where nothing reads the long wire.
    for i, t, d, s in enabled:
        if s.startswith("LOGIC_OUTS"):
            for cand in sorted(int_l):
                if cand[1] == s and cand[0].startswith("NN6BEG") and (t, cand[0]) not in by_dst \
                        and cand not in int_pp:
                    extra = f"{t}.{cand[0]}.{s}"
                    mutants["stray"] = (lines + [extra], f"added {extra}")
                    break
        if "stray" in mutants:
            break

    # default_clash: list the default pseudo-PIP of a wire that has an
    # enabled bit-backed PIP.
    for i, t, d, s in enabled:
        defaults = [src for (dst, src), k in int_pp.items() if dst == d and k == "default"]
        if defaults:
            extra = f"{t}.{d}.{defaults[0]}"
            mutants["default_clash"] = (lines + [extra], f"added {extra}")
            break

    for name in ["drop_mid", "conflict", "stray", "default_clash"]:
        if name not in mutants:
            raise SystemExit(f"could not construct mutant {name}")
        text, what = mutants[name]
        with open(os.path.join(out, name + ".fasm"), "w") as f:
            f.write("\n".join(text) + "\n")
        print(f"{name}: {what}")


main()

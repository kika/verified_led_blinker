"""Write mutated copies of a Yosys netlist JSON for the M3 mutation test.

Usage: python3 -I test/mutate.py <netlist.json> <outdir>
Writes <outdir>/{control,cyinit,swap_d,flop_init}.json. The input file is
only read; every mutation is applied to a copy.
"""
import json
import os
import sys


def top(d):
    mods = [m for m in d["modules"].values() if m.get("attributes", {}).get("top", "").lstrip("0") == "1"]
    assert len(mods) == 1
    return mods[0]


def cells(m, ty):
    return sorted((n for n, c in m["cells"].items() if c["type"] == ty))


def first_carry4(m):
    # The carry block whose CI is the constant 0 starts the chain.
    for n in cells(m, "CARRY4"):
        if m["cells"][n]["connections"]["CI"] == ["0"]:
            return n
    raise SystemExit("no chain-start CARRY4")


def cyinit(m):
    n = first_carry4(m)
    c = m["cells"][n]["connections"]
    assert c["CYINIT"] == ["0"]
    c["CYINIT"] = ["1"]
    return f"{n}: CYINIT 0 -> 1"


def swap_d(m):
    a, b = cells(m, "FDRE")[3], cells(m, "FDRE")[7]
    ca, cb = m["cells"][a]["connections"], m["cells"][b]["connections"]
    ca["D"], cb["D"] = cb["D"], ca["D"]
    return f"swapped D of {a} and {b}"


def flop_init(m):
    n = cells(m, "FDRE")[5]
    p = m["cells"][n]["parameters"]
    assert p["INIT"] == "0"
    p["INIT"] = "1"
    return f"{n}: INIT 0 -> 1"


def main():
    src, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    with open(src) as f:
        original = f.read()
    for name, fn in [("control", None), ("cyinit", cyinit), ("swap_d", swap_d), ("flop_init", flop_init)]:
        d = json.loads(original)
        what = fn(top(d)) if fn else "unchanged copy"
        with open(os.path.join(out, name + ".json"), "w") as f:
            json.dump(d, f)
        print(f"{name}: {what}")


main()

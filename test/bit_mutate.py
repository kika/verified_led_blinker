"""Write faulty copies of a 7-series .bit for the M4b test.

Usage: python3 -I test/bit_mutate.py <design.bit> <xray family dir> <die> <part> <outdir>

Frame positions follow the same auto-increment order as
lean/VeryFPGA/Bitstream.lean (from part.json); tile bit positions follow
tilegrid.json and segbits. The input file is only read.
"""
import json
import os
import struct
import sys


def main():
    bit, db, die, part, out = sys.argv[1:6]
    os.makedirs(out, exist_ok=True)
    data = bytearray(open(bit, "rb").read())
    sync = data.find(bytes.fromhex("aa995566"))
    words_at = lambda i: struct.unpack(">I", data[i:i + 4])[0]
    # locate the frame data (the one type 2 packet)
    i = sync + 4
    while words_at(i) >> 29 != 2:
        i += 4
    fdri = i + 4

    p = json.load(open(f"{db}/{part}/part.json"))
    order = []
    for bt, btn in [(0, "CLB_IO_CLK"), (1, "BLOCK_RAM")]:
        for hb, half in [(0, "top"), (1, "bottom")]:
            rows = p["global_clock_regions"][half]["rows"]
            for r in sorted(rows, key=int):
                bus = rows[r]["configuration_buses"].get(btn)
                if not bus:
                    continue
                cols = bus["configuration_columns"]
                for c in sorted(cols, key=int):
                    for m in range(cols[c]["frame_count"]):
                        order.append((bt << 23) | (hb << 22) | (int(r) << 17) | (int(c) << 7) | m)
                order += [None, None]

    def flip(buf, frame_index, word, bitno):
        off = fdri + 4 * (101 * frame_index + word)
        v = struct.unpack(">I", buf[off:off + 4])[0] ^ (1 << bitno)
        buf[off:off + 4] = struct.pack(">I", v)

    def tile_bit(tile, frame_rel, bitidx):
        g = json.load(open(f"{db}/{die}/tilegrid.json"))[tile]["bits"]["CLB_IO_CLK"]
        addr = int(g["baseaddr"], 16) + frame_rel
        return order.index(addr), g["offset"] + bitidx // 32, bitidx % 32

    seg = {}
    for line in open(f"{db}/segbits_clbll_l.db"):
        parts = line.split()
        if parts:
            seg[parts[0]] = parts[1:]

    mutants = {}
    # lut_bit: CLBLL_L_X2Y44 SLICEL_X0 ALUT.INIT[58]
    (fb,) = seg["CLBLL_L.SLICEL_X0.ALUT.INIT[58]"]
    f, b = (int(x) for x in fb.split("_"))
    buf = bytearray(data); flip(buf, *tile_bit("CLBLL_L_X2Y44", f, b))
    mutants["lut_bit"] = (buf, f"ALUT.INIT[58] of CLBLL_L_X2Y44 (segbit {fb}) flipped")

    # unknown_bit: a bit of CLBLL_L_X2Y44 that no CLBLL_L feature mentions
    used = {tuple(int(x) for x in s.lstrip("!").split("_")) for bits in seg.values() for s in bits}
    cand = next((f, b) for f in range(36) for b in range(64) if (f, b) not in used)
    buf = bytearray(data); flip(buf, *tile_bit("CLBLL_L_X2Y44", *cand))
    mutants["unknown_bit"] = (buf, f"bit {cand[0]:02d}_{cand[1]:02d} of CLBLL_L_X2Y44 (in no segbits entry) set")

    # padding: first padding frame, word 0, bit 0
    buf = bytearray(data); flip(buf, order.index(None), 0, 0)
    mutants["padding"] = (buf, "bit 0 of the first padding frame set")

    # bram: first block RAM frame, word 0, bit 0
    first_bram = next(n for n, a in enumerate(order) if a is not None and a >= 1 << 23)
    buf = bytearray(data); flip(buf, first_bram, 0, 0)
    mutants["bram"] = (buf, "bit 0 of the first block RAM frame set")

    # idcode: the IDCODE write's value, bit 0 flipped
    buf = bytearray(data)
    j = sync + 4
    while j < fdri:
        h = words_at(j)
        if h >> 29 == 1 and (h >> 13) & 0x1F == 12 and h & 0x7FF == 1:
            v = words_at(j + 4) ^ 1
            buf[j + 4:j + 8] = struct.pack(">I", v)
            break
        j += 4
    mutants["idcode"] = (buf, "IDCODE value bit 0 flipped")

    for name, (buf, what) in mutants.items():
        assert buf != data
        open(os.path.join(out, name + ".bit"), "wb").write(buf)
        print(f"{name}: {what}")


main()

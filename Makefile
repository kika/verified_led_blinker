# Run with the tools from .envrc on PATH (direnv loads it; in bash without
# direnv: . ./.envrc && make)
# Flow: yosys -> nextpnr-xilinx -> fasm2frames -> xc7frames2bit
# Commands follow the openXC7 demo-projects openXC7.mk (yosys line, minus
# -abc9, which gives the same cells here) and the
# toolchain-openxc7-releases README (nextpnr -o options, fasm2frames,
# xc7frames2bit), checked against the installed tools.

PART   ?= xc7s50ftgb196-1
FAMILY ?= spartan7
TOP    := blinky
RTL    := rtl/blinky.v
XDC    := board/astria.xdc
BUILD  := build
DB     := $(PRJXRAY_DB_DIR)/$(FAMILY)
CABLE  := ft232

# Only LUTs, INV, FDRE, CARRY4, IO buffers and BUFG may appear in the netlist.
SYNTH_OPTS := -flatten -arch xc7 -nosrl -nobram -nolutram -nodsp -nowidelut

.DELETE_ON_ERROR:
.PHONY: all program check-cells proof test-prims mutation fasm-check route-check phys-check phys-mutation bit-check verify clean

all: $(BUILD)/$(TOP).bit check-cells

$(BUILD):
	mkdir -p $@

$(BUILD)/$(TOP).json: $(RTL) | $(BUILD)
	yosys -l $(BUILD)/yosys.log -p "synth_xilinx $(SYNTH_OPTS) -top $(TOP); write_json $@" $(RTL)

$(BUILD)/$(TOP).fasm: $(BUILD)/$(TOP).json $(XDC)
	nextpnr-xilinx --device $(PART) --json $< -o xdc=$(XDC) -o fasm=$@ \
	    --report $(BUILD)/report.json -l $(BUILD)/nextpnr.log

$(BUILD)/$(TOP).frames: $(BUILD)/$(TOP).fasm
	fasm2frames --part $(PART) --db-root $(DB) $< > $@

$(BUILD)/$(TOP).bit: $(BUILD)/$(TOP).frames
	xc7frames2bit --part_file $(DB)/$(PART)/part.yaml --part_name $(PART) \
	    --frm_file $< --output_file $@

# Fail if the netlist contains any cell type outside the allowed set.
check-cells: $(BUILD)/$(TOP).json
	@python3 -I -c 'import json,sys; \
	ok={"LUT1","LUT2","LUT3","LUT4","LUT5","LUT6","INV","FDRE","CARRY4","IBUF","OBUF","BUFG"}; \
	cells=json.load(open(sys.argv[1]))["modules"]["$(TOP)"]["cells"].values(); \
	types=sorted({c["type"] for c in cells}); bad=[t for t in types if t not in ok]; \
	print("cell types:", " ".join(types)); \
	sys.exit("disallowed cell types: " + " ".join(bad) if bad else 0)' $<

# Run the Lean proofs against the current netlist and FASM and record what
# they were run against. lake rebuilds the proofs whenever build/blinky.json
# or build/blinky.fasm changes (lean/lakefile.toml declares them as inputs),
# so PROOF.txt can only be written for the files that exist when the proofs
# succeed.
proof: $(BUILD)/$(TOP).json $(BUILD)/$(TOP).fasm $(BUILD)/$(TOP).bit
	cd lean && lake build
	{ echo "Proof run: $$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
	  echo; echo "SHA-256:"; sha256sum $(BUILD)/$(TOP).json $(BUILD)/$(TOP).fasm $(BUILD)/$(TOP).bit; \
	  echo; cd lean && lake env lean ../test/Audit.lean; } > $(BUILD)/PROOF.txt
	cat $(BUILD)/PROOF.txt

# Compare lean/VeryFPGA/Prims.lean with Yosys's cells_sim.v on every input.
test-prims: | $(BUILD)
	mkdir -p $(BUILD)/prims
	iverilog -g2012 -o $(BUILD)/prims/tb.vvp -s prims_tb test/prims_tb.v \
	    $(OSS_CAD_SUITE_ROOT)/share/yosys/xilinx/cells_sim.v
	vvp -n $(BUILD)/prims/tb.vvp > $(BUILD)/prims/vectors.txt
	cd lean && lake env lean ../test/PrimsTest.lean

# The proof must reject mutated copies of the netlist.
mutation: $(BUILD)/$(TOP).json
	cd lean && lake build
	test/mutation.sh

# M4a.1: every FASM feature parsed and found in the X-Ray database.
fasm-check: $(BUILD)/$(TOP).fasm
	cd lean && lake build
	cd lean && lake env lean ../test/FasmReport.lean

# M4a.2: physical wiring reconstructed; faulty FASM copies rejected.
route-check: $(BUILD)/$(TOP).fasm
	cd lean && lake build
	cd lean && lake lean ../test/RouteReport.lean
	test/route_mutation.sh

# M4a.3: the decoded design simulates like the specification; the site models
# refuse configurations they do not cover.
phys-check: $(BUILD)/$(TOP).fasm
	cd lean && lake build
	cd lean && lake lean ../test/PhysSim.lean
	test/phys_mutation.sh

# M4a.4: the routed-design proof must reject FASM copies with one logic change.
phys-mutation: $(BUILD)/$(TOP).fasm
	cd lean && lake build
	test/phys_proof_mutation.sh

# M4b: the bitstream decoded and compared with the FASM; faulty copies of the
# bitstream rejected by the reader or by the theorem.
bit-check: $(BUILD)/$(TOP).bit
	cd lean && lake build
	cd lean && lake lean ../test/BitReport.lean
	test/bit_mutation.sh

verify: all proof test-prims mutation fasm-check route-check phys-check phys-mutation bit-check

# SRAM load only; does not touch the configuration flash.
program: $(BUILD)/$(TOP).bit
	openFPGALoader -c $(CABLE) $<

clean:
	rm -rf $(BUILD)

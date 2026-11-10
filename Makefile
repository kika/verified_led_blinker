# Run with the tools from env.sh on PATH:  . ./env.sh && make
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
.PHONY: all program check-cells clean

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

# SRAM load only; does not touch the configuration flash.
program: $(BUILD)/$(TOP).bit
	openFPGALoader -c $(CABLE) $<

clean:
	rm -rf $(BUILD)

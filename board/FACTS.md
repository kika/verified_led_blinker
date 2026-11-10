# Board facts: Adiuvo Astria S7-50 (Leonidas PCB)

Sources, all in `boards/astria/` (a clone of
`https://bitbucket.org/adiuvo-engineering/leonidas_embedded_development`,
gitignored here):

- **[NET]** KiCad netlist export `Kicad_project/spartan7_dev_board/spartan7_dev_board.xml`
  (Eeschema 6.0.6, 2023-11-24). Traced pin to pin with a script; this is the
  primary source for connectivity.
- **[SCH]** `schematic/spartan7_dev_board.pdf` (KiCad PDF of the same design, 2023-11-24).
- **[XDC]** `xdc/io.xdc` (identical to `applications/S7_LEONIDAS/.../io.xdc`).
- **[BRD]** Vivado board files `board_defintion/board.xml`, `part0_pins.xml`.
- **[UG]** `user_manual/Leonidas_Userguide_1_0.pdf`.

## Important caveat: the vendor files describe the XC7S6 build

Every vendor file names `xc7s6ftgb196-1`: [SCH] symbol, [BRD] `part_name`, all
`.xpr` projects, and the header of the shipped `.bit`. The chip on Kirill's
board is marked XC7S50. [UG] p.12: "the foot print is compatible with Spartan 7
up to XC7S50". So the PCB is the same and the pin *locations* carry over, but:

- No vendor bitstream or project can be loaded on this board as-is.
- That each pin used below has the same function (bank, clock-capable) on the
  XC7S50 must be confirmed against the X-Ray package pin file for
  `xc7s50ftgb196` during M0. Status: **done 2026-11-10**. All 100 FPGA IO pins
  in [NET] match `prjxray-db/spartan7/xc7s50ftgb196-1/package_pins.csv` in
  pin, bank and pin function (prjxray-db `a8b09269`). G11 = `IOB_X0Y26`,
  `IO_L12P_T1_MRCC_14`; E11 = `IOB_X0Y49`, `IO_0_14`.
- That the Astria S7-50 uses this exact PCB revision is inferred (same package,
  same vendor repo), not documented. Status: **ask Kirill / confirm by testing
  LED and clock with a known design**.

## Facts

| Fact | Value | Source |
|---|---|---|
| Board | Adiuvo Astria S7-50, earlier name Leonidas. FPGA + RP2040, 4 user LEDs, 4 slide switches, 4 push buttons, SDRAM, Pmods | vendor product page; [UG] p.12 |
| FPGA part | XC7S50, **confirmed**: JTAG IDCODE `0x362f093`, reported by openFPGALoader v1.2.0 as xilinx / spartan7 / xc7s50, irlength 6 (2026-11-10) | chip marking; `openFPGALoader -c ft232 --detect` |
| Package | FTGB196 | chip marking; [SCH] footprint `Xilinx_FTGB196` |
| Speed grade | Assume -1. Vendor files say -1 but for the XC7S6. Not readable from marking. Part name for tools: `xc7s50ftgb196-1` | assumption |
| Chip marking | XC7S50 / FTGB196ABX2533 / D4BDT096A | photo from Kirill |
| Clock source | On-board oscillator U10, Kyocera KC2520Z100 (100 MHz), 3.3 V supply. Not from the RP2040 | [NET] U10; [BRD] "3.3V Single-Ended 100MHz oscillator" |
| Clock frequency | 100 MHz | [NET] part value `KC2520Z100`; [BRD] `frequency=100000000` |
| Clock path | U10.3 (CLK) -> R140 33 ohm series -> FPGA **G11**, `IO_L12P_T1_MRCC_14` (bank 14, clock-capable) | [NET] nets `Net-(R140-Pad1)`, `/FPGA IO/SYS_CLK` |
| Clock pin IO standard | LVCMOS33 | [XDC], [BRD] |
| Oscillator enable | U10.1 (INH) pulled to +3V3 through R137 1 k. No other connection, so nothing (RP2040 included) can stop the clock. Oscillator datasheet not checked for INH polarity; pull-up plus vendor designs working implies high = run | [NET] `Net-(R137-Pad2)` |
| User LED pins | LED0 **E11** (`IO_0_14`), LED1 **M10** (`IO_25_14`), LED2 **A10** (`IO_L3N_T0_DQS_EMCCLK_14`), LED3 **D12** (`IO_L8P_T1_D11_14`) | [NET] `/FPGA IO/LED0..3`; matches [XDC] `PMOD_LED_H[24..27]` and [BRD] `led_4bits_tri_o_0..3` |
| LED circuit and polarity | **Active high.** FPGA pin -> 110 ohm (R173/R171/R168/R163) -> LED anode, cathode to GND. About 12 mA at 3.3 V | [NET] `Net-(LEDn-Pad2)`, LEDn.1(K) on GND |
| LED IO standard | LVCMOS33 | [XDC], [BRD] |
| Bank voltages | VCCO_14 = +3V3 (G13, K13, N13); VCCO_34 = +3V3 (G2, K2, N2); VCCO_0 = +3V3 (N6, N8). CFGBVS_0 pulled to +3V3 via R36 1 k | [NET] net `+3V3` |
| JTAG interface | FTDI FT232HL (U2) on USB connector J1, MPSSE channel: ADBUS0=TCK, ADBUS1=TDI, ADBUS2=TDO, ADBUS3=TMS, each through a 0 ohm resistor (R37..R40). 93LC56 EEPROM (U4) holds the FTDI config. Only device on the chain | [NET] `/FPGA Core & Config/TCK..TMS`; [BRD] `jtag_chain` |
| openFPGALoader cable | **`-c ft232`, confirmed.** USB ID 0403:6014. Without `-c`, openFPGALoader defaults to an FT2232 and fails with "device not found". Works without root via `board/60-veryfpga-ft232h.rules` | inferred from [NET] |
| Config mode pins | M0 pulled up (R26 1 k), M1 pulled down (R27 1 k), M2 pulled up (R23) with jumper JP1 to GND. JP1 open: M=101, JTAG only. JP1 shorted: M=001, Master SPI from the IS25LP256 flash (U5). JTAG loading works in either setting | [NET]; [UG] p.16 |
| DONE LED | DONE_0 (P9) drives Q1 gate, Q1 sinks the DONE0 LED. Lights when configuration completes | [NET] |

## RP2040 sharing

The RP2040 (U7, USB connector J2) connects to the FPGA only through ten bank-14
pins, each via a 33 ohm series resistor (R64..R73):

| RP2040 | FPGA pin | FPGA pin name |
|---|---|---|
| GPIO0 | E13 | IO_L10N_T1_D15_14 |
| GPIO1 | C14 | IO_L11N_T1_SRCC_14 |
| GPIO2 | F11 | IO_L12N_T1_MRCC_14 |
| GPIO3 | F13 | IO_L10P_T1_D14_14 |
| GPIO4 | F12 | IO_L7P_T1_D09_14 |
| GPIO5 | F14 | IO_L9N_T1_DQS_D13_14 |
| GPIO6 | G14 | IO_L9P_T1_DQS_14 |
| GPIO7 | D13 | IO_L8N_T1_D12_14 |
| GPIO8 | E12 | IO_L7N_T1_D10_14 |
| GPIO9 | D14 | IO_L11P_T1_SRCC_14 |

GPIO10..17 go to Pmod J6 only (not to the FPGA). The RP2040 has **no**
connection to the clock net, the LED nets, JTAG, PROGRAM_B, INIT_B, DONE or the
mode pins [NET]. Blinky uses only G11 and one LED pin, so the RP2040 firmware
cannot interfere with it, and blinky must not drive any of the ten pins above.
Its stock firmware is therefore not a blocker for M1; it matters only for a
later design that uses those pins.

Source: [NET], search of all nets containing U7.

## Values chosen for blinky (M1)

- Clock: G11, LVCMOS33, 100 MHz.
- LED: LED0 on E11, LVCMOS33, active high.
- N = 27: period 2^27 / 100 MHz = 1.342 s, 50 % duty.

# Pin data: board/FACTS.md (KiCad netlist, vendor XDC, X-Ray package pins).

# 100 MHz oscillator U10 -> 33 ohm -> G11 (IO_L12P_T1_MRCC_14, bank 14, 3.3 V)
set_property PACKAGE_PIN G11 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
create_clock -period 10.000 [get_ports clk]

# LED0: E11 (IO_0_14, bank 14, 3.3 V) -> 110 ohm -> LED -> GND, active high
set_property PACKAGE_PIN E11 [get_ports led]
set_property IOSTANDARD LVCMOS33 [get_ports led]

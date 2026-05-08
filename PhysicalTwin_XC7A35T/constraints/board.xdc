set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

set_property PACKAGE_PIN D4 [get_ports clk_50mhz]
set_property IOSTANDARD LVCMOS33 [get_ports clk_50mhz]
create_clock -period 20.000 -name clk_50mhz [get_ports clk_50mhz]

set_property PACKAGE_PIN P10 [get_ports rst_sw]
set_property IOSTANDARD LVCMOS33 [get_ports rst_sw]

# Segment outputs: seg[0]=A, seg[1]=B, ..., seg[6]=G. Common-anode, active low.
set_property PACKAGE_PIN M4 [get_ports {seg[0]}]
set_property PACKAGE_PIN L5 [get_ports {seg[1]}]
set_property PACKAGE_PIN K3 [get_ports {seg[2]}]
set_property PACKAGE_PIN L2 [get_ports {seg[3]}]
set_property PACKAGE_PIN K2 [get_ports {seg[4]}]
set_property PACKAGE_PIN N3 [get_ports {seg[5]}]
set_property PACKAGE_PIN L4 [get_ports {seg[6]}]
set_property PACKAGE_PIN L3 [get_ports dp]
set_property IOSTANDARD LVCMOS33 [get_ports {seg[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports dp]

# Digit selects: an[0]=S0, ..., an[5]=S5. Common-anode assumption, active low.
set_property PACKAGE_PIN K1 [get_ports {an[0]}]
set_property PACKAGE_PIN K5 [get_ports {an[1]}]
set_property PACKAGE_PIN J1 [get_ports {an[2]}]
set_property PACKAGE_PIN J5 [get_ports {an[3]}]
set_property PACKAGE_PIN J4 [get_ports {an[4]}]
set_property PACKAGE_PIN H5 [get_ports {an[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {an[*]}]

# LEDs are constrained left to right: led[7] is leftmost, led[0] is rightmost.
set_property PACKAGE_PIN J3 [get_ports {led[7]}]
set_property PACKAGE_PIN H3 [get_ports {led[6]}]
set_property PACKAGE_PIN G5 [get_ports {led[5]}]
set_property PACKAGE_PIN D1 [get_ports {led[4]}]
set_property PACKAGE_PIN G4 [get_ports {led[3]}]
set_property PACKAGE_PIN F3 [get_ports {led[2]}]
set_property PACKAGE_PIN F4 [get_ports {led[1]}]
set_property PACKAGE_PIN E3 [get_ports {led[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]

# A build timed at 70 MHz (CPU_MHZ = 70) analysed again with the CPU's counter
# dividing by 7, as pll_cfg sets it for the OSD's 100 MHz: the same placement's
# worst slack and failing pairs per clock. Run in a compiled build's directory:
# quartus_sta.exe -t <repo>\syn\sta_at100.tcl
project_open MacPPC7300
create_timing_netlist
read_sdc
set cpu {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[1].output_counter|divclk}
create_generated_clock -name $cpu -source [get_pins {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[1].output_counter|vco0ph[0]}] \
	-master_clock {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|fpll_0|fpll|vcoph[0]} -divide_by 7 -duty_cycle 50 [get_pins $cpu]
derive_clock_uncertainty
# the clock groups again (MacPPC7300.sdc, sys_top.sdc), now with the new clock
set_clock_groups -asynchronous \
	-group [get_clocks {*|pll|pll_inst|altera_pll_i|*[0].*|divclk}] \
	-group [get_clocks {*|pll|pll_inst|altera_pll_i|*[1].*|divclk}] \
	-group [get_clocks {*|pll|pll_inst|altera_pll_i|*[2].*|divclk}]
set_clock_groups -exclusive \
	-group [get_clocks { *|pll|pll_inst|altera_pll_i|*[*].*|divclk}] \
	-group [get_clocks { pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
	-group [get_clocks { pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
	-group [get_clocks { spi_sck}] \
	-group [get_clocks { hdmi_sck}] \
	-group [get_clocks { *|h2f_user0_clk}] \
	-group [get_clocks { FPGA_CLK1_50 }] \
	-group [get_clocks { FPGA_CLK2_50 }] \
	-group [get_clocks { FPGA_CLK3_50 }]
update_timing_netlist
foreach_in_collection c [get_clocks {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[*].output_counter|divclk}] {
	set p [get_timing_paths -setup -to_clock $c -npaths 1]
	set s "none"
	foreach_in_collection q $p { set s [get_path_info $q -slack] }
	set f [get_timing_paths -setup -to_clock $c -npaths 20000 -pairs_only -less_than_slack 0]
	puts [format "%s period %.3f worst %s failing pairs %d" [get_clock_info -name $c] [get_clock_info -period $c] $s [get_collection_size $f]]
}

# Every failing setup path into the CPU's clock, one line per launch/latch pair:
# slack, from, to, logic levels, into cpupaths.txt. Run in a compiled build's
# directory: quartus_sta.exe -t <repo>\syn\sta_cpupaths.tcl
# (the reconfigurable PLL of 2026-10-15 names the CPU's clock counter[1]; the
# builds before it general[1].gpll~PLL_OUTPUT_COUNTER)
project_open MacPPC7300
create_timing_netlist
read_sdc
update_timing_netlist
set clk [get_clocks {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[1].output_counter|divclk}]
set paths [get_timing_paths -setup -to_clock $clk -npaths 20000 -pairs_only -less_than_slack 0]
set fh [open cpupaths.txt w]
foreach_in_collection p $paths {
	puts $fh [format "%.3f\t%s\t%s\t%d" [get_path_info $p -slack] [get_node_info -name [get_path_info $p -from]] [get_node_info -name [get_path_info $p -to]] [get_path_info $p -num_logic_levels]]
}
close $fh
puts "failing pairs: [get_collection_size $paths]"

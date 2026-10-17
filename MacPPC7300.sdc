derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# The core PLL's three outputs are unrelated clock domains: 0 the video and
# the debug readout (20 MHz), 1 the CPU and the machine, 2 the SDRAM, hps_io
# and the ROM upload (100 MHz). sys_top.sdc puts all three in one group, so
# without this every path between them would be timed as if they were
# related. What crosses is safe by construction:
#   CPU <-> memory: DSPPC604_memcdc (registers that stand still while a
#     toggle crosses through two flip-flops each way);
#   memory -> CPU: the reset and the RAM size and boot options, through two
#     flip-flops, and quasi-static (they change only with the reset held);
#   CPU <-> video: MacPPC7300_debug's snapshot (a request/acknowledge pair of
#     toggles, each through two flip-flops; the snapshot registers stand
#     still between them);
#   memory -> video: the status bits and RAM size, through two flip-flops.
# A 100 MHz-only build (syn/build.py 100) has the CPU's and the memory's
# counters merged into one: a group only for each counter that exists.
set pll_groups {}
foreach i {0 1 2} {
	set c [get_clocks -nowarn "*|pll|pll_inst|altera_pll_i|*\[$i\].*|divclk"]
	if {[get_collection_size $c] > 0} { lappend pll_groups -group $c }
}
set_clock_groups -asynchronous {*}$pll_groups

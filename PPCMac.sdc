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
#   CPU <-> video: PPCMac_debug's snapshot (a request/acknowledge pair of
#     toggles, each through two flip-flops; the snapshot registers stand
#     still between them);
#   memory -> video: the status bits and RAM size, through two flip-flops.
set_clock_groups -asynchronous \
	-group [get_clocks {*|pll|pll_inst|altera_pll_i|*[0].*|divclk}] \
	-group [get_clocks {*|pll|pll_inst|altera_pll_i|*[1].*|divclk}] \
	-group [get_clocks {*|pll|pll_inst|altera_pll_i|*[2].*|divclk}]

// The Cuda bench's top: Cuda (PPCMac_cuda) with the ADB devices (PPCMac_adb)
// on its ADB line, as PPCMac_machine connects them; every other port of
// Cuda's is the bench's. adb_line is the wire, for the bench to watch.

module cuda_tb_top
#(
	parameter int unsigned CLK_HZ = 65_000_000
)
(
	input  logic        clk,
	input  logic        reset,

	input  logic        via_tip,
	input  logic        via_byteack,
	output logic        treq,
	output logic        cb1,
	output logic        cb2_oe,
	output logic        cb2_out,
	input  logic        cb2,

	output logic        cpu_reset,
	output logic        adb_low,         // Cuda pulls the ADB line low
	output logic        adb_dev_low,     // a device does
	output logic        adb_line,        // the wire
	output logic        iic_scl_low,
	output logic        iic_sda_low,
	input  logic        iic_scl,
	input  logic        iic_sda,

	input  logic [10:0] ps2_key,
	input  logic [24:0] ps2_mouse,
	input  logic [51:0] joy,

	output logic        dbg_cen,
	output logic [12:0] dbg_addr,
	output logic        dbg_rd,
	output logic        dbg_wr,
	output logic [7:0]  dbg_wdata,
	output logic [7:0]  dbg_rdata,
	output logic        tr_valid,
	output logic        tr_int,
	output logic [12:0] tr_pc,
	output logic [7:0]  tr_op,
	output logic [7:0]  tr_a,
	output logic [7:0]  tr_x,
	output logic [7:0]  tr_sp,
	output logic [7:0]  tr_cc,
	output logic        dbg_cpi,
	output logic        dbg_fast
);

logic tick;
assign adb_line = ~(adb_low | adb_dev_low);

PPCMac_cuda #(.CLK_HZ(CLK_HZ)) cuda (
	.clk, .reset,
	.via_tip, .via_byteack, .treq, .cb1, .cb2_oe, .cb2_out, .cb2,
	.cpu_reset, .adb_low, .adb_line, .tick,
	/* verilator lint_off PINCONNECTEMPTY */
	.nmi(),
	/* verilator lint_on PINCONNECTEMPTY */
	.clock_ok(1'b0), .clock_secs(32'h0),
	.iic_scl_low, .iic_sda_low, .iic_scl, .iic_sda,
	.dbg_cen, .dbg_addr, .dbg_rd, .dbg_wr, .dbg_wdata, .dbg_rdata,
	.tr_valid, .tr_int, .tr_pc, .tr_op, .tr_a, .tr_x, .tr_sp, .tr_cc,
	.dbg_cpi, .dbg_fast
);

PPCMac_adb adb (
	.clk, .reset, .tick, .host_low(adb_low), .dev_low(adb_dev_low),
	.ps2_key, .ps2_mouse, .joy,
	/* verilator lint_off PINCONNECTEMPTY */
	.tr_ev(), .tr_info()
	/* verilator lint_on PINCONNECTEMPTY */
);

endmodule

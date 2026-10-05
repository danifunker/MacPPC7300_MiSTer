//============================================================================
//
//  Synthesis-only wrapper for the area and timing check of the DSPPC604
//  pipeline (syn/check.py core).
//
//  Bus inputs and outputs are registered here, standing in for the caches
//  that will sit on these buses. The retirement trace is left unconnected,
//  as it will be in a real build.
//
//============================================================================

module DSPPC604_check_core
(
	input  logic        clk,
	input  logic        i_reset,
	input  logic [31:0] i_reset_pc,

	input  logic        i_ibus_gnt,
	input  logic        i_ibus_rvalid,
	input  logic [31:0] i_ibus_rdata,
	input  logic        i_dbus_gnt,
	input  logic        i_dbus_rvalid,
	input  logic [31:0] i_dbus_rdata,

	output logic        o_ibus_req,
	output logic [31:0] o_ibus_addr,
	output logic        o_dbus_req,
	output logic        o_dbus_we,
	output logic [29:0] o_dbus_addr,
	output logic [3:0]  o_dbus_be,
	output logic [31:0] o_dbus_wdata,
	output logic        o_halted
);

logic        reset_q;
logic [31:0] reset_pc_q;
logic        ibus_gnt_q, ibus_rvalid_q, dbus_gnt_q, dbus_rvalid_q;
logic [31:0] ibus_rdata_q, dbus_rdata_q;

logic        ibus_req, dbus_req, dbus_we, halted;
logic [31:0] ibus_addr, dbus_wdata;
logic [29:0] dbus_addr;
logic [3:0]  dbus_be;

always_ff @(posedge clk) begin
	reset_q       <= i_reset;
	reset_pc_q    <= i_reset_pc;
	ibus_gnt_q    <= i_ibus_gnt;
	ibus_rvalid_q <= i_ibus_rvalid;
	ibus_rdata_q  <= i_ibus_rdata;
	dbus_gnt_q    <= i_dbus_gnt;
	dbus_rvalid_q <= i_dbus_rvalid;
	dbus_rdata_q  <= i_dbus_rdata;

	o_ibus_req    <= ibus_req;
	o_ibus_addr   <= ibus_addr;
	o_dbus_req    <= dbus_req;
	o_dbus_we     <= dbus_we;
	o_dbus_addr   <= dbus_addr;
	o_dbus_be     <= dbus_be;
	o_dbus_wdata  <= dbus_wdata;
	o_halted      <= halted;
end

/* verilator lint_off PINCONNECTEMPTY */
DSPPC604 cpu
(
	.clk           (clk),
	.reset         (reset_q),
	.reset_pc      (reset_pc_q),
	.ibus_req      (ibus_req),
	.ibus_addr     (ibus_addr),
	.ibus_gnt      (ibus_gnt_q),
	.ibus_rvalid   (ibus_rvalid_q),
	.ibus_rdata    (ibus_rdata_q),
	.dbus_req      (dbus_req),
	.dbus_we       (dbus_we),
	.dbus_addr     (dbus_addr),
	.dbus_be       (dbus_be),
	.dbus_wdata    (dbus_wdata),
	.dbus_gnt      (dbus_gnt_q),
	.dbus_rvalid   (dbus_rvalid_q),
	.dbus_rdata    (dbus_rdata_q),
	.halted        (halted),
	.halt_pc       (),
	.trace_valid   (),
	.trace_last    (),
	.trace_pc      (),
	.trace_insn    (),
	.trace_reg_we  (),
	.trace_reg_idx (),
	.trace_reg_val (),
	.trace_cr      (),
	.trace_xer     (),
	.trace_lr      (),
	.trace_ctr     (),
	.trace_fpscr   ()
);
/* verilator lint_on PINCONNECTEMPTY */

endmodule

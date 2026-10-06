//============================================================================
//
//  Synthesis-only wrapper for the area and timing check of the DSPPC604
//  pipeline (syn/check.py core).
//
//  The memory and snoop ports are registered here, standing in for the
//  clock crossing to the SDRAM controller. The retirement trace is left
//  unconnected, as it will be in a real build.
//
//============================================================================

module DSPPC604_check_core
(
	input  logic         clk,
	input  logic         i_reset,
	input  logic [31:0]  i_reset_pc,

	input  logic         i_mem_ack,
	input  logic [255:0] i_mem_rdata,
	output logic         o_mem_req,
	output logic         o_mem_we,
	output logic         o_mem_line,
	output logic [31:2]  o_mem_addr,
	output logic [3:0]   o_mem_be,
	output logic [255:0] o_mem_wdata,

	input  logic         i_snoop_req,
	input  logic         i_snoop_we,
	input  logic [31:5]  i_snoop_addr,
	output logic         o_snoop_ack,

	input  logic         i_ext_irq,
	input  logic         i_tb_tick
);

logic         reset_q;
logic [31:0]  reset_pc_q;
logic         mem_ack_q, snoop_req_q, snoop_we_q;
logic [255:0] mem_rdata_q;
logic [31:5]  snoop_addr_q;
logic         ext_irq_q, tb_tick_q;

logic         mem_req, mem_we, mem_line, snoop_ack;
logic [31:2]  mem_addr;
logic [3:0]   mem_be;
logic [255:0] mem_wdata;

always_ff @(posedge clk) begin
	reset_q      <= i_reset;
	reset_pc_q   <= i_reset_pc;
	ext_irq_q    <= i_ext_irq;
	tb_tick_q    <= i_tb_tick;
	mem_ack_q    <= i_mem_ack;
	mem_rdata_q  <= i_mem_rdata;
	snoop_req_q  <= i_snoop_req;
	snoop_we_q   <= i_snoop_we;
	snoop_addr_q <= i_snoop_addr;

	o_mem_req    <= mem_req;
	o_mem_we     <= mem_we;
	o_mem_line   <= mem_line;
	o_mem_addr   <= mem_addr;
	o_mem_be     <= mem_be;
	o_mem_wdata  <= mem_wdata;
	o_snoop_ack  <= snoop_ack;
end

/* verilator lint_off PINCONNECTEMPTY */
DSPPC604 cpu
(
	.clk           (clk),
	.reset         (reset_q),
	.reset_pc      (reset_pc_q),
	.ext_irq       (ext_irq_q),
	.tb_tick       (tb_tick_q),
	.mem_req       (mem_req),
	.mem_we        (mem_we),
	.mem_line      (mem_line),
	.mem_addr      (mem_addr),
	.mem_be        (mem_be),
	.mem_wdata     (mem_wdata),
	.mem_ack       (mem_ack_q),
	.mem_rdata     (mem_rdata_q),
	.snoop_req     (snoop_req_q),
	.snoop_we      (snoop_we_q),
	.snoop_addr    (snoop_addr_q),
	.snoop_ack     (snoop_ack),
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
	.trace_fpscr   (),
	.trace_msr     (),
	.trace_dreq    (),
	.trace_dwe     (),
	.trace_dkind   (),
	.trace_daddr   (),
	.trace_dbe     (),
	.trace_dwdata  ()
);
/* verilator lint_on PINCONNECTEMPTY */

endmodule

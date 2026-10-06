//============================================================================
//
//  PPCMac - the machine around the CPU
//  The CPU, the machine and the clock crossing to memory, as one block
//
//    DSPPC604 --(memory port)--> PPCMac_machine --(RAM, ROM)--> DSPPC604_memcdc --> b_*
//
//  Everything left of the crossing runs in the CPU's clock; b_* is the same
//  port protocol in the memory's clock, addressed by SDRAM offset, for the
//  SDRAM controller (or the test bench's memory). The MiSTer top and the
//  test bench both instantiate this block, so the bench runs the machine
//  exactly as the FPGA does.
//
//  The CPU's retirement trace and its memory port are brought out for the
//  test bench and the debug readout; a build that does not use them leaves
//  them unconnected.
//
//============================================================================

module PPCMac_system
#(
	parameter int unsigned CPU_HZ   = 65_000_000,
	parameter int unsigned TB_HZ    = 12_500_000,
	parameter int unsigned SDRAM_MB = 128
)
(
	input  logic         clk,             // the CPU's clock
	input  logic         reset,           // in the CPU's clock
	input  logic [31:0]  reset_pc,
	input  logic [7:0]   ram_mb,          // installed RAM, at most SDRAM_MB - 4
	input  logic         boot_memtest,    // the memory test in place of the ROM

	// memory, in the memory's clock, by SDRAM offset
	input  logic         clk_b,
	input  logic         reset_b,
	output logic         b_req,
	output logic         b_we,
	output logic         b_line,
	output logic [31:2]  b_addr,
	output logic [3:0]   b_be,
	output logic [255:0] b_wdata,
	input  logic         b_ack,
	input  logic [255:0] b_rdata,

	// the CPU's memory port, as the machine sees it
	output logic         cpu_req,
	output logic         cpu_we,
	output logic         cpu_line,
	output logic [31:2]  cpu_addr,
	output logic [3:0]   cpu_be,
	output logic [255:0] cpu_wdata,
	output logic         cpu_ack,
	output logic [255:0] cpu_rdata,
	output logic         cpu_irq,
	output logic         cpu_tb_tick,

	// the machine's debug registers (the memory test's report)
	output logic [31:0]  dbg_status,
	output logic [31:0]  dbg_passes,
	output logic [31:0]  dbg_errors,
	output logic [31:0]  dbg_first,

	// the CPU's retirement trace (see DSPPC604)
	output logic         trace_valid,
	output logic         trace_last,
	output logic [31:0]  trace_pc,
	output logic [31:0]  trace_insn,
	output logic         trace_reg_we,
	output logic [6:0]   trace_reg_idx,
	output logic [63:0]  trace_reg_val,
	output logic [31:0]  trace_cr,
	output logic [31:0]  trace_xer,
	output logic [31:0]  trace_lr,
	output logic [31:0]  trace_ctr,
	output logic [31:0]  trace_fpscr,
	output logic [31:0]  trace_msr,
	output logic         trace_dreq,
	output logic         trace_dwe,
	output logic [2:0]   trace_dkind,
	output logic [31:2]  trace_daddr,
	output logic [3:0]   trace_dbe,
	output logic [31:0]  trace_dwdata
);

logic         c_req, c_we, c_line, c_ack;
logic [31:2]  c_addr;
logic [3:0]   c_be;
logic [255:0] c_wdata, c_rdata;
logic         m_req, m_we, m_line, m_ack;
logic [31:2]  m_addr;
logic [3:0]   m_be;
logic [255:0] m_wdata, m_rdata;
logic         ext_irq, tb_tick;
logic         snoop_ack;          // unused until something else masters memory

DSPPC604 cpu (
	.clk, .reset, .reset_pc,
	.ext_irq, .tb_tick,
	.mem_req(c_req), .mem_we(c_we), .mem_line(c_line), .mem_addr(c_addr), .mem_be(c_be),
	.mem_wdata(c_wdata), .mem_ack(c_ack), .mem_rdata(c_rdata),
	// nothing else masters memory yet
	.snoop_req(1'b0), .snoop_we(1'b0), .snoop_addr(27'h0), .snoop_ack,
	.trace_valid, .trace_last, .trace_pc, .trace_insn, .trace_reg_we, .trace_reg_idx, .trace_reg_val,
	.trace_cr, .trace_xer, .trace_lr, .trace_ctr, .trace_fpscr, .trace_msr,
	.trace_dreq, .trace_dwe, .trace_dkind, .trace_daddr, .trace_dbe, .trace_dwdata
);

PPCMac_machine #(.CPU_HZ(CPU_HZ), .TB_HZ(TB_HZ), .SDRAM_MB(SDRAM_MB)) machine (
	.clk, .reset, .ram_mb, .boot_memtest,
	.c_req, .c_we, .c_line, .c_addr, .c_be, .c_wdata, .c_ack, .c_rdata,
	.m_req, .m_we, .m_line, .m_addr, .m_be, .m_wdata, .m_ack, .m_rdata,
	.ext_irq, .tb_tick,
	.dbg_status, .dbg_passes, .dbg_errors, .dbg_first
);

DSPPC604_memcdc cdc (
	.clk_a(clk), .reset_a(reset),
	.a_req(m_req), .a_we(m_we), .a_line(m_line), .a_addr(m_addr), .a_be(m_be), .a_wdata(m_wdata),
	.a_ack(m_ack), .a_rdata(m_rdata),
	.clk_b, .reset_b,
	.b_req, .b_we, .b_line, .b_addr, .b_be, .b_wdata, .b_ack, .b_rdata
);

assign cpu_req     = c_req;
assign cpu_we      = c_we;
assign cpu_line    = c_line;
assign cpu_addr    = c_addr;
assign cpu_be      = c_be;
assign cpu_wdata   = c_wdata;
assign cpu_ack     = c_ack;
assign cpu_rdata   = c_rdata;
assign cpu_irq     = ext_irq;
assign cpu_tb_tick = tb_tick;

endmodule

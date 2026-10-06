// The SDRAM controller's test bench top: the CPU's memory port through the
// clock crossing into PPCMac_sdram, whose pins go to the C++ chip model in
// sdram_main.cpp (the data bus split into its two directions).

module sdram_tb_top
(
	// the CPU's side of the crossing
	input  logic         clk_a,
	input  logic         reset_a,
	input  logic         a_req,
	input  logic         a_we,
	input  logic         a_line,
	input  logic [31:2]  a_addr,
	input  logic [3:0]   a_be,
	input  logic [255:0] a_wdata,
	output logic         a_ack,
	output logic [255:0] a_rdata,

	// the memory clock: the controller and the upload
	input  logic         clk_b,
	input  logic         init,
	output logic         ready,
	input  logic         up_wr,
	input  logic [26:0]  up_addr,
	input  logic [7:0]   up_data,
	output logic         up_busy,

	// the chip
	output logic [12:0]  SDRAM_A,
	output logic [1:0]   SDRAM_BA,
	output logic         SDRAM_nCS,
	output logic         SDRAM_nRAS,
	output logic         SDRAM_nCAS,
	output logic         SDRAM_nWE,
	output logic         SDRAM_DQML,
	output logic         SDRAM_DQMH,
	output logic         SDRAM_CKE,
	output logic [15:0]  dq_out,
	output logic         dq_oe,
	input  logic [15:0]  dq_in
);

logic         b_req, b_we, b_line, b_ack;
logic [31:2]  b_addr;
logic [3:0]   b_be;
logic [255:0] b_wdata, b_rdata;

DSPPC604_memcdc cdc (
	.clk_a, .reset_a, .a_req, .a_we, .a_line, .a_addr, .a_be, .a_wdata, .a_ack, .a_rdata,
	.clk_b, .reset_b(init),
	.b_req, .b_we, .b_line, .b_addr, .b_be, .b_wdata, .b_ack, .b_rdata
);

PPCMac_sdram #(.CLK_MHZ(100)) sdram (
	.clk(clk_b), .init, .ready,
	.req(b_req), .we(b_we), .line(b_line), .addr(b_addr[26:2]), .be(b_be), .wdata(b_wdata),
	.ack(b_ack), .rdata(b_rdata),
	.up_wr, .up_addr, .up_data, .up_busy,
	.SDRAM_A, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nRAS, .SDRAM_nCAS, .SDRAM_nWE,
	.SDRAM_DQML, .SDRAM_DQMH, .SDRAM_CKE, .dq_out, .dq_oe, .dq_in
);

endmodule

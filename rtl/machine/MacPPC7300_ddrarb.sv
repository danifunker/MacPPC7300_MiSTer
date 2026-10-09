//============================================================================
//
//  MacPPC7300 - the machine around the CPU
//  The DDR3 port shared: the video (A, first) and the network bridge (B)
//
//  The owner changes only between transfers: when the owner asks for
//  nothing and no read's words are still to come (a command held against
//  busy is never taken away). A read is the owner's until its last word, a
//  write burst until its last word goes.
//
//============================================================================

module MacPPC7300_ddrarb
(
	input  logic        clk,
	input  logic        reset,

	output logic        a_busy,
	input  logic [7:0]  a_burstcnt,
	input  logic [28:0] a_addr,
	output logic        a_dout_ready,
	input  logic        a_rd,
	input  logic [63:0] a_din,
	input  logic [7:0]  a_be,
	input  logic        a_we,

	output logic        b_busy,
	input  logic [7:0]  b_burstcnt,
	input  logic [28:0] b_addr,
	output logic        b_dout_ready,
	input  logic        b_rd,
	input  logic [63:0] b_din,
	input  logic [7:0]  b_be,
	input  logic        b_we,

	input  logic        ddr_busy,
	output logic [7:0]  ddr_burstcnt,
	output logic [28:0] ddr_addr,
	input  logic        ddr_dout_ready,
	output logic        ddr_rd,
	output logic [63:0] ddr_din,
	output logic [7:0]  ddr_be,
	output logic        ddr_we
);

logic       own;                        // 0 A, 1 B
logic [8:0] left;                       // a transfer's words still to come or go

assign ddr_burstcnt = own ? b_burstcnt : a_burstcnt;
assign ddr_addr     = own ? b_addr     : a_addr;
assign ddr_rd       = own ? b_rd       : a_rd;
assign ddr_din      = own ? b_din      : a_din;
assign ddr_be       = own ? b_be       : a_be;
assign ddr_we       = own ? b_we       : a_we;
assign a_busy       = own | ddr_busy;
assign b_busy       = ~own | ddr_busy;
assign a_dout_ready = ~own & ddr_dout_ready;
assign b_dout_ready = own & ddr_dout_ready;

wire asks = own ? (b_rd | b_we) : (a_rd | a_we);
wire take = asks & ~ddr_busy;           // a word or a command goes

always_ff @(posedge clk) begin
	if (take && ddr_rd)
		left <= {1'b0, ddr_burstcnt};
	else if (take && ddr_we)
		left <= (left == 9'd0) ? {1'b0, ddr_burstcnt} - 9'd1 : left - 9'd1;
	else if (ddr_dout_ready && left != 9'd0)
		left <= left - 9'd1;
	if (!asks && left == 9'd0) begin
		if (a_rd | a_we)      own <= 1'b0;
		else if (b_rd | b_we) own <= 1'b1;
	end
	if (reset) begin
		own  <= 1'b0;
		left <= 9'd0;
	end
end

endmodule

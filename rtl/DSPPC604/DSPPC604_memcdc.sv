//============================================================================
//
//  DSPPC604 - PowerPC 604-class CPU core
//  The memory port across a clock boundary
//
//  Carries the CPU's memory port (one line or word, request held until
//  acknowledged, one outstanding) from the CPU's clock into the memory
//  controller's, and the answer back. The request and its write data are
//  captured once, in registers that then stand still while a toggle crosses
//  into the memory clock; the read data is captured in the memory clock and
//  stands still while a toggle crosses back. Nothing that moves ever crosses
//  the boundary except the two toggles, each through two flip-flops.
//
//  Latency: about two cycles of each clock in each direction, on top of the
//  memory's own. The protocol on both sides is the CPU's port's.
//
//  Not specific to this CPU model; any later model with the same port uses it.
//
//============================================================================

module DSPPC604_memcdc
(
	// the CPU's side
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

	// the memory's side
	input  logic         clk_b,
	input  logic         reset_b,
	output logic         b_req,
	output logic         b_we,
	output logic         b_line,
	output logic [31:2]  b_addr,
	output logic [3:0]   b_be,
	output logic [255:0] b_wdata,
	input  logic         b_ack,
	input  logic [255:0] b_rdata
);

// ---- the CPU's side -----------------------------------------------------------
logic         a_busy;         // a request has been sent and not answered
logic         a_tog;          // flips with every request sent
logic         a_ack_sync1, a_ack_sync2, a_ack_seen;
logic [255:0] b_data_q;       // the answer, in the memory's clock (read below)

// the request, standing still from the toggle until the answer
logic         q_we, q_line;
logic [31:2]  q_addr;
logic [3:0]   q_be;
logic [255:0] q_wdata;

wire a_answer = a_ack_sync2 ^ a_ack_seen;

always_ff @(posedge clk_a) begin
	a_ack <= 1'b0;
	// (not in the cycle an answer goes out: the request still up then is
	// the one just answered)
	if (~a_busy & a_req & ~a_ack) begin
		q_we    <= a_we;
		q_line  <= a_line;
		q_addr  <= a_addr;
		q_be    <= a_be;
		q_wdata <= a_wdata;
		a_tog   <= ~a_tog;
		a_busy  <= 1'b1;
	end
	if (a_busy & a_answer) begin
		a_busy    <= 1'b0;
		a_ack     <= 1'b1;
		a_rdata   <= b_data_q;
		a_ack_seen <= a_ack_sync2;
	end
	if (reset_a) begin
		a_busy     <= 1'b0;
		a_tog      <= 1'b0;
		a_ack      <= 1'b0;
		a_ack_seen <= 1'b0;
	end
end

// ---- the memory's side --------------------------------------------------------
logic b_req_sync1, b_req_sync2, b_req_seen;
logic b_tog;                  // flips with every answer
logic b_busy;

wire b_arrival = b_req_sync2 ^ b_req_seen;

always_ff @(posedge clk_b) begin
	if (~b_busy & b_arrival) begin
		b_busy     <= 1'b1;
		b_req_seen <= b_req_sync2;
	end
	if (b_busy & b_ack) begin
		b_busy   <= 1'b0;
		b_data_q <= b_rdata;
		b_tog    <= ~b_tog;
	end
	if (reset_b) begin
		b_busy     <= 1'b0;
		b_req_seen <= 1'b0;
		b_tog      <= 1'b0;
	end
end

assign b_req   = b_busy;
assign b_we    = q_we;
assign b_line  = q_line;
assign b_addr  = q_addr;
assign b_be    = q_be;
assign b_wdata = q_wdata;

// ---- the two toggles, each through two flip-flops of the other clock ----------
always_ff @(posedge clk_b) begin
	b_req_sync1 <= a_tog;
	b_req_sync2 <= b_req_sync1;
	if (reset_b) begin
		b_req_sync1 <= 1'b0;
		b_req_sync2 <= 1'b0;
	end
end

always_ff @(posedge clk_a) begin
	a_ack_sync1 <= b_tog;
	a_ack_sync2 <= a_ack_sync1;
	if (reset_a) begin
		a_ack_sync1 <= 1'b0;
		a_ack_sync2 <= 1'b0;
	end
end

endmodule

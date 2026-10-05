//============================================================================
//
//  DSPPC604 - PowerPC 604-class CPU core
//  Integer multiplier: 32 x 32 -> 64, signed or unsigned
//
//  Two register stages so the multiply maps onto the FPGA's DSP blocks with
//  registers on both sides. The product is valid two clocks after load.
//
//============================================================================

module DSPPC604_mul
(
	input  logic        clk,
	input  logic        load,        // capture the operands
	input  logic        is_signed,
	input  logic [31:0] a,
	input  logic [31:0] b,
	output logic [63:0] product
);

logic signed [32:0] a_q;
logic signed [32:0] b_q;
logic signed [65:0] p_q;

always_ff @(posedge clk) begin
	if (load) begin
		a_q <= {is_signed & a[31], a};
		b_q <= {is_signed & b[31], b};
	end
	p_q <= a_q * b_q;
end

assign product = p_q[63:0];

endmodule

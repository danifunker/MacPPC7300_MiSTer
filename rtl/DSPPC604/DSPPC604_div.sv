//============================================================================
//
//  DSPPC604 - PowerPC 604-class CPU core
//  Integer divider: 32 / 32, signed or unsigned, one quotient bit per clock
//
//  The architecture leaves the quotient undefined for a zero divisor and for
//  0x80000000 / -1. This divider returns what a real PowerPC 604 (PVR
//  00040303) returns in those cases:
//
//    divisor zero        : dividend shifted left four bits, low four bits
//                          0000 for a negative signed dividend, else 1111
//    0x80000000 / -1     : 1
//
//  Both set overflow.
//
//============================================================================

module DSPPC604_div
(
	input  logic        clk,
	input  logic        reset,
	input  logic        start,       // one clock, with the operands
	input  logic        abort,
	input  logic        is_signed,
	input  logic [31:0] a,           // dividend
	input  logic [31:0] b,           // divisor

	output logic        done,        // one clock, with the results
	output logic [31:0] quotient,
	output logic        overflow
);

typedef enum logic [1:0] {
	S_IDLE,
	S_RUN,
	S_FIX,
	S_DONE
} state_t;

state_t      state;
logic [4:0]  count;
logic [31:0] rem;
logic [31:0] quo;        // dividend shifts out of the top, quotient into the bottom
logic [31:0] dvs;
logic        neg;

wire        a_neg = is_signed & a[31];
wire        b_neg = is_signed & b[31];
wire [31:0] a_mag = a_neg ? (32'd0 - a) : a;
wire [31:0] b_mag = b_neg ? (32'd0 - b) : b;

wire        by_zero  = (b == 32'd0);
wire        too_big  = is_signed & (a == 32'h80000000) & (b == 32'hFFFFFFFF);

// one restoring step
wire [32:0] rem_sh = {rem, quo[31]};
wire [33:0] diff   = {1'b0, rem_sh} - {2'b00, dvs};
wire        fits   = ~diff[33];

always_ff @(posedge clk) begin
	case (state)
	S_IDLE: begin
		if (start) begin
			rem      <= 32'd0;
			quo      <= a_mag;
			dvs      <= b_mag;
			neg      <= a_neg ^ b_neg;
			count    <= 5'd31;
			overflow <= by_zero | too_big;
			if (by_zero) begin
				quotient <= {a[27:0], a_neg ? 4'h0 : 4'hF};
				state    <= S_DONE;
			end
			else if (too_big) begin
				quotient <= 32'd1;
				state    <= S_DONE;
			end
			else begin
				state <= S_RUN;
			end
		end
	end

	S_RUN: begin
		rem   <= fits ? diff[31:0] : rem_sh[31:0];
		quo   <= {quo[30:0], fits};
		count <= count - 5'd1;
		if (count == 5'd0) state <= S_FIX;
	end

	S_FIX: begin
		quotient <= neg ? (32'd0 - quo) : quo;
		state    <= S_DONE;
	end

	default: begin // S_DONE
		state <= S_IDLE;
	end
	endcase

	if (reset | abort) state <= S_IDLE;
end

assign done = (state == S_DONE);

endmodule

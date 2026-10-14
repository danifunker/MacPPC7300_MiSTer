//============================================================================
//
//  DSPPC604 - PowerPC 604-class CPU core
//  Integer divider: 32 / 32, signed or unsigned, four quotient bits per
//  clock (two radix-4 steps in cascade), the dividend's leading zero pairs
//  skipped, and the quotient's leading zero digits that the divisor's size
//  guarantees (3-11 clocks from start to done)
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
	input  logic        ack,         // results taken
	input  logic        is_signed,
	input  logic [31:0] a,           // dividend
	input  logic [31:0] b,           // divisor

	output logic        done,        // held, with the results, until ack
	output logic [31:0] quotient,
	output logic        overflow
);

typedef enum logic [2:0] {
	S_IDLE,
	S_PRE,
	S_RUN,
	S_FIX,
	S_DONE
} state_t;

state_t      state;
logic [3:0]  count;      // radix-4 steps left, less one
logic [31:0] rem;
logic [31:0] quo;        // dividend shifts out of the top, quotient into the bottom
logic [31:0] dvs;
logic [33:0] dvs3;       // three times the divisor
logic        neg;

wire        a_neg = is_signed & a[31];
wire        b_neg = is_signed & b[31];
wire [31:0] a_mag = a_neg ? (32'd0 - a) : a;
wire [31:0] b_mag = b_neg ? (32'd0 - b) : b;

wire        by_zero  = (b == 32'd0);
wire        too_big  = is_signed & (a == 32'h80000000) & (b == 32'hFFFFFFFF);

// The dividend's leading zero pairs give zero quotient digits with the
// remainder staying zero: shift them out and run only the steps left.
logic [3:0] lz_pairs;    // leading zero bit pairs of quo, 0-15
always_comb begin
	lz_pairs = 4'd15;
	for (int i = 0; i < 15; i++)
		if (quo[31 - 2*i -: 2] != 2'b00 && lz_pairs == 4'd15) lz_pairs = 4'(i);
end
wire quo_zero = (quo == 32'd0);

// While the partial remainder holds fewer bits than the divisor's top one,
// the digit is zero: with B significant divisor bits, the first
// floor((B - 1) / 2) steps only move dividend bits into the remainder.
// Do them at once (at most all the steps left).
logic [5:0] lz_b;                        // leading zeros of the divisor (nonzero here)
DSPPC604_lzc #(.WIDTH(32)) dvs_lzc (.in(dvs), .count(lz_b));
wire [4:0]  steps   = 5'd16 - {1'b0, lz_pairs};
wire [4:0]  t0      = (5'd31 - lz_b[4:0]) >> 1;              // floor((B - 1) / 2), B = 32 - lz_b
wire [4:0]  skip    = (t0 < steps) ? t0 : steps;
wire [5:0]  pre_sh  = {1'b0, lz_pairs, 1'b0} + {skip, 1'b0};   // dividend bits moved: 2 * (pairs + skip)
wire [63:0] pre_rq  = {32'd0, quo} << pre_sh;

// one radix-4 restoring step: the largest of 0-3 divisors that fits, all
// three tried in parallel (rem < dvs, so rem_sh < 4 * dvs)
wire [33:0] rem_sh = {rem, quo[31:30]};
wire [34:0] diff1  = {1'b0, rem_sh} - {3'b000, dvs};
wire [34:0] diff2  = {1'b0, rem_sh} - {2'b00, dvs, 1'b0};
wire [34:0] diff3  = {1'b0, rem_sh} - {1'b0, dvs3};
wire [1:0]  digit  = ~diff3[34] ? 2'd3 : ~diff2[34] ? 2'd2 : ~diff1[34] ? 2'd1 : 2'd0;
wire [31:0] rem_nx = ~diff3[34] ? diff3[31:0] : ~diff2[34] ? diff2[31:0] :
                     ~diff1[34] ? diff1[31:0] : rem_sh[31:0];

// the next step behind it, in the same clock
wire [33:0] rem_sh_b = {rem_nx, quo[29:28]};
wire [34:0] diff1_b  = {1'b0, rem_sh_b} - {3'b000, dvs};
wire [34:0] diff2_b  = {1'b0, rem_sh_b} - {2'b00, dvs, 1'b0};
wire [34:0] diff3_b  = {1'b0, rem_sh_b} - {1'b0, dvs3};
wire [1:0]  digit_b  = ~diff3_b[34] ? 2'd3 : ~diff2_b[34] ? 2'd2 : ~diff1_b[34] ? 2'd1 : 2'd0;
wire [31:0] rem_nx_b = ~diff3_b[34] ? diff3_b[31:0] : ~diff2_b[34] ? diff2_b[31:0] :
                       ~diff1_b[34] ? diff1_b[31:0] : rem_sh_b[31:0];

always_ff @(posedge clk) begin
	case (state)
	S_IDLE: begin
		if (start) begin
			rem      <= 32'd0;
			quo      <= a_mag;
			dvs      <= b_mag;
			neg      <= a_neg ^ b_neg;
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
				state <= S_PRE;
			end
		end
	end

	S_PRE: begin
		dvs3  <= {2'b00, dvs} + {1'b0, dvs, 1'b0};
		rem   <= pre_rq[63:32];
		quo   <= pre_rq[31:0];
		count <= 4'(steps - skip - 5'd1);
		state <= (quo_zero | (skip == steps)) ? S_FIX : S_RUN;
	end

	S_RUN: begin
		// two steps a clock; the last one alone when the count is odd
		if (count == 4'd0) begin
			rem   <= rem_nx;
			quo   <= {quo[29:0], digit};
			state <= S_FIX;
		end
		else begin
			rem   <= rem_nx_b;
			quo   <= {quo[27:0], digit, digit_b};
			count <= count - 4'd2;
			if (count == 4'd1) state <= S_FIX;
		end
	end

	S_FIX: begin
		quotient <= neg ? (32'd0 - quo) : quo;
		state    <= S_DONE;
	end

	default: begin // S_DONE
		if (ack) state <= S_IDLE;
	end
	endcase

	if (reset | abort) state <= S_IDLE;
end

assign done = (state == S_DONE);

endmodule

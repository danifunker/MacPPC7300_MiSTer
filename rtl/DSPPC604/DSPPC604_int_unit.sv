//============================================================================
//
//  DSPPC604 - PowerPC 604-class CPU core
//  Integer execute unit
//
//  Holds no architectural state. The requester supplies operand values and
//  the XER bits the instruction reads, and commits the results itself.
//
//  Handshake
//    The requester holds req_valid, unit, ctl and the operands steady until
//    resp_valid. A request is taken in a cycle where req_valid and req_ready
//    are both high. resp_valid is high for exactly one cycle, with the
//    results; the requester moves on at the end of that cycle.
//
//    UNIT_ALU   resp_valid in the same cycle as the request (combinational)
//    UNIT_MUL   resp_valid two cycles after the request
//    UNIT_DIV   resp_valid 34 cycles after the request (1 for the
//               architecturally undefined cases)
//
//    flush abandons a multiply or divide in progress.
//
//============================================================================

module DSPPC604_int_unit
(
	input  logic        clk,
	input  logic        reset,
	input  logic        flush,

	input  logic        req_valid,
	output logic        req_ready,
	input  DSPPC604_pkg::unit_t    unit,
	input  DSPPC604_pkg::int_ctl_t ctl,
	input  logic [31:0] a,
	input  logic [31:0] b,
	input  logic        ca_in,       // XER[CA]
	input  logic        so_in,       // XER[SO]

	output logic        resp_valid,
	output logic [31:0] result,
	output logic        ca_out,      // new XER[CA], for instructions that set it
	output logic        ov_out,      // new XER[OV], for instructions with OE
	output logic [3:0]  cr_out       // CR field: LT GT EQ SO
);

import DSPPC604_pkg::*;

// ---- single-cycle ALU ------------------------------------------------------
logic [31:0] alu_result;
logic        alu_ca;
logic        alu_ov;
logic        alu_lt;
logic        alu_gt;
logic        alu_eq;

DSPPC604_alu alu
(
	.ctl    (ctl),
	.a      (a),
	.b      (b),
	.ca_in  (ca_in),
	.result (alu_result),
	.ca_out (alu_ca),
	.ov_out (alu_ov),
	.lt     (alu_lt),
	.gt     (alu_gt),
	.eq     (alu_eq)
);

// ---- multiply and divide ---------------------------------------------------
typedef enum logic [1:0] {
	S_IDLE,
	S_MUL1,
	S_MUL2,
	S_DIV
} state_t;

state_t state;

wire start     = req_valid & (state == S_IDLE);
wire mul_start = start & (unit == UNIT_MUL);
wire div_start = start & (unit == UNIT_DIV);

logic [63:0] mul_product;

DSPPC604_mul mul
(
	.clk       (clk),
	.load      (mul_start),
	.is_signed (ctl.is_signed),
	.a         (a),
	.b         (b),
	.product   (mul_product)
);

logic        div_done;
logic [31:0] div_quotient;
logic        div_overflow;

DSPPC604_div div
(
	.clk       (clk),
	.reset     (reset),
	.start     (div_start),
	.abort     (flush),
	.is_signed (ctl.is_signed),
	.a         (a),
	.b         (b),
	.done      (div_done),
	.quotient  (div_quotient),
	.overflow  (div_overflow)
);

always_ff @(posedge clk) begin
	case (state)
		S_IDLE:  if (mul_start) state <= S_MUL1;
		         else if (div_start) state <= S_DIV;
		S_MUL1:  state <= S_MUL2;
		S_MUL2:  state <= S_IDLE;
		default: if (div_done) state <= S_IDLE;
	endcase

	if (reset | flush) state <= S_IDLE;
end

assign req_ready = (state == S_IDLE);

// ---- results ---------------------------------------------------------------
logic so_new;

always_comb begin
	ca_out = alu_ca;

	case (unit)
		UNIT_MUL: begin
			resp_valid = req_valid & (state == S_MUL2);
			result     = ctl.mul_high ? mul_product[63:32] : mul_product[31:0];
			// mullwo: the product does not fit in 32 bits
			ov_out     = (mul_product[63:32] != {32{mul_product[31]}});
		end
		UNIT_DIV: begin
			resp_valid = req_valid & (state == S_DIV) & div_done;
			result     = div_quotient;
			ov_out     = div_overflow;
		end
		default: begin
			resp_valid = req_valid & (unit == UNIT_ALU);
			result     = alu_result;
			ov_out     = alu_ov;
		end
	endcase

	so_new = so_in | (ctl.oe & ov_out);

	if (unit == UNIT_ALU && ctl.alu_op == ALU_CMP)
		cr_out = {alu_lt, alu_gt, alu_eq, so_in};
	else
		cr_out = {result[31], ~result[31] & (|result), ~(|result), so_new};
end

endmodule

//============================================================================
//
//  Synthesis-only wrapper for the area and timing check of the DSPPC604
//  floating-point unit (syn/check.py fpu).
//
//  Operands arrive from registers through a forwarding multiplexer, as they
//  will in the pipeline's execute stage, and the response is registered.
//
//============================================================================

module DSPPC604_check_fpu
(
	input  logic        clk,
	input  logic        i_reset,
	input  logic        i_valid,
	input  logic [4:0]  i_op,
	input  logic        i_single,
	input  logic        i_rc,
	input  logic [63:0] i_a,
	input  logic [63:0] i_b,
	input  logic [63:0] i_c,
	input  logic [2:0]  i_fwd,       // take the operand from the previous result
	input  logic        i_fwd_fpscr,
	input  logic [31:0] i_fpscr,

	output logic        o_valid,
	output logic        o_ready,
	output logic [63:0] o_result,
	output logic        o_result_we,
	output logic [31:0] o_fpscr,
	output logic [3:0]  o_cr,
	output logic        o_fex
);

import DSPPC604_pkg::*;

logic        reset_q;
logic        valid_q;
fpu_ctl_t    ctl_q;
logic [63:0] a_q;
logic [63:0] b_q;
logic [63:0] c_q;
logic [2:0]  fwd_q;
logic        fwd_fpscr_q;
logic [31:0] fpscr_q;

logic        resp_valid;
logic [63:0] result;
logic        result_we;
logic [31:0] fpscr_out;
logic [3:0]  cr_out;
logic        fex;

always_ff @(posedge clk) begin
	reset_q <= i_reset;
	if (~valid_q | resp_valid) begin
		valid_q     <= i_valid;
		ctl_q.op    <= fpu_op_t'(i_op);
		ctl_q.single <= i_single;
		ctl_q.rc    <= i_rc;
		a_q         <= i_a;
		b_q         <= i_b;
		c_q         <= i_c;
		fwd_q       <= i_fwd;
		fwd_fpscr_q <= i_fwd_fpscr;
		fpscr_q     <= i_fpscr;
	end
	if (reset_q) valid_q <= 1'b0;
end

wire [63:0] op_a  = fwd_q[0] ? o_result : a_q;
wire [63:0] op_b  = fwd_q[1] ? o_result : b_q;
wire [63:0] op_c  = fwd_q[2] ? o_result : c_q;
wire [31:0] op_fs = fwd_fpscr_q ? o_fpscr : fpscr_q;

DSPPC604_fpu fpu
(
	.clk        (clk),
	.reset      (reset_q),
	.flush      (1'b0),
	.req_valid  (valid_q),
	.req_ready  (o_ready),
	.ctl        (ctl_q),
	.a          (op_a),
	.b          (op_b),
	.c          (op_c),
	.fpscr_in   (op_fs),
	.resp_valid (resp_valid),
	.result     (result),
	.result_we  (result_we),
	.fpscr_out  (fpscr_out),
	.cr_out     (cr_out),
	.fex        (fex)
);

always_ff @(posedge clk) begin
	o_valid <= resp_valid;
	if (resp_valid) begin
		if (result_we) o_result <= result;
		o_result_we <= result_we;
		o_fpscr     <= fpscr_out;
		o_cr        <= cr_out;
		o_fex       <= fex;
	end
end

endmodule

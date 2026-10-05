//============================================================================
//
//  Synthesis-only wrapper for the area and timing check of the DSPPC604
//  integer path (syn/check.py int).
//
//  Models how the pipeline will use the units: a registered instruction is
//  decoded in one stage and executed in the next, with the execute result
//  forwarded straight back into the execute stage's operands. That loop is
//  the path that sets the clock.
//
//============================================================================

module DSPPC604_check_int
(
	input  logic        clk,
	input  logic        i_reset,
	input  logic        i_valid,
	input  logic [31:0] i_insn,
	input  logic [31:0] i_ra,        // register file read data
	input  logic [31:0] i_rb,
	input  logic [31:0] i_wb,        // a second forwarding source
	input  logic [1:0]  i_fwd_a,     // 0: register, 1: execute result, 2: i_wb
	input  logic [1:0]  i_fwd_b,
	input  logic        i_fwd_xer,   // carry and summary overflow from the previous result
	input  logic        i_ca,
	input  logic        i_so,

	output logic        o_valid,
	output logic        o_ready,
	output logic [31:0] o_result,
	output logic [3:0]  o_cr,
	output logic        o_ca,
	output logic        o_ov,
	output logic        o_so
);

import DSPPC604_pkg::*;

// ---- input registers (keep the pins out of the timing paths) ---------------
logic        reset_q;
logic        valid_q;
logic [31:0] insn_q;
logic [31:0] ra_q;
logic [31:0] rb_q;
logic [31:0] wb_q;
logic [1:0]  fwd_a_q;
logic [1:0]  fwd_b_q;
logic        fwd_xer_q;
logic        ca_q;
logic        so_q;

always_ff @(posedge clk) begin
	reset_q   <= i_reset;
	valid_q   <= i_valid;
	insn_q    <= i_insn;
	ra_q      <= i_ra;
	rb_q      <= i_rb;
	wb_q      <= i_wb;
	fwd_a_q   <= i_fwd_a;
	fwd_b_q   <= i_fwd_b;
	fwd_xer_q <= i_fwd_xer;
	ca_q      <= i_ca;
	so_q      <= i_so;
end

// ---- decode stage ----------------------------------------------------------
dec_t dec;

DSPPC604_decode decode
(
	.insn (insn_q),
	.dec  (dec)
);

logic        ex_valid;
dec_t        ex_dec;
logic [31:0] ex_a;
logic [31:0] ex_b;
logic [31:0] ex_wb;
logic [1:0]  ex_fwd_a;
logic [1:0]  ex_fwd_b;
logic        ex_fwd_xer;
logic        ex_ca;
logic        ex_so;

logic        resp_valid;
wire         advance = ~ex_valid | resp_valid;

always_ff @(posedge clk) begin
	if (advance) begin
		ex_valid   <= valid_q & dec.valid;
		ex_dec     <= dec;
		ex_a       <= dec.ra_rd ? ra_q : 32'd0;
		ex_b       <= dec.b_imm ? dec.imm : rb_q;
		ex_wb      <= wb_q;
		ex_fwd_a   <= dec.ra_rd ? fwd_a_q : 2'd0;
		ex_fwd_b   <= dec.b_imm ? 2'd0 : fwd_b_q;
		ex_fwd_xer <= fwd_xer_q;
		ex_ca      <= ca_q;
		ex_so      <= so_q;
	end
	if (reset_q) ex_valid <= 1'b0;
end

// ---- execute stage ---------------------------------------------------------
logic [31:0] result;
logic        ca_out;
logic        ov_out;
logic [3:0]  cr_out;

wire [31:0] op_a = (ex_fwd_a == 2'd1) ? o_result : (ex_fwd_a == 2'd2) ? ex_wb : ex_a;
wire [31:0] op_b = (ex_fwd_b == 2'd1) ? o_result : (ex_fwd_b == 2'd2) ? ex_wb : ex_b;
wire        ca_in = ex_fwd_xer ? o_ca : ex_ca;
wire        so_in = ex_fwd_xer ? o_so : ex_so;

DSPPC604_int_unit int_unit
(
	.clk        (clk),
	.reset      (reset_q),
	.flush      (1'b0),
	.req_valid  (ex_valid),
	.req_ready  (o_ready),
	.unit       (ex_dec.unit),
	.ctl        (ex_dec.ic),
	.a          (op_a),
	.b          (op_b),
	.ca_in      (ca_in),
	.so_in      (so_in),
	.resp_valid (resp_valid),
	.resp_ready (1'b1),
	.result     (result),
	.ca_out     (ca_out),
	.ov_out     (ov_out),
	.cr_out     (cr_out)
);

always_ff @(posedge clk) begin
	o_valid <= resp_valid;
	if (resp_valid) begin
		o_result <= result;
		o_cr     <= cr_out;
		o_ca     <= ex_dec.ca_wr ? ca_out : ca_in;
		o_ov     <= ov_out;
		o_so     <= so_in | (ex_dec.ov_wr & ov_out);
	end
end

endmodule

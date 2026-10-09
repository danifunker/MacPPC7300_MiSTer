//============================================================================
//
//  Test-only wrapper for replaying single-instruction golden vectors.
//
//  Does in miniature what the pipeline will do: holds the architectural
//  state, decodes one instruction, reads its operands, hands it to an execute
//  unit and commits the results. Vectors use r3-r6, CR, XER, CTR, FPSCR and
//  f3-f6; every other register reads as zero.
//
//============================================================================

module vector_dut
#(
	parameter int HAVE_FPU = 1       // 0: floating point reports "unimplemented"
)
(
	input  logic        clk,
	input  logic        reset,

	input  logic        start,       // one clock, with the inputs below
	input  logic [31:0] insn,
	input  logic [31:0] in_r3,
	input  logic [31:0] in_r4,
	input  logic [31:0] in_r5,
	input  logic [31:0] in_r6,
	input  logic [31:0] in_cr,
	input  logic [31:0] in_xer,
	input  logic [31:0] in_ctr,
	input  logic [31:0] in_fpscr,
	input  logic [63:0] in_f4,
	input  logic [63:0] in_f5,
	input  logic [63:0] in_f6,

	output logic        done,
	output logic        unimplemented,
	output logic [31:0] out_r3,
	output logic [31:0] out_r4,
	output logic [31:0] out_r5,
	output logic [31:0] out_r6,
	output logic [31:0] out_cr,
	output logic [31:0] out_xer,
	output logic [31:0] out_ctr,
	output logic [31:0] out_fpscr,
	output logic [63:0] out_f3,
	output logic [63:0] out_f4,
	output logic [63:0] out_f5,
	output logic [63:0] out_f6
);

import DSPPC604_pkg::*;

// ---- architectural state ---------------------------------------------------
logic [31:0] gpr [32];
logic [63:0] fpr [32];
logic [31:0] cr;
logic [31:0] xer;
logic [31:0] ctr;
logic [31:0] fpscr;
logic [31:0] insn_q;

wire xer_so = xer[31];
wire xer_ca = xer[29];

// ---- decode ----------------------------------------------------------------
dec_t dec;

DSPPC604_decode decode
(
	.insn (insn_q),
	.dec  (dec)
);

// ---- operand read ----------------------------------------------------------
wire [31:0] op_a = dec.ra_rd ? gpr[dec.ra[4:0]] : 32'd0;
wire [31:0] op_b = dec.b_imm ? dec.imm : gpr[dec.rb[4:0]];

wire [63:0] fop_a = fpr[dec.fra];
wire [63:0] fop_b = fpr[dec.frb];
wire [63:0] fop_c = fpr[dec.frc];

// ---- execute ---------------------------------------------------------------
typedef enum logic [1:0] {
	S_IDLE,
	S_EXEC,
	S_DONE
} state_t;

state_t state;

// loads, stores, branches and CR/SPR moves need the pipeline; here they
// count as unimplemented
wire plain  = ~dec.mem_rd & ~dec.mem_wr & (dec.br == BR_NONE);
wire is_int = dec.valid & plain & (dec.unit == UNIT_ALU || dec.unit == UNIT_MUL || dec.unit == UNIT_DIV);
wire is_fpu = dec.valid & (dec.unit == UNIT_FPU) & (HAVE_FPU != 0);

logic        int_resp;
logic [31:0] int_result;
logic        int_ca;
logic        int_ov;
logic [3:0]  int_cr;
/* verilator lint_off UNUSEDSIGNAL */
logic        int_ready;
/* verilator lint_on UNUSEDSIGNAL */

DSPPC604_int_unit int_unit
(
	.clk        (clk),
	.reset      (reset),
	.flush      (1'b0),
	.req_valid  ((state == S_EXEC) & is_int),
	.req_ready  (int_ready),
	.unit       (dec.unit),
	.ctl        (dec.ic),
	.a          (op_a),
	.b          (op_b),
	.ca_in      (xer_ca),
	.so_in      (xer_so),
	.resp_valid (int_resp),
	.resp_ready (1'b1),
	.result     (int_result),
	.ca_out     (int_ca),
	.ov_out     (int_ov),
	.cr_out     (int_cr),
	/* verilator lint_off PINCONNECTEMPTY */
	.sum        (),
	.cmp_lts    (),
	.cmp_ltu    (),
	.cmp_eq     ()
	/* verilator lint_on PINCONNECTEMPTY */
);

logic        fpu_resp;
logic [63:0] fpu_result;
logic        fpu_result_we;
logic [31:0] fpu_fpscr;
logic [3:0]  fpu_cr;
/* verilator lint_off UNUSEDSIGNAL */
logic        fpu_ready;
logic        fpu_fex;
/* verilator lint_on UNUSEDSIGNAL */

generate if (HAVE_FPU != 0) begin : g_fpu
	DSPPC604_fpu fpu
	(
		.clk        (clk),
		.reset      (reset),
		.flush      (1'b0),
		.req_valid  ((state == S_EXEC) & is_fpu),
		.req_ready  (fpu_ready),
		.ctl        (dec.fc),
		.a          (fop_a),
		.b          (fop_b),
		.c          (fop_c),
		.cls_a      (DSPPC604_pkg::fp_classify(fop_a)),
		.cls_b      (DSPPC604_pkg::fp_classify(fop_b)),
		.cls_c      (DSPPC604_pkg::fp_classify(fop_c)),
		.fpscr_in   (fpscr),
		.resp_valid (fpu_resp),
		.resp_ready (1'b1),
		.result     (fpu_result),
		.result_we  (fpu_result_we),
		.fpscr_out  (fpu_fpscr),
		.cr_out     (fpu_cr),
		.fex        (fpu_fex)
	);
end
else begin : g_nofpu
	assign fpu_resp      = 1'b0;
	assign fpu_result    = 64'd0;
	assign fpu_result_we = 1'b0;
	assign fpu_fpscr     = 32'd0;
	assign fpu_cr        = 4'd0;
	assign fpu_ready     = 1'b0;
	assign fpu_fex       = 1'b0;
end endgenerate

// ---- commit ----------------------------------------------------------------
// CR field n occupies bits 31-4n down to 28-4n.
function automatic logic [31:0] cr_insert(input logic [31:0] old, input logic [2:0] fld, input logic [3:0] val);
	logic [4:0] sh;
	begin
		sh = {3'd7 - fld, 2'b00};
		cr_insert = (old & ~(32'hF << sh)) | ({28'd0, val} << sh);
	end
endfunction

always_ff @(posedge clk) begin
	case (state)
	S_IDLE: begin
		if (start) begin
			for (int i = 0; i < 32; i++) begin
				gpr[i] <= 32'd0;
				fpr[i] <= 64'd0;
			end
			gpr[3] <= in_r3;
			gpr[4] <= in_r4;
			gpr[5] <= in_r5;
			gpr[6] <= in_r6;
			fpr[4] <= in_f4;
			fpr[5] <= in_f5;
			fpr[6] <= in_f6;
			cr     <= in_cr;
			xer    <= in_xer;
			ctr    <= in_ctr;
			fpscr  <= in_fpscr;
			insn_q <= insn;
			unimplemented <= 1'b0;
			state  <= S_EXEC;
		end
	end

	S_EXEC: begin
		if (is_int) begin
			if (int_resp) begin
				if (dec.rd_wr) gpr[dec.rd[4:0]] <= int_result;
				if (dec.ca_wr) xer[29] <= int_ca;
				if (dec.ov_wr) begin
					xer[30] <= int_ov;
					xer[31] <= xer[31] | int_ov;
				end
				if (dec.cr_wr) cr <= cr_insert(cr, dec.cr_fld, int_cr);
				state <= S_DONE;
			end
		end
		else if (is_fpu) begin
			if (fpu_resp) begin
				if (dec.frd_wr & fpu_result_we) fpr[dec.frd] <= fpu_result;
				if (dec.fpscr_wr) fpscr <= fpu_fpscr;
				if (dec.cr_wr) cr <= cr_insert(cr, dec.cr_fld, fpu_cr);
				state <= S_DONE;
			end
		end
		else begin
			unimplemented <= 1'b1;
			state <= S_DONE;
		end
	end

	default: begin // S_DONE
		state <= S_IDLE;
	end
	endcase

	if (reset) state <= S_IDLE;
end

assign done      = (state == S_DONE);

assign out_r3    = gpr[3];
assign out_r4    = gpr[4];
assign out_r5    = gpr[5];
assign out_r6    = gpr[6];
assign out_cr    = cr;
assign out_xer   = xer;
assign out_ctr   = ctr;
assign out_fpscr = fpscr;
assign out_f3    = fpr[3];
assign out_f4    = fpr[4];
assign out_f5    = fpr[5];
assign out_f6    = fpr[6];

endmodule

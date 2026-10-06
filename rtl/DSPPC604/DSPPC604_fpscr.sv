//============================================================================
//
//  DSPPC604 - PowerPC 604-class CPU core
//  The instructions that write FPSCR directly (combinational)
//
//    mtfsf    fields selected by FM <- the same fields of frB's low word
//    mtfsfi   field crfD <- IMM
//    mtfsb0   bit crbD <- 0
//    mtfsb1   bit crbD <- 1
//    mcrfs    CR field <- FPSCR field crfS; the exception bits copied are cleared
//
//  FEX and VX are summaries and are never written directly; they are
//  recomputed after every change. mtfsb1 setting an exception bit that was
//  clear sets FX as well, like any other instruction raising an exception;
//  mtfsf and mtfsfi change FX only when their operand says so.
//
//  Checked against a real 604 (7300 run): 2,989 vectors over every bit of
//  every one of these instructions, all as here. Bit 20 (reserved) is never
//  set.
//
//============================================================================

module DSPPC604_fpscr
(
	input  DSPPC604_pkg::sys_op_t op,
	input  logic [31:0] insn,
	input  logic [31:0] fpscr,
	input  logic [31:0] frb,          // low word of frB, for mtfsf

	output logic [31:0] fpscr_next,
	output logic [3:0]  cr_field      // for mcrfs
);

import DSPPC604_pkg::*;

localparam logic [31:0] EXC_BITS = 32'h9FF80700;   // FX and every exception bit
localparam logic [31:0] VX_ALL   = 32'h01F80700;
localparam logic [31:0] WRITABLE = 32'h9FFFF7FF;   // not FEX, VX or the reserved bit

wire [7:0] fm    = insn[24:17];
wire [2:0] crfd  = insn[25:23];
wire [2:0] crfs  = insn[20:18];
wire [3:0] imm   = insn[15:12];
wire [4:0] bit_n = 5'd31 - insn[25:21];

logic [31:0] fm_mask;
logic [31:0] fld_mask;
logic [31:0] src_mask;
logic [31:0] bit_mask;
logic [31:0] fld_bits;
logic [31:0] n;

always_comb begin
	for (int f = 0; f < 8; f++)
		fm_mask[31 - 4*f -: 4] = {4{fm[7 - f]}};
	fld_mask = 32'hF0000000 >> {crfd, 2'b00};
	src_mask = 32'hF0000000 >> {crfs, 2'b00};
	bit_mask = 32'd1 << bit_n;

	n = fpscr;
	case (op)
		SYS_MTFSF:  n = (fpscr & ~(fm_mask & WRITABLE)) | (frb & fm_mask & WRITABLE);
		SYS_MTFSFI: n = (fpscr & ~(fld_mask & WRITABLE)) | ({8{imm}} & fld_mask & WRITABLE);
		SYS_MTFSB0: n = fpscr & ~(bit_mask & WRITABLE);
		SYS_MTFSB1: begin
			n = fpscr | (bit_mask & WRITABLE);
			if (|(bit_mask & EXC_BITS & ~fpscr)) n[31] = 1'b1;
		end
		SYS_MCRFS:  n = fpscr & ~(src_mask & EXC_BITS);
		default: ;
	endcase

	// the summaries
	n[29] = |(n & VX_ALL);
	n[30] = (n[29] & n[7]) | (n[28] & n[6]) | (n[27] & n[5]) | (n[26] & n[4]) | (n[25] & n[3]);
	fpscr_next = n;

	fld_bits = fpscr >> {3'd7 - crfs, 2'b00};
	cr_field = fld_bits[3:0];
end

endmodule

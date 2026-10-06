//============================================================================
//
//  DSPPC604 - PowerPC 604-class CPU core
//  Sequencer for multi-operation instructions (decode stage)
//
//  Expands the instructions that are several operations in one into simple
//  operations, so that no later stage has to know about them:
//
//    update forms    the access, then rA <- rA + displacement or rB
//    lmw, stmw       one word access per register
//    lswi, stswi     one access of up to four bytes per register
//    lswx, stswx     scratch <- (rA|0) + rB, then as lswi/stswi from scratch
//    stwcx.          the conditional store, then CR0 from its outcome
//
//  Every other instruction passes through as one operation.
//
//============================================================================

module DSPPC604_seq
(
	input  logic        clk,
	input  logic        reset,
	input  logic        flush,

	input  logic        valid,        // an instruction is in the decode stage
	input  DSPPC604_pkg::dec_t dec,   // its decode
	input  logic [4:0]  nb,           // its NB field, for lswi and stswi
	input  logic [6:0]  xer_count,    // XER byte count, for lswx and stswx
	input  logic        take,         // the operation shown is accepted this cycle

	output DSPPC604_pkg::dec_t uop,
	output logic        first,        // first operation of the instruction
	output logic        last,         // last operation of the instruction
	output logic        wait_xer      // XER's byte count must be final first
);

import DSPPC604_pkg::*;

logic [5:0] step;

wire        is_load = dec.mem_rd;
wire [4:0]  base_r  = is_load ? dec.rd[4:0] : dec.rc[4:0];

// string forms
wire [6:0]  n_total = (dec.seq == SEQ_STRX) ? xer_count :
                      (nb == 5'd0) ? 7'd32 : {2'b00, nb};
wire [5:0]  word_i  = (dec.seq == SEQ_STRX) ? (step - 6'd1) : step;   // which register
wire [7:0]  done_b  = {word_i, 2'b00};                                  // bytes before it
wire [7:0]  left_b  = {1'b0, n_total} - done_b;                         // bytes still to go
wire [4:0]  str_r   = base_r + word_i[4:0];

always_comb begin
	uop      = dec;
	first    = (step == 6'd0);
	last     = 1'b1;
	wait_xer = 1'b0;

	case (dec.seq)
	SEQ_UPDATE: begin
		if (step == 6'd0) begin
			last = 1'b0;
		end
		else begin
			// rA <- rA + B, with what the access left in place
			uop.mem_rd = 1'b0;
			uop.mem_wr = 1'b0;
			uop.mem_fp = 1'b0;
			uop.rc_rd  = 1'b0;
			uop.frb_rd = 1'b0;
			uop.frd_wr = 1'b0;
			uop.rd     = dec.ra;
			uop.rd_wr  = 1'b1;
		end
	end

	SEQ_STWCX: begin
		if (step == 6'd0) begin
			last = 1'b0;
		end
		else begin
			// CR0 <- 0 0 stored SO, from what the store left behind
			uop        = '0;
			uop.valid  = 1'b1;
			uop.unit   = UNIT_SYS;
			uop.sys    = SYS_STWCX_CR;
			uop.cr_wr  = 1'b1;
		end
	end

	SEQ_MULTI: begin
		uop.imm = dec.imm + {24'd0, step, 2'b00};
		if (is_load) uop.rd = {1'b0, base_r + step[4:0]};
		else         uop.rc = {1'b0, base_r + step[4:0]};
		last = ((base_r + step[4:0]) == 5'd31);
	end

	SEQ_STRI, SEQ_STRX: begin
		wait_xer = (dec.seq == SEQ_STRX) & (step == 6'd0);
		if ((dec.seq == SEQ_STRX) && (n_total == 7'd0)) begin
			// nothing to move
			uop       = '0;
			uop.valid = 1'b1;
			uop.unit  = UNIT_SYS;
			uop.sys   = SYS_NOP;
		end
		else if ((dec.seq == SEQ_STRX) && (step == 6'd0)) begin
			// scratch <- (rA|0) + rB
			uop.mem_rd = 1'b0;
			uop.mem_wr = 1'b0;
			uop.rc_rd  = 1'b0;
			uop.rd     = REG_TEMP;
			uop.rd_wr  = 1'b1;
			last       = 1'b0;
		end
		else begin
			if (dec.seq == SEQ_STRX) begin
				uop.ra    = REG_TEMP;
				uop.ra_rd = 1'b1;
				uop.rb_rd = 1'b0;
				uop.b_imm = 1'b1;
			end
			uop.imm   = {24'd0, done_b};
			uop.mem_n = (left_b >= 8'd4) ? 4'd4 : left_b[3:0];
			if (is_load) uop.rd = {1'b0, str_r};
			else         uop.rc = {1'b0, str_r};
			if (word_i == 6'd0) uop.str_bytes = n_total;
			last = (left_b <= 8'd4);
		end
	end

	default: ;
	endcase
end

always_ff @(posedge clk) begin
	if (valid & take) step <= last ? 6'd0 : (step + 6'd1);
	if (reset | flush | ~valid) step <= 6'd0;
end

endmodule

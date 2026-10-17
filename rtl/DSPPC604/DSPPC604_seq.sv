//============================================================================
//
//  DSPPC604 - PowerPC 604-class CPU core
//  Sequencer for multi-operation instructions (decode stage)
//
//  Expands the instructions that are several operations in one into simple
//  operations, so that no later stage has to know about them:
//
//    update forms    a store: one operation, which also writes rA <- EA
//                    (a store writes no other register); a load: the
//                    access, then rA <- rA + displacement or rB; an
//                    indexed load whose rD is its rB (lwzux r4,r3,r4, a
//                    valid form) cannot form the update from rB after the
//                    load, so it goes scratch <- rA + rB, rD <- [scratch],
//                    rA <- scratch
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
	input  DSPPC604_pkg::seq_t seqk,  // dec.seq, from the opcode bits directly (for last)
	input  logic [4:0]  rs,           // the instruction's rS/rD field, likewise
	input  logic [4:0]  nb,           // its NB field, for lswi and stswi
	input  logic        strx,         // it is lswx or stswx, from the opcode bits directly
	input  logic        ldux_rb,      // it is an indexed load with update whose rD is its rB, likewise
	input  logic        upd_store,    // it is a store with update, likewise: one operation
	input  logic        upd_load,     // it is a load with update in one operation (rA not 0, not rD), likewise
	input  logic [6:0]  xer_count,    // XER byte count, for lswx and stswx
	input  logic        take,         // the operation shown is accepted this cycle

	output DSPPC604_pkg::dec_t uop,
	output logic        first,        // first operation of the instruction
	output logic        last,         // last operation of the instruction
	output logic        wait_xer,     // XER's byte count must be final first
	output logic [5:0]  next_ra,      // prospective next micro-op, independent of take
	output logic [5:0]  next_rc,
	// uop's read flags again, from the decoder's and the step alone (not
	// through the arms below): the forwarding selects are compared from these
	output logic        ra_rd_s, rb_rd_s, rc_rd_s, b_imm_s, fra_rd_s, frb_rd_s, frc_rd_s,
	output logic        nop_s,        // uop is the nop of lswx/stswx with a zero count
	output logic        cr_op_s       // uop is stwcx.'s CR operation
);

import DSPPC604_pkg::*;

logic [5:0] step;
logic       last_d;               // last, as the decoder's seq field has it (checked against last)

wire        is_load = dec.mem_rd;
wire [4:0]  base_r  = rs;                 // rS or rD (the field the decoder puts in rc for every instruction)
// the multiple's displacement from a register after the first operation
// (the decoder's immediate is then not in front of the adder): the word
// holds through a sequence, so what the first operation saw stays right
logic [31:0] imm_q;
always_ff @(posedge clk) if (step == 6'd0) imm_q <= dec.imm;

// string forms (strx, from the opcode bits, keeps the decoder's seq field
// off the register-read indexes)
wire [6:0]  n_total = strx ? xer_count :
                      (nb == 5'd0) ? 7'd32 : {2'b00, nb};
wire [5:0]  word_i  = strx ? (step - 6'd1) : step;                     // which register
wire [7:0]  done_b  = {word_i, 2'b00};                                  // bytes before it
wire [7:0]  left_b  = {1'b0, n_total} - done_b;                         // bytes still to go
wire [4:0]  str_r   = base_r + word_i[4:0];

// The wait for XER holds the handshake with EX and so every stage's load
// enable; it is decided from the opcode bits the pipeline compares directly,
// not from the decoder's seq field, which keeps the decoder out of that chain.
assign wait_xer = strx & (step == 6'd0);
// The next operation is read speculatively even while this one stalls.
// Only a non-last take consumes these RAM samples; the next fetched word
// has independent register-file copies. RB is unchanged throughout a macro.
wire [4:0] next_word_i = strx ? step[4:0] : (step[4:0] + 5'd1);
assign next_ra = (strx | ldux_rb) ? REG_TEMP : dec.ra;
assign next_rc = {1'b0, base_r + next_word_i};

always_comb begin
	uop      = dec;
	first    = (step == 6'd0);
	last_d   = 1'b1;

	case (dec.seq)
	SEQ_UPDATE: begin
		if (ldux_rb) begin
			// rD = rB: the load overwrites rB, so the address is kept in the
			// scratch register: scratch <- rA + rB; rD <- [scratch]; rA <- scratch
			if (step == 6'd0) begin
				uop.mem_rd = 1'b0;
				uop.rd     = REG_TEMP;
				last_d       = 1'b0;
			end
			else begin
				uop.ra_rd  = 1'b1;                // the scratch register (see the read indexes below)
				uop.rb_rd  = 1'b0;
				uop.b_imm  = 1'b1;
				uop.imm    = 32'd0;
				if (step == 6'd1) begin
					last_d = 1'b0;
				end
				else begin
					uop.mem_rd = 1'b0;
					uop.rd     = dec.ra;
				end
			end
		end
		else if (step == 6'd0) begin
			if (~is_load) begin
				// a store: rA <- EA as its own result
				uop.rd    = dec.ra;
				uop.rd_wr = 1'b1;
			end
			else if (upd_load) uop.upd = 1'b1;    // rD from memory, rA <- EA at once
			else last_d = 1'b0;
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
			last_d = 1'b0;
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
		uop.imm = (step == 6'd0) ? dec.imm : (imm_q + {24'd0, step, 2'b00});
		if (is_load) uop.rd = {1'b0, base_r + step[4:0]};
		last_d = ((base_r + step[4:0]) == 5'd31);
	end

	SEQ_STRI, SEQ_STRX: begin
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
			last_d       = 1'b0;
		end
		else begin
			if (dec.seq == SEQ_STRX) begin
				uop.ra_rd = 1'b1;
				uop.rb_rd = 1'b0;
				uop.b_imm = 1'b1;
			end
			uop.imm   = {24'd0, done_b};
			uop.mem_n = (left_b >= 8'd4) ? 4'd4 : left_b[3:0];
			if (is_load) uop.rd = {1'b0, str_r};
			if (word_i == 6'd0) uop.str_bytes = n_total;
			last_d = (left_b <= 8'd4);
		end
	end

	default: ;
	endcase

	// The read indexes, assigned last and unconditionally: the decoder's
	// fields, or after the first operation the scratch register for lswx,
	// stswx and the rD = rB loads, and the next register of a multiple or
	// string store, decided from the step and the opcode bits alone, so that
	// the register file's read mux waits neither for the decoder's seq field
	// nor for the arms above (which zero the whole operation in the two nop
	// cases; nothing reads an index there, the read enables being zero).
	uop.ra = ((strx | ldux_rb) & (step != 6'd0)) ? REG_TEMP : dec.ra;
	uop.rb = dec.rb;
	uop.rc = (step != 6'd0) ? {1'b0, str_r} : dec.rc;
end

// last from seqk: ID's handshake waits for the opcode bits, the step and
// the register fields, not for the decoder
always_comb begin
	case (seqk)
	SEQ_UPDATE:          last = ldux_rb ? (step >= 6'd2) : (upd_store | upd_load | (step != 6'd0));
	SEQ_STWCX:           last = (step != 6'd0);
	SEQ_MULTI:           last = ((rs + step[4:0]) == 5'd31);
	SEQ_STRI:            last = (left_b <= 8'd4);
	SEQ_STRX:            last = (n_total == 7'd0) | ((step != 6'd0) & (left_b <= 8'd4));
	default:             last = 1'b1;
	endcase
end

// the read flags from the decoder's and the step, beside the arms above
wire   scratch_s = (strx | ldux_rb) & (step != 6'd0);               // the scratch register is A, B an immediate
wire   upd_s     = (seqk == SEQ_UPDATE) & ~ldux_rb & (step != 6'd0); // rA <- rA + B: no rS, no frS
assign nop_s     = (seqk == SEQ_STRX) & (n_total == 7'd0);
assign cr_op_s   = (seqk == SEQ_STWCX) & (step != 6'd0);
wire   zero_s    = nop_s | cr_op_s;
assign ra_rd_s   = ~zero_s & (dec.ra_rd | scratch_s);
assign rb_rd_s   = ~zero_s & dec.rb_rd & ~scratch_s;
assign b_imm_s   = ~zero_s & (dec.b_imm | scratch_s);
assign rc_rd_s   = ~zero_s & dec.rc_rd & ~upd_s & ~(strx & (step == 6'd0));
assign fra_rd_s  = ~zero_s & dec.fra_rd;
assign frb_rd_s  = ~zero_s & dec.frb_rd & ~upd_s;
assign frc_rd_s  = ~zero_s & dec.frc_rd;

// synthesis translate_off
always_ff @(posedge clk) begin
	if (~reset & valid & ((seqk != dec.seq) | (last != last_d)))
		$fatal(1, "DSPPC604_seq: seqk %0d / last %0d differ from the decoder's %0d / %0d", seqk, last, dec.seq, last_d);
	if (~reset & valid & ({ra_rd_s, rb_rd_s, rc_rd_s, b_imm_s, fra_rd_s, frb_rd_s, frc_rd_s} !=
	                      {uop.ra_rd, uop.rb_rd, uop.rc_rd, uop.b_imm, uop.fra_rd, uop.frb_rd, uop.frc_rd}))
		$fatal(1, "DSPPC604_seq: the read flags beside the arms differ from uop's");
	if (~reset & valid & ((nop_s != ((uop.unit == UNIT_SYS) & (uop.sys == SYS_NOP) & (dec.seq == SEQ_STRX))) |
	                      (cr_op_s != (uop.sys == SYS_STWCX_CR))))
		$fatal(1, "DSPPC604_seq: nop_s or cr_op_s differs from uop");
end
// synthesis translate_on

always_ff @(posedge clk) begin
	if (valid & take) step <= last ? 6'd0 : (step + 6'd1);
	if (reset | flush | ~valid) step <= 6'd0;
end

endmodule

//============================================================================
//
//  DSPPC604 - PowerPC 604-class CPU core
//  Instruction decoder (combinational)
//
//  Covers integer arithmetic, logical, compare, rotate and shift, and the
//  floating-point arithmetic, move, convert and compare instructions.
//  Loads, stores, branches, CR logic and system instructions are added with
//  the pipeline.
//
//============================================================================

module DSPPC604_decode
(
	input  logic [31:0]        insn,
	output DSPPC604_pkg::dec_t dec
);

import DSPPC604_pkg::*;

wire [5:0]  opcd = insn[31:26];
wire [4:0]  f_d  = insn[25:21];      // rD, rS, frD
wire [4:0]  f_a  = insn[20:16];      // rA, frA
wire [4:0]  f_b  = insn[15:11];      // rB, frB, SH
wire [4:0]  f_c  = insn[10:6];       // frC, MB
wire [9:0]  xo10 = insn[10:1];
wire [8:0]  xo9  = insn[9:1];
wire [4:0]  xo5  = insn[5:1];
wire        f_oe = insn[10];
wire        f_rc = insn[0];

wire [31:0] simm  = {{16{insn[15]}}, insn[15:0]};
wire [31:0] uimm  = {16'd0, insn[15:0]};
wire [31:0] shimm = {insn[15:0], 16'd0};

always_comb begin
	dec = '0;

	// fields that are always in the same place
	dec.ic.sh  = f_b;
	dec.ic.mb  = f_c;
	dec.ic.me  = xo5;
	dec.fra    = f_a;
	dec.frb    = f_b;
	dec.frc    = f_c;
	dec.frd    = f_d;

	case (opcd)

	// ---- integer, immediate operand ---------------------------------------
	6'd7: begin // mulli
		dec.valid = 1; dec.unit = UNIT_MUL;
		dec.ra = f_a; dec.ra_rd = 1; dec.b_imm = 1; dec.imm = simm;
		dec.rd = f_d; dec.rd_wr = 1;
		dec.ic.is_signed = 1;
	end
	6'd8: begin // subfic
		dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ADD;
		dec.ra = f_a; dec.ra_rd = 1; dec.b_imm = 1; dec.imm = simm;
		dec.rd = f_d; dec.rd_wr = 1;
		dec.ic.inv_a = 1; dec.ic.cin = CIN_ONE; dec.ca_wr = 1;
	end
	6'd10, 6'd11: begin // cmpli, cmpi
		dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_CMP;
		dec.ra = f_a; dec.ra_rd = 1; dec.b_imm = 1;
		dec.imm = opcd[0] ? simm : uimm;
		dec.ic.is_signed = opcd[0];
		dec.cr_wr = 1; dec.cr_fld = insn[25:23];
	end
	6'd12, 6'd13: begin // addic, addic.
		dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ADD;
		dec.ra = f_a; dec.ra_rd = 1; dec.b_imm = 1; dec.imm = simm;
		dec.rd = f_d; dec.rd_wr = 1;
		dec.ca_wr = 1;
		dec.cr_wr = opcd[0];
	end
	6'd14, 6'd15: begin // addi, addis: (rA|0)
		dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ADD;
		dec.ra = f_a; dec.ra_rd = (f_a != 5'd0); dec.b_imm = 1;
		dec.imm = opcd[0] ? shimm : simm;
		dec.rd = f_d; dec.rd_wr = 1;
	end

	// ---- rotates -----------------------------------------------------------
	6'd20: begin // rlwimi: A = rS, B = rA (the word being inserted into)
		dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ROT;
		dec.ic.rot_op = ROT_RLWIMI;
		dec.ra = f_d; dec.ra_rd = 1; dec.rb = f_a; dec.rb_rd = 1;
		dec.rd = f_a; dec.rd_wr = 1;
		dec.cr_wr = f_rc;
	end
	6'd21, 6'd23: begin // rlwinm, rlwnm
		dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ROT;
		dec.ic.rot_op = ROT_RLWINM;
		dec.ra = f_d; dec.ra_rd = 1;
		dec.rb = f_b; dec.rb_rd = opcd[1]; dec.ic.sh_reg = opcd[1];
		dec.rd = f_a; dec.rd_wr = 1;
		dec.cr_wr = f_rc;
	end

	// ---- logical, immediate operand ---------------------------------------
	6'd24, 6'd25, 6'd26, 6'd27, 6'd28, 6'd29: begin
		// ori, oris, xori, xoris, andi., andis.
		dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_LOGIC;
		dec.ra = f_d; dec.ra_rd = 1; dec.b_imm = 1;
		dec.imm = opcd[0] ? shimm : uimm;
		dec.rd = f_a; dec.rd_wr = 1;
		case (opcd[2:1])
			2'b00:   dec.ic.log_op = LOG_OR;
			2'b01:   dec.ic.log_op = LOG_XOR;
			default: begin dec.ic.log_op = LOG_AND; dec.cr_wr = 1; end
		endcase
	end

	// ---- opcode 31 ---------------------------------------------------------
	6'd31: begin
		case (xo10)
		10'd0, 10'd32: begin // cmp, cmpl
			dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_CMP;
			dec.ra = f_a; dec.ra_rd = 1; dec.rb = f_b; dec.rb_rd = 1;
			dec.ic.is_signed = ~xo10[5];
			dec.cr_wr = 1; dec.cr_fld = insn[25:23];
		end
		10'd26: begin // cntlzw
			dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_CNTLZ;
			dec.ra = f_d; dec.ra_rd = 1;
			dec.rd = f_a; dec.rd_wr = 1;
			dec.cr_wr = f_rc;
		end
		10'd922, 10'd954: begin // extsh, extsb
			dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_EXTS;
			dec.ic.ext_byte = xo10[5];
			dec.ra = f_d; dec.ra_rd = 1;
			dec.rd = f_a; dec.rd_wr = 1;
			dec.cr_wr = f_rc;
		end
		10'd28, 10'd60, 10'd124, 10'd284, 10'd316, 10'd412, 10'd444, 10'd476: begin
			// and, andc, nor, eqv, xor, orc, or, nand
			dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_LOGIC;
			dec.ra = f_d; dec.ra_rd = 1; dec.rb = f_b; dec.rb_rd = 1;
			dec.rd = f_a; dec.rd_wr = 1;
			dec.cr_wr = f_rc;
			case (xo10)
				10'd28:  begin dec.ic.log_op = LOG_AND; end
				10'd60:  begin dec.ic.log_op = LOG_AND; dec.ic.log_inv_b = 1; end
				10'd124: begin dec.ic.log_op = LOG_OR;  dec.ic.log_inv_out = 1; end
				10'd284: begin dec.ic.log_op = LOG_XOR; dec.ic.log_inv_out = 1; end
				10'd316: begin dec.ic.log_op = LOG_XOR; end
				10'd412: begin dec.ic.log_op = LOG_OR;  dec.ic.log_inv_b = 1; end
				10'd444: begin dec.ic.log_op = LOG_OR;  end
				default: begin dec.ic.log_op = LOG_AND; dec.ic.log_inv_out = 1; end
			endcase
		end
		10'd24, 10'd536, 10'd792: begin // slw, srw, sraw
			dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ROT;
			dec.ic.rot_op = (xo10 == 10'd24)  ? ROT_SLW :
			                (xo10 == 10'd536) ? ROT_SRW : ROT_SRAW;
			dec.ic.sh_reg = 1;
			dec.ra = f_d; dec.ra_rd = 1; dec.rb = f_b; dec.rb_rd = 1;
			dec.rd = f_a; dec.rd_wr = 1;
			dec.ca_wr = (xo10 == 10'd792);
			dec.cr_wr = f_rc;
		end
		10'd824: begin // srawi
			dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ROT;
			dec.ic.rot_op = ROT_SRAW;
			dec.ra = f_d; dec.ra_rd = 1;
			dec.rd = f_a; dec.rd_wr = 1;
			dec.ca_wr = 1;
			dec.cr_wr = f_rc;
		end

		default: begin
			// XO form: 9-bit extended opcode with OE above it
			case (xo9)
			9'd8, 9'd10, 9'd40, 9'd104, 9'd136, 9'd138,
			9'd200, 9'd202, 9'd232, 9'd234, 9'd266: begin
				// subfc, addc, subf, neg, subfe, adde,
				// subfze, addze, subfme, addme, add
				dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ADD;
				dec.ra = f_a; dec.ra_rd = 1; dec.rb = f_b; dec.rb_rd = 1;
				dec.rd = f_d; dec.rd_wr = 1;
				dec.ic.oe = f_oe; dec.ov_wr = f_oe;
				dec.cr_wr = f_rc;
				case (xo9)
				9'd8:   begin dec.ic.inv_a = 1; dec.ic.cin = CIN_ONE; dec.ca_wr = 1; end
				9'd10:  begin dec.ca_wr = 1; end
				9'd40:  begin dec.ic.inv_a = 1; dec.ic.cin = CIN_ONE; end
				9'd104: begin // neg: ~A + 0 + 1
					dec.ic.inv_a = 1; dec.ic.cin = CIN_ONE;
					dec.rb_rd = 0; dec.b_imm = 1;
				end
				9'd136: begin dec.ic.inv_a = 1; dec.ic.cin = CIN_CA; dec.ca_wr = 1; end
				9'd138: begin dec.ic.cin = CIN_CA; dec.ca_wr = 1; end
				9'd200: begin // subfze: ~A + 0 + CA
					dec.ic.inv_a = 1; dec.ic.cin = CIN_CA; dec.ca_wr = 1;
					dec.rb_rd = 0; dec.b_imm = 1;
				end
				9'd202: begin // addze: A + 0 + CA
					dec.ic.cin = CIN_CA; dec.ca_wr = 1;
					dec.rb_rd = 0; dec.b_imm = 1;
				end
				9'd232: begin // subfme: ~A + (-1) + CA
					dec.ic.inv_a = 1; dec.ic.cin = CIN_CA; dec.ca_wr = 1;
					dec.rb_rd = 0; dec.b_imm = 1; dec.imm = 32'hFFFFFFFF;
				end
				9'd234: begin // addme: A + (-1) + CA
					dec.ic.cin = CIN_CA; dec.ca_wr = 1;
					dec.rb_rd = 0; dec.b_imm = 1; dec.imm = 32'hFFFFFFFF;
				end
				default: ; // add
				endcase
			end
			9'd11, 9'd75: begin // mulhwu, mulhw
				dec.valid = 1; dec.unit = UNIT_MUL;
				dec.ra = f_a; dec.ra_rd = 1; dec.rb = f_b; dec.rb_rd = 1;
				dec.rd = f_d; dec.rd_wr = 1;
				dec.ic.is_signed = xo9[6]; dec.ic.mul_high = 1;
				dec.cr_wr = f_rc;
			end
			9'd235: begin // mullw
				dec.valid = 1; dec.unit = UNIT_MUL;
				dec.ra = f_a; dec.ra_rd = 1; dec.rb = f_b; dec.rb_rd = 1;
				dec.rd = f_d; dec.rd_wr = 1;
				dec.ic.is_signed = 1;
				dec.ic.oe = f_oe; dec.ov_wr = f_oe;
				dec.cr_wr = f_rc;
			end
			9'd459, 9'd491: begin // divwu, divw
				dec.valid = 1; dec.unit = UNIT_DIV;
				dec.ra = f_a; dec.ra_rd = 1; dec.rb = f_b; dec.rb_rd = 1;
				dec.rd = f_d; dec.rd_wr = 1;
				dec.ic.is_signed = xo9[5];
				dec.ic.oe = f_oe; dec.ov_wr = f_oe;
				dec.cr_wr = f_rc;
			end
			default: ;
			endcase
		end
		endcase
	end

	// ---- floating point ----------------------------------------------------
	6'd59, 6'd63: begin
		dec.fc.single = ~opcd[2];
		dec.fc.rc     = f_rc;
		if (insn[5]) begin
			// A form: 5-bit extended opcode
			dec.unit = UNIT_FPU;
			dec.frd_wr = 1; dec.fpscr_wr = 1;
			dec.cr_wr = f_rc; dec.cr_fld = 3'd1;
			case (xo5)
			5'd18: begin dec.valid = 1; dec.fc.op = FPU_DIV; dec.fra_rd = 1; dec.frb_rd = 1; end
			5'd20: begin dec.valid = 1; dec.fc.op = FPU_SUB; dec.fra_rd = 1; dec.frb_rd = 1; end
			5'd21: begin dec.valid = 1; dec.fc.op = FPU_ADD; dec.fra_rd = 1; dec.frb_rd = 1; end
			5'd23: begin // fsel
				dec.valid = opcd[2]; dec.fc.op = FPU_SEL; dec.fpscr_wr = 0;
				dec.fra_rd = 1; dec.frb_rd = 1; dec.frc_rd = 1;
			end
			5'd24: begin dec.valid = ~opcd[2]; dec.fc.op = FPU_RES; dec.frb_rd = 1; end
			5'd25: begin dec.valid = 1; dec.fc.op = FPU_MUL; dec.fra_rd = 1; dec.frc_rd = 1; end
			5'd26: begin dec.valid = opcd[2]; dec.fc.op = FPU_RSQRTE; dec.frb_rd = 1; end
			5'd28: begin dec.valid = 1; dec.fc.op = FPU_MSUB;  dec.fra_rd = 1; dec.frb_rd = 1; dec.frc_rd = 1; end
			5'd29: begin dec.valid = 1; dec.fc.op = FPU_MADD;  dec.fra_rd = 1; dec.frb_rd = 1; dec.frc_rd = 1; end
			5'd30: begin dec.valid = 1; dec.fc.op = FPU_NMSUB; dec.fra_rd = 1; dec.frb_rd = 1; dec.frc_rd = 1; end
			5'd31: begin dec.valid = 1; dec.fc.op = FPU_NMADD; dec.fra_rd = 1; dec.frb_rd = 1; dec.frc_rd = 1; end
			default: ;
			endcase
		end
		else if (opcd[2]) begin
			// X form, opcode 63 only
			dec.unit = UNIT_FPU;
			case (xo10)
			10'd0, 10'd32: begin // fcmpu, fcmpo
				dec.valid = 1; dec.fc.op = xo10[5] ? FPU_CMPO : FPU_CMPU;
				dec.fra_rd = 1; dec.frb_rd = 1;
				dec.fpscr_wr = 1;
				dec.cr_wr = 1; dec.cr_fld = insn[25:23];
				dec.fc.rc = 0;
			end
			10'd12, 10'd14, 10'd15: begin // frsp, fctiw, fctiwz
				dec.valid = 1;
				dec.fc.op = (xo10 == 10'd12) ? FPU_RSP :
				            (xo10 == 10'd14) ? FPU_CTIW : FPU_CTIWZ;
				dec.frb_rd = 1; dec.frd_wr = 1; dec.fpscr_wr = 1;
				dec.cr_wr = f_rc; dec.cr_fld = 3'd1;
			end
			10'd40, 10'd72, 10'd136, 10'd264: begin // fneg, fmr, fnabs, fabs
				dec.valid = 1;
				dec.fc.op = (xo10 == 10'd40)  ? FPU_NEG :
				            (xo10 == 10'd72)  ? FPU_MR :
				            (xo10 == 10'd136) ? FPU_NABS : FPU_ABS;
				dec.frb_rd = 1; dec.frd_wr = 1;
				dec.cr_wr = f_rc; dec.cr_fld = 3'd1;
			end
			default: ;
			endcase
		end
	end

	default: ;
	endcase

	// nothing about an unimplemented instruction may look like a request
	if (!dec.valid) dec = '0;
end

endmodule

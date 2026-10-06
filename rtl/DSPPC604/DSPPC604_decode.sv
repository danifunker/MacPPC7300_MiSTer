//============================================================================
//
//  DSPPC604 - PowerPC 604-class CPU core
//  Instruction decoder (combinational)
//
//  Covers the user-mode integer instruction set (arithmetic, logical,
//  compare, rotate and shift, loads and stores, branches, CR logic, moves to
//  and from CR, LR, CTR and XER) and the floating-point arithmetic, move,
//  convert and compare instructions.
//
//  dcbt and dcbtst are hints and stay no-ops; dcbz, dcbst, dcbf, dcbi and
//  icbi are data accesses of their own kind (dec.cop), which the data cache
//  carries out. tlbsync is accepted and does nothing, there being one
//  processor.
//
//  Multi-operation instructions (update forms, lmw/stmw, string forms) are
//  decoded here as their first operation, with dec.seq telling the sequencer
//  what follows.
//
//============================================================================

module DSPPC604_decode
(
	input  logic [31:0]        insn,
	output DSPPC604_pkg::dec_t dec
);

import DSPPC604_pkg::*;

wire [5:0]  opcd = insn[31:26];
wire [5:0]  f_d  = {1'b0, insn[25:21]};   // rD, rS, frD
wire [5:0]  f_a  = {1'b0, insn[20:16]};   // rA, frA
wire [5:0]  f_b  = {1'b0, insn[15:11]};   // rB, frB, SH
wire [4:0]  f_c  = insn[10:6];            // frC, MB
wire [9:0]  xo10 = insn[10:1];
wire [8:0]  xo9  = insn[9:1];
wire [4:0]  xo5  = insn[5:1];
wire        f_oe = insn[10];
wire        f_rc = insn[0];
wire        a_nz = (insn[20:16] != 5'd0); // (rA|0) reads a register

// Which field names each operand is a small function of the opcode, decided
// here and not in the case below, so that the register file's read mux does
// not wait for the whole decode. A is rS (the rD field) for the rotates, the
// logical and shift instructions and the moves to CR, the SPRs, MSR and the
// segment registers; B is rA for rlwimi; C, the value a store writes, is rS.
wire x31_a_rs = (xo10 == 10'd26)  | (xo10 == 10'd922) | (xo10 == 10'd954) |             // cntlzw, extsh, extsb
                (xo10 == 10'd28)  | (xo10 == 10'd60)  | (xo10 == 10'd124) |             // and, andc, nor
                (xo10 == 10'd284) | (xo10 == 10'd316) | (xo10 == 10'd412) |             // eqv, xor, orc
                (xo10 == 10'd444) | (xo10 == 10'd476) |                                  // or, nand
                (xo10 == 10'd24)  | (xo10 == 10'd536) | (xo10 == 10'd792) | (xo10 == 10'd824) |   // slw, srw, sraw, srawi
                (xo10 == 10'd144) | (xo10 == 10'd467) | (xo10 == 10'd146) |             // mtcrf, mtspr, mtmsr
                (xo10 == 10'd210) | (xo10 == 10'd242);                                   // mtsr, mtsrin
wire a_is_rs  = (opcd == 6'd20) | (opcd == 6'd21) | (opcd == 6'd23) |                   // rlwimi, rlwinm, rlwnm
                (opcd[5:2] == 4'b0110) | (opcd[5:1] == 5'b01110) |                       // ori ... andis. (24-29)
                ((opcd == 6'd31) & x31_a_rs);

wire [31:0] simm  = {{16{insn[15]}}, insn[15:0]};
wire [31:0] uimm  = {16'd0, insn[15:0]};
wire [31:0] shimm = {insn[15:0], 16'd0};

always_comb begin
	dec = '0;

	// fields that are always in the same place
	dec.ic.sh  = insn[15:11];
	dec.ic.mb  = f_c;
	dec.ic.me  = xo5;
	dec.fra    = insn[20:16];
	dec.frb    = insn[15:11];
	dec.frc    = f_c;
	dec.frd    = insn[25:21];
	dec.bo     = insn[25:21];
	dec.bi     = insn[20:16];
	dec.crbt   = insn[25:21];
	dec.crba   = insn[20:16];
	dec.crbb   = insn[15:11];
	dec.crm    = insn[19:12];
	dec.spr    = {insn[15:11], insn[20:16]};
	dec.mem_n  = 4'd4;
	dec.ra     = a_is_rs ? f_d : f_a;        // read only when ra_rd says so, below
	dec.rb     = (opcd == 6'd20) ? f_a : f_b;
	dec.rc     = f_d;

	case (opcd)

	// ---- traps and system call ---------------------------------------------
	6'd3: begin // twi: a compare in the ALU (b - a), the TO field decides in EX
		dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_CMP; dec.trap = 1;
		dec.ic.inv_a = 1; dec.ic.cin = CIN_ONE;
		dec.ra_rd = 1; dec.b_imm = 1; dec.imm = simm;
	end
	6'd17: begin // sc
		dec.valid = insn[1]; dec.unit = UNIT_SYS; dec.sys = SYS_SC;
	end

	// ---- integer, immediate operand ---------------------------------------
	6'd7: begin // mulli
		dec.valid = 1; dec.unit = UNIT_MUL;
		dec.ra_rd = 1; dec.b_imm = 1; dec.imm = simm;
		dec.rd = f_d; dec.rd_wr = 1;
		dec.ic.is_signed = 1;
	end
	6'd8: begin // subfic
		dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ADD;
		dec.ra_rd = 1; dec.b_imm = 1; dec.imm = simm;
		dec.rd = f_d; dec.rd_wr = 1;
		dec.ic.inv_a = 1; dec.ic.cin = CIN_ONE; dec.ca_wr = 1;
	end
	6'd10, 6'd11: begin // cmpli, cmpi: the adder forms b - a, its flags are the compare
		dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_CMP;
		dec.ic.inv_a = 1; dec.ic.cin = CIN_ONE;
		dec.ra_rd = 1; dec.b_imm = 1;
		dec.imm = opcd[0] ? simm : uimm;
		dec.ic.is_signed = opcd[0];
		dec.cr_wr = 1; dec.cr_fld = insn[25:23];
	end
	6'd12, 6'd13: begin // addic, addic.
		dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ADD;
		dec.ra_rd = 1; dec.b_imm = 1; dec.imm = simm;
		dec.rd = f_d; dec.rd_wr = 1;
		dec.ca_wr = 1;
		dec.cr_wr = opcd[0];
	end
	6'd14, 6'd15: begin // addi, addis: (rA|0)
		dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ADD;
		dec.ra_rd = a_nz; dec.b_imm = 1;
		dec.imm = opcd[0] ? shimm : simm;
		dec.rd = f_d; dec.rd_wr = 1;
	end

	// ---- branches ----------------------------------------------------------
	6'd16: begin // bc
		dec.valid = 1; dec.unit = UNIT_SYS; dec.sys = SYS_NOP;
		dec.br = BR_IMM; dec.br_aa = insn[1]; dec.br_lk = insn[0];
		dec.imm = {{16{insn[15]}}, insn[15:2], 2'b00};
	end
	6'd18: begin // b
		dec.valid = 1; dec.unit = UNIT_SYS; dec.sys = SYS_NOP;
		dec.br = BR_IMM; dec.br_aa = insn[1]; dec.br_lk = insn[0];
		dec.imm = {{6{insn[25]}}, insn[25:2], 2'b00};
		dec.bo  = 5'b10100;      // always
	end

	// ---- opcode 19: branches to LR and CTR, CR logic -----------------------
	6'd19: begin
		case (xo10)
		10'd16, 10'd528: begin // bclr, bcctr
			dec.valid = 1; dec.unit = UNIT_SYS; dec.sys = SYS_NOP;
			dec.br = xo10[9] ? BR_CTR : BR_LR; dec.br_lk = insn[0];
			// bcctr cannot also count CTR down
			if (xo10[9]) dec.bo[2] = 1'b1;
		end
		10'd0: begin // mcrf
			dec.valid = 1; dec.unit = UNIT_SYS; dec.sys = SYS_MCRF;
		end
		10'd33, 10'd129, 10'd193, 10'd225, 10'd257, 10'd289, 10'd417, 10'd449: begin
			// crnor, crandc, crxor, crnand, crand, creqv, crorc, cror
			dec.valid = 1; dec.unit = UNIT_SYS; dec.sys = SYS_CRLOG;
			case (xo10)
				10'd33:  dec.crtt = 4'b0001;
				10'd129: dec.crtt = 4'b0100;
				10'd193: dec.crtt = 4'b0110;
				10'd225: dec.crtt = 4'b0111;
				10'd257: dec.crtt = 4'b1000;
				10'd289: dec.crtt = 4'b1001;
				10'd417: dec.crtt = 4'b1101;
				default: dec.crtt = 4'b1110;
			endcase
		end
		10'd150: begin // isync
			dec.valid = 1; dec.unit = UNIT_SYS; dec.sys = SYS_ISYNC;
		end
		10'd50: begin // rfi
			dec.valid = 1; dec.unit = UNIT_SYS; dec.sys = SYS_RFI; dec.priv = 1;
		end
		default: ;
		endcase
	end

	// ---- rotates -----------------------------------------------------------
	6'd20: begin // rlwimi: A = rS, B = rA (the word being inserted into)
		dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ROT;
		dec.ic.rot_op = ROT_RLWIMI;
		dec.ra_rd = 1; dec.rb_rd = 1;
		dec.rd = f_a; dec.rd_wr = 1;
		dec.cr_wr = f_rc;
	end
	6'd21, 6'd23: begin // rlwinm, rlwnm
		dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ROT;
		dec.ic.rot_op = ROT_RLWINM;
		dec.ra_rd = 1;
		dec.rb_rd = opcd[1]; dec.ic.sh_reg = opcd[1];
		dec.rd = f_a; dec.rd_wr = 1;
		dec.cr_wr = f_rc;
	end

	// ---- logical, immediate operand ---------------------------------------
	6'd24, 6'd25, 6'd26, 6'd27, 6'd28, 6'd29: begin
		// ori, oris, xori, xoris, andi., andis.
		dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_LOGIC;
		dec.ra_rd = 1; dec.b_imm = 1;
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
			dec.ic.inv_a = 1; dec.ic.cin = CIN_ONE;
			dec.ra_rd = 1; dec.rb_rd = 1;
			dec.ic.is_signed = ~xo10[5];
			dec.cr_wr = 1; dec.cr_fld = insn[25:23];
		end
		10'd26: begin // cntlzw
			dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_CNTLZ;
			dec.ra_rd = 1;
			dec.rd = f_a; dec.rd_wr = 1;
			dec.cr_wr = f_rc;
		end
		10'd922, 10'd954: begin // extsh, extsb
			dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_EXTS;
			dec.ic.ext_byte = xo10[5];
			dec.ra_rd = 1;
			dec.rd = f_a; dec.rd_wr = 1;
			dec.cr_wr = f_rc;
		end
		10'd28, 10'd60, 10'd124, 10'd284, 10'd316, 10'd412, 10'd444, 10'd476: begin
			// and, andc, nor, eqv, xor, orc, or, nand
			dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_LOGIC;
			dec.ra_rd = 1; dec.rb_rd = 1;
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
			dec.ra_rd = 1; dec.rb_rd = 1;
			dec.rd = f_a; dec.rd_wr = 1;
			dec.ca_wr = (xo10 == 10'd792);
			dec.cr_wr = f_rc;
		end
		10'd824: begin // srawi
			dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ROT;
			dec.ic.rot_op = ROT_SRAW;
			dec.ra_rd = 1;
			dec.rd = f_a; dec.rd_wr = 1;
			dec.ca_wr = 1;
			dec.cr_wr = f_rc;
		end

		// ---- loads and stores, indexed -------------------------------------
		10'd23, 10'd55, 10'd87, 10'd119, 10'd279, 10'd311, 10'd343, 10'd375,
		10'd534, 10'd790: begin
			// lwzx lwzux lbzx lbzux lhzx lhzux lhax lhaux lwbrx lhbrx
			dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ADD;
			dec.ra_rd = a_nz; dec.rb_rd = 1;
			dec.rd = f_d; dec.rd_wr = 1;
			dec.mem_rd = 1;
			case (xo10)
				10'd23:  begin end
				10'd55:  begin dec.seq = SEQ_UPDATE; end
				10'd87:  begin dec.mem_n = 4'd1; end
				10'd119: begin dec.mem_n = 4'd1; dec.seq = SEQ_UPDATE; end
				10'd279: begin dec.mem_n = 4'd2; end
				10'd311: begin dec.mem_n = 4'd2; dec.seq = SEQ_UPDATE; end
				10'd343: begin dec.mem_n = 4'd2; dec.mem_sext = 1; end
				10'd375: begin dec.mem_n = 4'd2; dec.mem_sext = 1; dec.seq = SEQ_UPDATE; end
				10'd534: begin dec.mem_brev = 1; end
				default: begin dec.mem_n = 4'd2; dec.mem_brev = 1; end
			endcase
		end
		10'd151, 10'd183, 10'd215, 10'd247, 10'd407, 10'd439, 10'd662, 10'd918: begin
			// stwx stwux stbx stbux sthx sthux stwbrx sthbrx
			dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ADD;
			dec.ra_rd = a_nz; dec.rb_rd = 1;
			dec.rc_rd = 1;
			dec.mem_wr = 1;
			case (xo10)
				10'd151: begin end
				10'd183: begin dec.seq = SEQ_UPDATE; end
				10'd215: begin dec.mem_n = 4'd1; end
				10'd247: begin dec.mem_n = 4'd1; dec.seq = SEQ_UPDATE; end
				10'd407: begin dec.mem_n = 4'd2; end
				10'd439: begin dec.mem_n = 4'd2; dec.seq = SEQ_UPDATE; end
				10'd662: begin dec.mem_brev = 1; end
				default: begin dec.mem_n = 4'd2; dec.mem_brev = 1; end
			endcase
		end
		10'd20: begin // lwarx
			dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ADD;
			dec.ra_rd = a_nz; dec.rb_rd = 1;
			dec.rd = f_d; dec.rd_wr = 1;
			dec.mem_rd = 1; dec.resv = RESV_SET;
		end
		10'd150: begin // stwcx.: the store, then CR0. Without Rc the 604 calls it illegal (measured)
			dec.valid = f_rc; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ADD;
			dec.ra_rd = a_nz; dec.rb_rd = 1;
			dec.rc_rd = 1;
			dec.mem_wr = 1; dec.resv = RESV_STORE; dec.seq = SEQ_STWCX;
		end
		10'd1014: begin // dcbz: the line, zero
			dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ADD;
			dec.ra_rd = a_nz; dec.rb_rd = 1;
			dec.mem_wr = 1; dec.cop = CK_ZERO;
		end
		10'd54, 10'd86, 10'd470, 10'd982: begin // dcbst, dcbf, dcbi, icbi
			dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ADD;
			dec.ra_rd = a_nz; dec.rb_rd = 1;
			case (xo10)
				10'd54:  begin dec.mem_rd = 1; dec.cop = CK_STORE; end
				10'd86:  begin dec.mem_rd = 1; dec.cop = CK_FLUSH; end
				10'd470: begin dec.mem_wr = 1; dec.cop = CK_INVAL; dec.priv = 1; end   // a store, supervisor only
				default: begin dec.mem_rd = 1; dec.cop = CK_ICBI; end
			endcase
		end
		10'd597, 10'd725: begin // lswi, stswi: bytes at (rA|0), count in the NB field
			dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ADD;
			dec.ra_rd = a_nz; dec.b_imm = 1;
			dec.mem_ljust = 1; dec.seq = SEQ_STRI;
			if (xo10[7]) begin dec.rc_rd = 1; dec.mem_wr = 1; end
			else         begin dec.rd = f_d; dec.rd_wr = 1; dec.mem_rd = 1; end
		end
		10'd533, 10'd661: begin // lswx, stswx: bytes at (rA|0) + rB, count in XER
			dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ADD;
			dec.ra_rd = a_nz; dec.rb_rd = 1;
			dec.mem_ljust = 1; dec.seq = SEQ_STRX;
			if (xo10[7]) begin dec.rc_rd = 1; dec.mem_wr = 1; end
			else         begin dec.rd = f_d; dec.rd_wr = 1; dec.mem_rd = 1; end
		end

		10'd535, 10'd567, 10'd599, 10'd631: begin // lfsx lfsux lfdx lfdux
			dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ADD;
			dec.ra_rd = a_nz; dec.rb_rd = 1;
			dec.frd_wr = 1;
			dec.mem_rd = 1; dec.mem_fp = 1;
			dec.mem_fsgl = ~xo10[6]; dec.mem_n = xo10[6] ? 4'd8 : 4'd4;
			if (xo10[5]) dec.seq = SEQ_UPDATE;
		end
		10'd663, 10'd695, 10'd727, 10'd759, 10'd983: begin // stfsx stfsux stfdx stfdux stfiwx
			dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ADD;
			dec.ra_rd = a_nz; dec.rb_rd = 1;
			dec.frb = insn[25:21]; dec.frb_rd = 1;
			dec.mem_wr = 1; dec.mem_fp = 1;
			if (xo10 == 10'd983) begin
				dec.mem_n = 4'd4;                // the low word as it is
			end
			else begin
				dec.mem_fsgl = ~xo10[6]; dec.mem_n = xo10[6] ? 4'd8 : 4'd4;
				if (xo10[5]) dec.seq = SEQ_UPDATE;
			end
		end

		// ---- moves to and from CR and SPRs ---------------------------------
		10'd19: begin // mfcr
			dec.valid = 1; dec.unit = UNIT_SYS; dec.sys = SYS_MFCR;
			dec.rd = f_d; dec.rd_wr = 1;
		end
		10'd144: begin // mtcrf
			dec.valid = 1; dec.unit = UNIT_SYS; dec.sys = SYS_MTCRF;
			dec.ra_rd = 1;
		end
		10'd512: begin // mcrxr
			dec.valid = 1; dec.unit = UNIT_SYS; dec.sys = SYS_MCRXR;
		end
		10'd339: begin // mfspr: the execute stage knows which SPRs exist (an SPR that does not is illegal in either mode)
			dec.valid = 1; dec.unit = UNIT_SYS; dec.sys = SYS_MFSPR;
			dec.priv = dec.spr[4];
			dec.rd = f_d; dec.rd_wr = 1;
		end
		10'd467: begin // mtspr
			dec.valid = 1; dec.unit = UNIT_SYS; dec.sys = SYS_MTSPR;
			dec.priv = dec.spr[4];
			dec.ra_rd = 1;
		end
		10'd371: begin // mftb: the time base, readable in user mode
			dec.unit = UNIT_SYS; dec.sys = SYS_MFSPR;
			dec.valid = (dec.spr == 10'd268) | (dec.spr == 10'd269);
			dec.spr = dec.spr[0] ? 10'd285 : 10'd284;
			dec.rd = f_d; dec.rd_wr = 1;
		end
		10'd4: begin // tw: as twi
			dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_CMP; dec.trap = 1;
			dec.ic.inv_a = 1; dec.ic.cin = CIN_ONE;
			dec.ra_rd = 1; dec.rb_rd = 1;
		end
		10'd83: begin // mfmsr
			dec.valid = 1; dec.unit = UNIT_SYS; dec.sys = SYS_MFMSR; dec.priv = 1;
			dec.rd = f_d; dec.rd_wr = 1;
		end
		10'd146: begin // mtmsr
			dec.valid = 1; dec.unit = UNIT_SYS; dec.sys = SYS_MTMSR; dec.priv = 1;
			dec.ra_rd = 1;
		end
		10'd595, 10'd659: begin // mfsr, mfsrin
			dec.valid = 1; dec.unit = UNIT_SYS; dec.sys = SYS_MFSR; dec.priv = 1;
			dec.rb_rd = xo10[7];   // mfsrin takes the number from rB
			dec.rd = f_d; dec.rd_wr = 1;
		end
		10'd210, 10'd242: begin // mtsr, mtsrin
			dec.valid = 1; dec.unit = UNIT_SYS; dec.sys = SYS_MTSR; dec.priv = 1;
			dec.ra_rd = 1;
			dec.rb_rd = xo10[5];
		end
		10'd306: begin // tlbie
			dec.valid = 1; dec.unit = UNIT_SYS; dec.sys = SYS_TLBIE; dec.priv = 1;
			dec.rb_rd = 1;
		end
		10'd566: begin // tlbsync
			dec.valid = 1; dec.unit = UNIT_SYS; dec.sys = SYS_NOP; dec.priv = 1;
		end
		10'd310, 10'd438: begin // eciwx, ecowx: always a DSI here (EAR[E] is never set by anything)
			dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ADD;
			dec.ra_rd = a_nz; dec.rb_rd = 1;
			dec.mem_ext = 1;
			if (xo10[7]) dec.mem_wr = 1;
		end
		10'd598, 10'd854: begin // sync, eieio
			dec.valid = 1; dec.unit = UNIT_SYS; dec.sys = SYS_NOP;
		end
		10'd278, 10'd246: begin // dcbt, dcbtst: hints, never fault; doing nothing is allowed
			dec.valid = 1; dec.unit = UNIT_SYS; dec.sys = SYS_NOP;
		end

		default: begin
			// XO form: 9-bit extended opcode with OE above it
			case (xo9)
			9'd8, 9'd10, 9'd40, 9'd104, 9'd136, 9'd138,
			9'd200, 9'd202, 9'd232, 9'd234, 9'd266: begin
				// subfc, addc, subf, neg, subfe, adde,
				// subfze, addze, subfme, addme, add
				dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ADD;
				dec.ra_rd = 1; dec.rb_rd = 1;
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
				dec.ra_rd = 1; dec.rb_rd = 1;
				dec.rd = f_d; dec.rd_wr = 1;
				dec.ic.is_signed = xo9[6]; dec.ic.mul_high = 1;
				dec.cr_wr = f_rc;
			end
			9'd235: begin // mullw
				dec.valid = 1; dec.unit = UNIT_MUL;
				dec.ra_rd = 1; dec.rb_rd = 1;
				dec.rd = f_d; dec.rd_wr = 1;
				dec.ic.is_signed = 1;
				dec.ic.oe = f_oe; dec.ov_wr = f_oe;
				dec.cr_wr = f_rc;
			end
			9'd459, 9'd491: begin // divwu, divw
				dec.valid = 1; dec.unit = UNIT_DIV;
				dec.ra_rd = 1; dec.rb_rd = 1;
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

	// ---- loads and stores, displacement ------------------------------------
	6'd32, 6'd33, 6'd34, 6'd35, 6'd40, 6'd41, 6'd42, 6'd43: begin
		// lwz lwzu lbz lbzu lhz lhzu lha lhau
		dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ADD;
		dec.ra_rd = a_nz; dec.b_imm = 1; dec.imm = simm;
		dec.rd = f_d; dec.rd_wr = 1;
		dec.mem_rd = 1;
		dec.mem_n  = opcd[3] ? 4'd2 : opcd[1] ? 4'd1 : 4'd4;
		dec.mem_sext = opcd[3] & opcd[1];
		if (opcd[0]) dec.seq = SEQ_UPDATE;
	end
	6'd36, 6'd37, 6'd38, 6'd39, 6'd44, 6'd45: begin
		// stw stwu stb stbu sth sthu
		dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ADD;
		dec.ra_rd = a_nz; dec.b_imm = 1; dec.imm = simm;
		dec.rc_rd = 1;
		dec.mem_wr = 1;
		dec.mem_n  = opcd[3] ? 4'd2 : opcd[1] ? 4'd1 : 4'd4;
		if (opcd[0]) dec.seq = SEQ_UPDATE;
	end
	6'd46: begin // lmw
		dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ADD;
		dec.ra_rd = a_nz; dec.b_imm = 1; dec.imm = simm;
		dec.rd = f_d; dec.rd_wr = 1;
		dec.mem_rd = 1; dec.seq = SEQ_MULTI;
	end
	6'd47: begin // stmw
		dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ADD;
		dec.ra_rd = a_nz; dec.b_imm = 1; dec.imm = simm;
		dec.rc_rd = 1;
		dec.mem_wr = 1; dec.seq = SEQ_MULTI;
	end

	6'd48, 6'd49, 6'd50, 6'd51: begin // lfs lfsu lfd lfdu
		dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ADD;
		dec.ra_rd = a_nz; dec.b_imm = 1; dec.imm = simm;
		dec.frd_wr = 1;
		dec.mem_rd = 1; dec.mem_fp = 1;
		dec.mem_fsgl = ~opcd[1]; dec.mem_n = opcd[1] ? 4'd8 : 4'd4;
		if (opcd[0]) dec.seq = SEQ_UPDATE;
	end
	6'd52, 6'd53, 6'd54, 6'd55: begin // stfs stfsu stfd stfdu
		dec.valid = 1; dec.unit = UNIT_ALU; dec.ic.alu_op = ALU_ADD;
		dec.ra_rd = a_nz; dec.b_imm = 1; dec.imm = simm;
		dec.frb = insn[25:21]; dec.frb_rd = 1;
		dec.mem_wr = 1; dec.mem_fp = 1;
		dec.mem_fsgl = ~opcd[1]; dec.mem_n = opcd[1] ? 4'd8 : 4'd4;
		if (opcd[0]) dec.seq = SEQ_UPDATE;
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
			10'd583: begin // mffs
				dec.valid = 1; dec.unit = UNIT_SYS; dec.sys = SYS_MFFS;
				dec.frd_wr = 1;
				dec.cr_wr = f_rc; dec.cr_fld = 3'd1;
			end
			10'd711: begin // mtfsf
				dec.valid = 1; dec.unit = UNIT_SYS; dec.sys = SYS_MTFSF;
				dec.frb_rd = 1; dec.fpscr_wr = 1;
				dec.cr_wr = f_rc; dec.cr_fld = 3'd1;
			end
			10'd134, 10'd70, 10'd38: begin // mtfsfi, mtfsb0, mtfsb1
				dec.valid = 1; dec.unit = UNIT_SYS;
				dec.sys = (xo10 == 10'd134) ? SYS_MTFSFI :
				          (xo10 == 10'd70)  ? SYS_MTFSB0 : SYS_MTFSB1;
				dec.fpscr_wr = 1;
				dec.cr_wr = f_rc; dec.cr_fld = 3'd1;
			end
			10'd64: begin // mcrfs
				dec.valid = 1; dec.unit = UNIT_SYS; dec.sys = SYS_MCRFS;
				dec.fpscr_wr = 1;
				dec.cr_wr = 1; dec.cr_fld = insn[25:23];
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

	// every instruction that touches a floating-point register or FPSCR
	dec.fp_use = (dec.unit == UNIT_FPU) | dec.mem_fp |
	             ((dec.unit == UNIT_SYS) & ((dec.sys == SYS_MFFS) | (dec.sys == SYS_MTFSF) |
	              (dec.sys == SYS_MTFSFI) | (dec.sys == SYS_MTFSB0) | (dec.sys == SYS_MTFSB1) |
	              (dec.sys == SYS_MCRFS)));

	// nothing about an unimplemented instruction may look like a request
	if (!dec.valid) dec = '0;
end

endmodule

//============================================================================
//
//  DSPPC604 - PowerPC 604-class CPU core
//  Shared types
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//============================================================================

package DSPPC604_pkg;

	// Which execute unit handles an instruction.
	typedef enum logic [2:0] {
		UNIT_NONE,     // not an instruction this core implements (yet)
		UNIT_ALU,      // integer, result in the cycle it is requested
		UNIT_MUL,      // integer multiply
		UNIT_DIV,      // integer divide
		UNIT_FPU,      // floating point
		UNIT_SYS       // CR logic, moves to and from CR and SPRs (in the pipeline)
	} unit_t;

	// What a UNIT_SYS instruction does.
	typedef enum logic [2:0] {
		SYS_NOP,       // sync, eieio, isync (until there is something to synchronise)
		SYS_CRLOG,     // CR bit BT <- BA op BB
		SYS_MCRF,
		SYS_MFCR,
		SYS_MTCRF,
		SYS_MCRXR,
		SYS_MFSPR,
		SYS_MTSPR
	} sys_op_t;

	// Where a branch goes.
	typedef enum logic [1:0] {
		BR_NONE,       // not a branch
		BR_IMM,        // b, bc: displacement in imm
		BR_LR,         // bclr
		BR_CTR         // bcctr
	} br_t;

	// Instructions the sequencer in the decode stage expands into several
	// simple operations.
	typedef enum logic [2:0] {
		SEQ_NONE,
		SEQ_UPDATE,    // load/store with update: the access, then rA <- EA
		SEQ_MULTI,     // lmw, stmw: one word per register
		SEQ_STRI,      // lswi, stswi: byte count in the instruction
		SEQ_STRX       // lswx, stswx: byte count in XER
	} seq_t;

	// Register 32 is a scratch register that only the sequencer can name.
	localparam logic [5:0] REG_TEMP = 6'd32;

	typedef enum logic [2:0] {
		ALU_ADD,       // adder: add, subtract, negate
		ALU_CMP,       // compare; only a CR field is produced
		ALU_LOGIC,
		ALU_ROT,       // rotates and shifts, through one rotator and mask
		ALU_CNTLZ,
		ALU_EXTS
	} alu_op_t;

	typedef enum logic [1:0] {
		CIN_ZERO,
		CIN_ONE,
		CIN_CA         // XER[CA]
	} cin_t;

	typedef enum logic [1:0] {
		LOG_AND,
		LOG_OR,
		LOG_XOR
	} log_op_t;

	typedef enum logic [2:0] {
		ROT_RLWINM,    // rotate left, AND with mask(MB,ME); also rlwnm
		ROT_RLWIMI,    // rotate left, insert under mask(MB,ME) into operand B
		ROT_SLW,
		ROT_SRW,
		ROT_SRAW       // also srawi
	} rot_op_t;

	typedef enum logic [4:0] {
		FPU_ADD,
		FPU_SUB,
		FPU_MUL,
		FPU_DIV,
		FPU_MADD,
		FPU_MSUB,
		FPU_NMADD,
		FPU_NMSUB,
		FPU_RSP,
		FPU_CTIW,
		FPU_CTIWZ,
		FPU_MR,
		FPU_NEG,
		FPU_ABS,
		FPU_NABS,
		FPU_SEL,
		FPU_RES,
		FPU_RSQRTE,
		FPU_CMPU,
		FPU_CMPO
	} fpu_op_t;

	// Control for the integer execute unit.
	typedef struct packed {
		alu_op_t     alu_op;
		logic        inv_a;        // adder uses ~A
		cin_t        cin;          // adder carry in
		log_op_t     log_op;
		logic        log_inv_b;    // andc, orc
		logic        log_inv_out;  // nand, nor, eqv
		rot_op_t     rot_op;
		logic        sh_reg;       // shift count from operand B, not SH
		logic [4:0]  sh;
		logic [4:0]  mb;
		logic [4:0]  me;
		logic        ext_byte;     // extsb, otherwise extsh
		logic        is_signed;    // compare, multiply, divide
		logic        mul_high;     // mulhw, mulhwu
		logic        oe;           // result of XER[OV] is wanted
	} int_ctl_t;

	// Control for the floating-point unit.
	typedef struct packed {
		fpu_op_t     op;
		logic        single;       // result rounded to single precision
		logic        rc;           // CR1 is wanted
	} fpu_ctl_t;

	// Everything the decoder knows about one instruction.
	//
	// Integer operands: A is register ra when ra_rd is set, otherwise zero.
	// B is the immediate when b_imm is set, otherwise register rb. C is
	// register rc, the value a store writes.
	typedef struct packed {
		logic        valid;        // an instruction this core implements
		unit_t       unit;

		logic [5:0]  ra;
		logic        ra_rd;
		logic [5:0]  rb;
		logic        rb_rd;
		logic        b_imm;
		logic [31:0] imm;
		logic [5:0]  rc;
		logic        rc_rd;
		logic [5:0]  rd;           // integer destination
		logic        rd_wr;

		// memory access at A + B
		logic        mem_rd;
		logic        mem_wr;
		logic [2:0]  mem_n;        // bytes, 1 to 4
		logic        mem_sext;     // lha: sign-extend the halfword
		logic        mem_brev;     // byte-reversed forms
		logic        mem_ljust;    // string forms: bytes fill the register from the top
		seq_t        seq;

		// branch
		br_t         br;
		logic        br_aa;        // absolute target
		logic        br_lk;        // LR <- address of the next instruction
		logic [4:0]  bo;
		logic [4:0]  bi;

		// CR and SPR moves
		sys_op_t     sys;
		logic [3:0]  crtt;         // CR logic truth table, indexed by {BA, BB}
		logic [4:0]  crbt;
		logic [4:0]  crba;
		logic [4:0]  crbb;
		logic [7:0]  crm;          // mtcrf field mask
		logic [9:0]  spr;

		logic [4:0]  fra;
		logic        fra_rd;
		logic [4:0]  frb;
		logic        frb_rd;
		logic [4:0]  frc;
		logic        frc_rd;
		logic [4:0]  frd;          // floating-point destination
		logic        frd_wr;

		logic        ca_wr;        // updates XER[CA]
		logic        ov_wr;        // updates XER[OV] and XER[SO]
		logic        cr_wr;        // updates CR field cr_fld
		logic [2:0]  cr_fld;
		logic        fpscr_wr;     // updates FPSCR

		int_ctl_t    ic;
		fpu_ctl_t    fc;
	} dec_t;

endpackage

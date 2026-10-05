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
		UNIT_FPU       // floating point
	} unit_t;

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
	// B is the immediate when b_imm is set, otherwise register rb.
	typedef struct packed {
		logic        valid;        // an instruction this core implements
		unit_t       unit;

		logic [4:0]  ra;
		logic        ra_rd;
		logic [4:0]  rb;
		logic        rb_rd;
		logic        b_imm;
		logic [31:0] imm;
		logic [4:0]  rd;           // integer destination
		logic        rd_wr;

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

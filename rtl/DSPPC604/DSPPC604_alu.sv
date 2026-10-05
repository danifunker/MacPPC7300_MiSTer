//============================================================================
//
//  DSPPC604 - PowerPC 604-class CPU core
//  Integer ALU (combinational)
//
//  Adder, compare, logic, count leading zeros, sign extension, and one
//  rotator with a mask generator that serves every rotate and shift.
//
//============================================================================

module DSPPC604_alu
(
	input  DSPPC604_pkg::int_ctl_t ctl,
	input  logic [31:0] a,
	input  logic [31:0] b,
	input  logic        ca_in,

	output logic [31:0] result,
	output logic        ca_out,
	output logic        ov_out,
	output logic        lt,          // compare results, A against B
	output logic        gt,
	output logic        eq
);

import DSPPC604_pkg::*;

// ---- adder -----------------------------------------------------------------
logic [31:0] add_a;
logic        add_ci;
logic [32:0] add_sum;

always_comb begin
	add_a = ctl.inv_a ? ~a : a;
	case (ctl.cin)
		CIN_ONE: add_ci = 1'b1;
		CIN_CA:  add_ci = ca_in;
		default: add_ci = 1'b0;
	endcase
	add_sum = {1'b0, add_a} + {1'b0, b} + {32'd0, add_ci};
end

wire add_ov = (add_a[31] == b[31]) & (add_sum[31] != add_a[31]);

// ---- compare ---------------------------------------------------------------
always_comb begin
	eq = (a == b);
	lt = ctl.is_signed ? ($signed(a) < $signed(b)) : (a < b);
	gt = ~lt & ~eq;
end

// ---- logic -----------------------------------------------------------------
logic [31:0] log_b;
logic [31:0] log_raw;
logic [31:0] log_res;

always_comb begin
	log_b = ctl.log_inv_b ? ~b : b;
	case (ctl.log_op)
		LOG_OR:  log_raw = a | log_b;
		LOG_XOR: log_raw = a ^ log_b;
		default: log_raw = a & log_b;
	endcase
	log_res = ctl.log_inv_out ? ~log_raw : log_raw;
end

// ---- rotate and mask -------------------------------------------------------
// mask(mb, me): ones from bit mb through bit me in PowerPC numbering (bit 0 is
// the most significant), wrapping around when mb > me.
function automatic logic [31:0] mask_gen(input logic [4:0] mb, input logic [4:0] me);
	logic [31:0] m1;
	logic [31:0] m2;
	begin
		m1 = 32'hFFFFFFFF >> mb;
		m2 = 32'hFFFFFFFF << (5'd31 - me);
		mask_gen = (mb <= me) ? (m1 & m2) : (m1 | m2);
	end
endfunction

logic [5:0]  sh_n;       // shift count; bit 5 means "32 or more" for shifts
logic [4:0]  rot_amt;
logic [63:0] rot_dbl;
logic [31:0] rot;
logic [31:0] mask;
logic [31:0] rot_res;
logic        rot_ca;

always_comb begin
	sh_n = ctl.sh_reg ? b[5:0] : {1'b0, ctl.sh};

	case (ctl.rot_op)
		ROT_SRW, ROT_SRAW: rot_amt = 5'd0 - sh_n[4:0];   // right by n = left by 32-n
		default:           rot_amt = sh_n[4:0];
	endcase
	rot_dbl = {a, a} << rot_amt;
	rot     = rot_dbl[63:32];

	case (ctl.rot_op)
		ROT_SLW:           mask = sh_n[5] ? 32'd0 : mask_gen(5'd0, 5'd31 - sh_n[4:0]);
		ROT_SRW, ROT_SRAW: mask = sh_n[5] ? 32'd0 : mask_gen(sh_n[4:0], 5'd31);
		default:           mask = mask_gen(ctl.mb, ctl.me);
	endcase

	case (ctl.rot_op)
		ROT_RLWIMI: rot_res = (rot & mask) | (b & ~mask);
		ROT_SRAW:   rot_res = (rot & mask) | ({32{a[31]}} & ~mask);
		default:    rot_res = rot & mask;
	endcase

	// sraw, srawi: carry when a negative value loses any one bits
	rot_ca = a[31] & (|(rot & ~mask));
end

// ---- count leading zeros ---------------------------------------------------
function automatic logic [5:0] clz32(input logic [31:0] v);
	begin
		clz32 = 6'd32;
		for (int i = 0; i < 32; i++)
			if (v[i]) clz32 = 6'd31 - i[5:0];
	end
endfunction

// ---- result ----------------------------------------------------------------
always_comb begin
	ca_out = add_sum[32];
	ov_out = add_ov;
	case (ctl.alu_op)
		ALU_LOGIC: result = log_res;
		ALU_ROT:   begin result = rot_res; ca_out = rot_ca; end
		ALU_CNTLZ: result = {26'd0, clz32(a)};
		ALU_EXTS:  result = ctl.ext_byte ? {{24{a[7]}}, a[7:0]} : {{16{a[15]}}, a[15:0]};
		default:   result = add_sum[31:0];
	endcase
end

endmodule

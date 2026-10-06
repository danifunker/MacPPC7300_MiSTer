//============================================================================
//
//  DSPPC604 - PowerPC 604-class CPU core
//  Floating-point unit
//
//  Holds no architectural state: operand values and FPSCR in, result and the
//  new FPSCR out. verilator/fpmodel.py is the executable specification this
//  module follows; both are checked against results from a real 604.
//
//  Handshake (same as the integer unit)
//    The requester holds req_valid, ctl, the operands and fpscr_in steady
//    until the response is taken. resp_valid stays high, with the results,
//    until a cycle in which resp_ready is high too.
//
//    fmr fneg fabs fnabs fsel fcmpu fcmpo   same cycle (combinational)
//    everything else                        several cycles, see the stages
//
//    result_we is low when an enabled invalid-operation or zero-divide
//    exception keeps the target register unchanged. fex is the new
//    FPSCR[FEX]; the requester decides with MSR[FE0,FE1] whether to trap.
//
//  One datapath serves every arithmetic instruction:
//
//    x * y + z   fadd (y = 1), fmul (z absent), fmadd..., frsp and fctiw
//                (product absent, z = operand)
//    x / z       fdiv, fres (x = 1); two quotient bits per cycle
//
//  followed by a shared normalise - shift - round - pack back end.
//
//  Non-IEEE mode (FPSCR[NI]) does what a 604 does: a result that would be
//  denormalised is delivered as a signed zero and reported as an inexact
//  underflow; denormal operands are computed with as in IEEE mode.
//
//============================================================================

module DSPPC604_fpu
(
	input  logic        clk,
	input  logic        reset,
	input  logic        flush,

	input  logic        req_valid,
	output logic        req_ready,
	input  DSPPC604_pkg::fpu_ctl_t ctl,
	input  logic [63:0] a,           // frA
	input  logic [63:0] b,           // frB
	input  logic [63:0] c,           // frC
	input  logic [31:0] fpscr_in,

	output logic        resp_valid,
	input  logic        resp_ready,
	output logic [63:0] result,
	output logic        result_we,
	output logic [31:0] fpscr_out,
	output logic [3:0]  cr_out,      // CR1 for Rc forms, the compare result for fcmp
	output logic        fex
);

import DSPPC604_pkg::*;

// FPSCR bit numbers (bit 31 is FX, the architecture's bit 0)
localparam int B_OX = 28, B_UX = 27, B_ZX = 26, B_XX = 25;
localparam int B_VXSNAN = 24, B_VXISI = 23, B_VXIDI = 22, B_VXZDZ = 21;
localparam int B_VXIMZ = 20, B_VXVC = 19, B_VXSQRT = 9, B_VXCVI = 8;
localparam int B_VE = 7, B_OE = 6, B_UE = 5, B_ZE = 4;

localparam logic [31:0] VX_ALL = 32'h01F80700;   // every invalid-operation cause
localparam logic [31:0] STICKY = 32'h1FF80700;   // every exception bit that sets FX

localparam logic [63:0] QNAN = 64'h7FF8000000000000;

// ---- FPSCR helpers ---------------------------------------------------------
function automatic logic [31:0] fpscr_update(
	input logic [31:0] old,
	input logic [31:0] set_bits,
	input logic        frfi_we,
	input logic        fr,
	input logic        fi,
	input logic        fprf_we,
	input logic [4:0]  fprf
);
	logic [31:0] n;
	begin
		n = old;
		if (frfi_we) begin
			n[18] = fr;
			n[17] = fi;
		end
		if (fprf_we) n[16:12] = fprf;
		if (|(set_bits & ~old & STICKY)) n[31] = 1'b1;
		n = n | set_bits;
		n[29] = |(n & VX_ALL);
		n[30] = (n[29] & n[B_VE]) | (n[B_OX] & n[B_OE]) | (n[B_UX] & n[B_UE]) |
		        (n[B_ZX] & n[B_ZE]) | (n[B_XX] & n[3]);
		fpscr_update = n;
	end
endfunction

// result class, as FPSCR[FPRF]. A single-precision denormal is held as a
// normalised double, so the rounding stage says whether the result was
// denormalised (den_in); one that an enabled underflow scaled into range is a
// normal number whatever its exponent, as a 604 reports it.
function automatic logic [4:0] fprf_of(input logic [63:0] x, input logic den_in);
	logic s, emax, ezero, fzero, den;
	begin
		s     = x[63];
		emax  = (x[62:52] == 11'h7FF);
		ezero = (x[62:52] == 11'd0);
		fzero = (x[51:0] == 52'd0);
		den   = ezero | den_in;
		if (emax & ~fzero)      fprf_of = 5'b10001;
		else if (emax)          fprf_of = s ? 5'b01001 : 5'b00101;
		else if (ezero & fzero) fprf_of = s ? 5'b10010 : 5'b00010;
		else if (den)           fprf_of = s ? 5'b11000 : 5'b10100;
		else                    fprf_of = s ? 5'b01000 : 5'b00100;
	end
endfunction

// ---- operand classes -------------------------------------------------------
wire        a_s = a[63];
wire        b_s = b[63];
wire        c_s = c[63];
wire        a_ez = (a[62:52] == 11'd0), a_ef = (a[62:52] == 11'h7FF), a_fz = (a[51:0] == 52'd0);
wire        b_ez = (b[62:52] == 11'd0), b_ef = (b[62:52] == 11'h7FF), b_fz = (b[51:0] == 52'd0);
wire        c_ez = (c[62:52] == 11'd0), c_ef = (c[62:52] == 11'h7FF), c_fz = (c[51:0] == 52'd0);
wire        a_zero = a_ez & a_fz, a_den = a_ez & ~a_fz, a_inf = a_ef & a_fz, a_nan = a_ef & ~a_fz;
wire        b_zero = b_ez & b_fz, b_den = b_ez & ~b_fz, b_inf = b_ef & b_fz, b_nan = b_ef & ~b_fz;
wire        c_zero = c_ez & c_fz, c_den = c_ez & ~c_fz, c_inf = c_ef & c_fz, c_nan = c_ef & ~c_fz;
wire        a_snan = a_nan & ~a[51];
wire        b_snan = b_nan & ~b[51];
wire        c_snan = c_nan & ~c[51];

// magnitude m * 2**e for a finite operand; a denormal has exponent field 1
wire [52:0] a_m = {~a_ez, a[51:0]};
wire [52:0] b_m = {~b_ez, b[51:0]};
wire [52:0] c_m = {~c_ez, c[51:0]};
wire signed [13:0] a_e = $signed({3'b000, a_ez ? 11'd1 : a[62:52]}) - 14'sd1075;
wire signed [13:0] b_e = $signed({3'b000, b_ez ? 11'd1 : b[62:52]}) - 14'sd1075;
wire signed [13:0] c_e = $signed({3'b000, c_ez ? 11'd1 : c[62:52]}) - 14'sd1075;

// ---- what the instruction is ----------------------------------------------
logic op_simple;    // answered in the request cycle
logic op_fma;       // fmadd family
logic op_div;       // fdiv, fres
logic op_rsq;
logic op_int;       // fctiw, fctiwz
logic op_sub;       // the frB operand is subtracted
logic op_neg;       // the result is negated
logic use_a, use_b, use_c;

always_comb begin
	op_simple = 0; op_fma = 0; op_div = 0; op_rsq = 0; op_int = 0;
	op_sub = 0; op_neg = 0; use_a = 0; use_b = 0; use_c = 0;
	case (ctl.op)
		FPU_ADD:    begin use_a = 1; use_b = 1; end
		FPU_SUB:    begin use_a = 1; use_b = 1; op_sub = 1; end
		FPU_MUL:    begin use_a = 1; use_c = 1; end
		FPU_DIV:    begin use_a = 1; use_b = 1; op_div = 1; end
		FPU_MADD:   begin use_a = 1; use_b = 1; use_c = 1; op_fma = 1; end
		FPU_MSUB:   begin use_a = 1; use_b = 1; use_c = 1; op_fma = 1; op_sub = 1; end
		FPU_NMADD:  begin use_a = 1; use_b = 1; use_c = 1; op_fma = 1; op_neg = 1; end
		FPU_NMSUB:  begin use_a = 1; use_b = 1; use_c = 1; op_fma = 1; op_sub = 1; op_neg = 1; end
		FPU_RSP:    begin use_b = 1; end
		FPU_CTIW,
		FPU_CTIWZ:  begin use_b = 1; op_int = 1; end
		FPU_RES:    begin use_b = 1; op_div = 1; end
		FPU_RSQRTE: begin use_b = 1; op_rsq = 1; end
		default:    op_simple = 1;   // moves, fsel, compares
	endcase
end

// rounded to single precision: opcode 59, and frsp
wire op_sgl = ctl.single | (ctl.op == FPU_RSP);

// ---- moves, select and compare: combinational ------------------------------
logic [63:0] simple_result;
logic [31:0] simple_fpscr;
logic [3:0]  simple_cr;

wire cmp_un = a_nan | b_nan;
wire cmp_bz = a_zero & b_zero;
wire cmp_lt = ~cmp_un & ~cmp_bz & ((a_s & ~b_s) |
              (~a_s & ~b_s & (a[62:0] < b[62:0])) | (a_s & b_s & (a[62:0] > b[62:0])));
wire cmp_eq = ~cmp_un & (cmp_bz | (a == b));
wire cmp_gt = ~cmp_un & ~cmp_lt & ~cmp_eq;
wire [3:0] cmp_cc = {cmp_lt, cmp_gt, cmp_eq, cmp_un};

always_comb begin : simple_ops
	logic [31:0] set_bits;
	logic        cmp_snan;

	set_bits = 32'd0;
	cmp_snan = a_snan | b_snan;

	simple_result = b;
	simple_fpscr  = fpscr_in;
	simple_cr     = fpscr_in[31:28];

	case (ctl.op)
		FPU_NEG:  simple_result = {~b[63], b[62:0]};
		FPU_ABS:  simple_result = {1'b0, b[62:0]};
		FPU_NABS: simple_result = {1'b1, b[62:0]};
		FPU_SEL:  simple_result = (~a_nan & (a_zero | ~a_s)) ? c : b;
		FPU_CMPU, FPU_CMPO: begin
			set_bits[B_VXSNAN] = cmp_snan;
			if (ctl.op == FPU_CMPO)
				set_bits[B_VXVC] = cmp_snan ? ~fpscr_in[B_VE] : cmp_un;
			simple_fpscr = fpscr_update(fpscr_in, set_bits, 1'b0, 1'b0, 1'b0,
			                            1'b1, {fpscr_in[16], cmp_cc});
			simple_cr = cmp_cc;
		end
		default: ;
	endcase
end

// ---- results that need no arithmetic ---------------------------------------
// NaN operands, infinities, zeros and the invalid operations.
logic        sp_valid;
logic [63:0] sp_result;
logic [31:0] sp_set;        // exception bits
logic        sp_fprf_we;

wire        sb_eff  = b_s ^ op_sub;           // sign frB contributes with
wire        s_prod  = a_s ^ c_s;
wire        rn_down = (fpscr_in[1:0] == 2'b11);
wire        imz     = (a_inf & c_zero) | (a_zero & c_inf);
wire        nan_any  = (use_a & a_nan)  | (use_b & b_nan)  | (use_c & c_nan);
wire        snan_any = (use_a & a_snan) | (use_b & b_snan) | (use_c & c_snan);

// the NaN operand that propagates: frA first, then frB, then frC; made
// quiet, and for single precision without the bits a single cannot hold
wire [63:0] nan_pick = (use_a & a_nan) ? a : (use_b & b_nan) ? b : c;
wire [63:0] nan_res  = {nan_pick[63:52], 1'b1, nan_pick[50:29], op_sgl ? 29'd0 : nan_pick[28:0]};

always_comb begin : special_results
	logic is_nan;   // the special result is a NaN (never negated)

	sp_valid   = 1'b0;
	sp_result  = 64'd0;
	sp_set     = 32'd0;
	sp_fprf_we = 1'b1;
	is_nan     = 1'b0;

	case (ctl.op)
	FPU_ADD, FPU_SUB: begin
		if (nan_any) begin
			sp_valid = 1; sp_result = nan_res; is_nan = 1;
		end
		else if (a_inf & b_inf) begin
			sp_valid = 1;
			if (a_s != sb_eff) begin sp_set[B_VXISI] = 1; sp_result = QNAN; is_nan = 1; end
			else sp_result = {a_s, 11'h7FF, 52'd0};
		end
		else if (a_inf) begin sp_valid = 1; sp_result = {a_s, 11'h7FF, 52'd0}; end
		else if (b_inf) begin sp_valid = 1; sp_result = {sb_eff, 11'h7FF, 52'd0}; end
		else if (a_zero & b_zero) begin
			sp_valid = 1; sp_result = {(a_s == sb_eff) ? a_s : rn_down, 63'd0};
		end
	end

	FPU_MUL: begin
		if (nan_any) begin
			sp_valid = 1; sp_result = nan_res; is_nan = 1;
		end
		else if (imz) begin
			sp_valid = 1; sp_set[B_VXIMZ] = 1; sp_result = QNAN; is_nan = 1;
		end
		else if (a_inf | c_inf) begin sp_valid = 1; sp_result = {s_prod, 11'h7FF, 52'd0}; end
		else if (a_zero | c_zero) begin sp_valid = 1; sp_result = {s_prod, 63'd0}; end
	end

	FPU_MADD, FPU_MSUB, FPU_NMADD, FPU_NMSUB: begin
		// infinity times zero is flagged even beside a NaN operand
		if (imz) sp_set[B_VXIMZ] = 1;
		if (nan_any) begin
			sp_valid = 1; sp_result = nan_res; is_nan = 1;
		end
		else if (imz) begin
			sp_valid = 1; sp_result = QNAN; is_nan = 1;
		end
		else if (a_inf | c_inf) begin
			sp_valid = 1;
			if (b_inf & (sb_eff != s_prod)) begin sp_set[B_VXISI] = 1; sp_result = QNAN; is_nan = 1; end
			else sp_result = {s_prod, 11'h7FF, 52'd0};
		end
		else if (b_inf) begin sp_valid = 1; sp_result = {sb_eff, 11'h7FF, 52'd0}; end
		else if ((a_zero | c_zero) & b_zero) begin
			sp_valid = 1; sp_result = {(s_prod == sb_eff) ? s_prod : rn_down, 63'd0};
		end
	end

	FPU_DIV: begin
		if (nan_any) begin
			sp_valid = 1; sp_result = nan_res; is_nan = 1;
		end
		else if (a_inf & b_inf) begin
			sp_valid = 1; sp_set[B_VXIDI] = 1; sp_result = QNAN; is_nan = 1;
		end
		else if (a_zero & b_zero) begin
			sp_valid = 1; sp_set[B_VXZDZ] = 1; sp_result = QNAN; is_nan = 1;
		end
		else if (a_inf) begin sp_valid = 1; sp_result = {a_s ^ b_s, 11'h7FF, 52'd0}; end
		else if (b_inf) begin sp_valid = 1; sp_result = {a_s ^ b_s, 63'd0}; end
		else if (b_zero) begin
			sp_valid = 1; sp_set[B_ZX] = 1; sp_result = {a_s ^ b_s, 11'h7FF, 52'd0};
		end
		else if (a_zero) begin sp_valid = 1; sp_result = {a_s ^ b_s, 63'd0}; end
	end

	FPU_RES: begin
		if (nan_any) begin
			sp_valid = 1; sp_result = nan_res; is_nan = 1;
		end
		else if (b_inf) begin sp_valid = 1; sp_result = {b_s, 63'd0}; end
		else if (b_zero) begin
			sp_valid = 1; sp_set[B_ZX] = 1; sp_result = {b_s, 11'h7FF, 52'd0};
		end
	end

	FPU_RSP: begin
		if (nan_any) begin
			sp_valid = 1; sp_result = nan_res; is_nan = 1;
		end
		else if (b_inf | b_zero) begin sp_valid = 1; sp_result = b; end
	end

	FPU_CTIW, FPU_CTIWZ: begin
		// The upper word of the result is undefined; the 604 writes FFF80000,
		// with the lowest bit set when a negative operand converts to zero.
		sp_fprf_we = 1'b0;
		if (nan_any) begin
			sp_valid = 1; sp_set[B_VXCVI] = 1; sp_result = 64'hFFF8000080000000;
		end
		else if (b_inf) begin
			sp_valid = 1; sp_set[B_VXCVI] = 1;
			sp_result = b_s ? 64'hFFF8000080000000 : 64'hFFF800007FFFFFFF;
		end
		else if (b_zero) begin
			sp_valid = 1; sp_result = {31'h7FFC0000, b_s, 32'd0};
		end
	end

	FPU_RSQRTE: begin
		if (nan_any) begin
			sp_valid = 1; sp_result = nan_res; is_nan = 1;
		end
		else if (b_zero) begin
			sp_valid = 1; sp_set[B_ZX] = 1; sp_result = {b_s, 11'h7FF, 52'd0};
		end
		else if (b_s) begin
			sp_valid = 1; sp_set[B_VXSQRT] = 1; sp_result = QNAN; is_nan = 1;
		end
		else if (b_inf) begin sp_valid = 1; sp_result = 64'd0; end
	end

	default: ;
	endcase

	if (snan_any) sp_set[B_VXSNAN] = 1'b1;
	if (op_neg & sp_valid & ~is_nan) sp_result[63] = ~sp_result[63];
end

// ---- state -----------------------------------------------------------------
typedef enum logic [3:0] {
	S_IDLE,
	S_PREA,     // normalise denormal operands, two cycles each
	S_PREB,
	S_PREC,
	S_MUL1,     // partial products; alignment distance
	S_MUL2,     // product; aligned addend
	S_ADD,      // magnitude of product +/- addend
	S_LZC,      // leading zeros
	S_NORM,     // normalise; where to round
	S_SHIFT,    // bring the rounding point to bit 0
	S_ROUND,    // round, range checks, pack
	S_DIV0,     // divide set-up
	S_DIV,      // two quotient bits per cycle
	S_RSQ,      // reciprocal square root estimate
	S_DONE      // results presented
} state_t;

state_t state;

// request, as latched
logic        sgl_q;        // round to single precision
logic        int_q;        // convert to integer
logic        div_q;
logic        rsq_q;
logic        neg_q;
logic        rc_q;
logic [1:0]  rn_q;         // rounding mode in effect
logic [31:0] fpscr_q;

// x * y + z, or x / z
logic [52:0] mx, my, mz;
logic signed [13:0] ex, ey, ez;
logic        s_p;          // sign of the product or quotient
logic        s_z;          // sign the addend contributes with
logic        p_zero;       // no product
logic        z_zero;       // no addend

// what S_DONE presents
logic [63:0] fin_result;
logic [31:0] fin_set;
logic        fin_fr;
logic        fin_fi;
logic        fin_fprf_we;
logic        fin_den;      // the result was denormalised in its own format

wire ue = fpscr_q[B_UE];
wire oe = fpscr_q[B_OE];

// ---- operand normaliser (denormal inputs only) -----------------------------
logic [52:0] pre_in;
logic [5:0]  pre_lz;

always_comb begin
	case (state)
		S_PREA:  pre_in = mx;
		S_PREB:  pre_in = mz;
		default: pre_in = my;
	endcase
end

DSPPC604_lzc #(.WIDTH(53)) pre_lzc
(
	.in    (pre_in),
	.count (pre_lz)
);

// count in one cycle, shift in the next: denormals are rare and this path
// would otherwise set the clock
logic        pre_phase;
logic [5:0]  pre_lz_q;

wire [52:0]        pre_out = pre_in << pre_lz_q;
wire signed [13:0] pre_adj = $signed({8'd0, pre_lz_q});

// ---- multiply --------------------------------------------------------------
// 53 x 53 as four products of at most 27 x 27, one DSP block each.
logic [53:0]  pp_ll;
logic [52:0]  pp_lh;
logic [52:0]  pp_hl;
logic [51:0]  pp_hh;
logic [105:0] p_q;

wire [53:0]  pp_mid = {1'b0, pp_lh} + {1'b0, pp_hl};
wire [105:0] p_sum  = {pp_hh, 54'd0} + {25'd0, pp_mid, 27'd0} + {52'd0, pp_ll};

// ---- align the addend ------------------------------------------------------
// The sum is formed in a 162-bit window. The product sits in bits 105..0. The
// addend starts with its last place at bit 108 and moves right by the
// distance between the exponents; what leaves the bottom becomes sticky. If
// the addend is larger than that, it stays at the top and the window follows
// it: the product is then entirely below the rounding point.
logic signed [13:0] e_win;      // weight of window bit 0
logic [7:0]         sr;
logic [160:0]       zal;
logic               zst;

wire signed [13:0] e_prod = ex + ey;
wire signed [13:0] e_dist = e_prod - ez + 14'sd108;
wire               pin_z  = p_zero | (~z_zero & e_dist[13]);

function automatic logic [161:0] align_z(input logic [52:0] m, input logic [7:0] amount);
	logic [160:0] v;
	logic         s;
	begin
		v = {m, 108'd0};
		s = 1'b0;
		for (int i = 0; i < 8; i++) begin
			if (amount[i]) begin
				s = s | (|(v & ((161'd1 << (1 << i)) - 161'd1)));
				v = v >> (1 << i);
			end
		end
		align_z = {v, s};
	end
endfunction

// ---- add -------------------------------------------------------------------
logic [161:0] r_q;         // magnitude of the sum, or the quotient
logic         r_sign;
logic         r_sticky;

wire [162:0] add_p   = {57'd0, p_q};
wire [162:0] add_z   = {2'd0, zal};
wire [162:0] add_sum = add_p + add_z;
wire [162:0] add_pz  = add_p - add_z - {162'd0, zst};   // negative: addend is larger
wire [162:0] add_zp  = add_z - add_p;
wire         eff_sub = s_p ^ s_z;

// ---- normalise -------------------------------------------------------------
logic [7:0]  lz_cnt;
logic [7:0]  lz_q;
logic        rzero_q;      // exactly zero

DSPPC604_lzc #(.WIDTH(162)) r_lzc
(
	.in    (r_q),
	.count (lz_cnt)
);

wire [161:0] norm = r_q << lz_q;

// exponent of the leading one, and where rounding happens
wire signed [13:0] top     = e_win + 14'sd161 - $signed({6'd0, lz_q});
wire signed [13:0] emin    = sgl_q ? -14'sd126 : -14'sd1022;
wire               tiny    = (top < emin);
wire signed [13:0] under   = emin - top;                        // how far below
wire signed [13:0] int_pos = 14'sd63 - top;

logic [63:0]        w_q;       // normalised, leading one at bit 63
logic               w_sticky;
logic signed [13:0] top_q;
logic               tiny_q;    // below the normal range before rounding
logic               den_q;     // delivered denormalised
logic [6:0]         l_q;       // bits dropped below the rounding point
logic [4:0]         tc_q;      // single precision: places denormalised, 24 at most

// ---- shift so the last kept bit is bit 0 -----------------------------------
wire [128:0] sh_x = {w_q, 65'd0} >> l_q;

logic [63:0] k_q;          // kept bits
logic        rb_q;         // first dropped bit
logic        sk_q;         // any later bit

// ---- divide ----------------------------------------------------------------
// Restoring, radix 4. The operands are normalised, so the first quotient bit
// is 0 or 1; every cycle after that produces two more.
logic [52:0] d_rem;
logic [54:0] d_three;      // 3 * divisor
logic [56:0] d_quo;
logic [4:0]  d_cnt;

wire [55:0] d_r4 = {1'b0, d_rem, 2'b00};
wire [55:0] d_t1 = d_r4 - {3'd0, mz};
wire [55:0] d_t2 = d_r4 - {2'd0, mz, 1'b0};
wire [55:0] d_t3 = d_r4 - {1'b0, d_three};

logic [1:0]  d_digit;
logic [52:0] d_next;

always_comb begin
	if (~d_t3[55])      begin d_digit = 2'd3; d_next = d_t3[52:0]; end
	else if (~d_t2[55]) begin d_digit = 2'd2; d_next = d_t2[52:0]; end
	else if (~d_t1[55]) begin d_digit = 2'd1; d_next = d_t1[52:0]; end
	else                begin d_digit = 2'd0; d_next = d_r4[52:0]; end
end

wire [56:0] d_quo_next = {d_quo[54:0], d_digit};

// ---- reciprocal square root estimate ---------------------------------------
// Seven fraction bits, by the low bit of the exponent and the top four
// fraction bits: 1/sqrt at the middle of each interval, rounded to nearest.
// Eight entries are confirmed by a real 604; see fpmodel.py.
function automatic logic [6:0] rsqrte_table(input logic [4:0] index);
	begin
		case (index)
			5'd0:  rsqrte_table = 7'h7C;  5'd1:  rsqrte_table = 7'h75;
			5'd2:  rsqrte_table = 7'h6E;  5'd3:  rsqrte_table = 7'h68;
			5'd4:  rsqrte_table = 7'h62;  5'd5:  rsqrte_table = 7'h5D;
			5'd6:  rsqrte_table = 7'h58;  5'd7:  rsqrte_table = 7'h53;
			5'd8:  rsqrte_table = 7'h4F;  5'd9:  rsqrte_table = 7'h4B;
			5'd10: rsqrte_table = 7'h47;  5'd11: rsqrte_table = 7'h43;
			5'd12: rsqrte_table = 7'h40;  5'd13: rsqrte_table = 7'h3D;
			5'd14: rsqrte_table = 7'h39;  5'd15: rsqrte_table = 7'h36;
			5'd16: rsqrte_table = 7'h32;  5'd17: rsqrte_table = 7'h2D;
			5'd18: rsqrte_table = 7'h28;  5'd19: rsqrte_table = 7'h24;
			5'd20: rsqrte_table = 7'h20;  5'd21: rsqrte_table = 7'h1C;
			5'd22: rsqrte_table = 7'h19;  5'd23: rsqrte_table = 7'h15;
			5'd24: rsqrte_table = 7'h12;  5'd25: rsqrte_table = 7'h0F;
			5'd26: rsqrte_table = 7'h0D;  5'd27: rsqrte_table = 7'h0A;
			5'd28: rsqrte_table = 7'h08;  5'd29: rsqrte_table = 7'h05;
			5'd30: rsqrte_table = 7'h03;  default: rsqrte_table = 7'h01;
		endcase
	end
endfunction

wire signed [13:0] rsq_top  = ez + 14'sd52;                   // operand is 1.f * 2**rsq_top
wire signed [13:0] rsq_half = rsq_top >>> 1;
wire signed [13:0] rsq_exp  = -rsq_half - 14'sd1;             // odd and even alike
wire [10:0]        rsq_bexp = rsq_exp[10:0] + 11'd1023;

// ---- round and pack --------------------------------------------------------
logic [63:0] rnd_result;
logic [31:0] rnd_set;
logic        rnd_fr;
logic        rnd_fi;
logic        rnd_den;

// non-IEEE mode: a result that would be denormalised becomes a signed zero
wire ni_flush = den_q & fpscr_q[2] & ~rzero_q;

always_comb begin : round_pack
	logic        sign;
	logic        inexact;
	logic        up;
	logic [64:0] kr;
	logic        to_inf;
	logic        ovf;
	logic        carry;
	logic signed [13:0] e_res;
	logic signed [13:0] b14;      // biased exponent, in the wider internal range
	logic [10:0] bexp;
	logic [51:0] frac;
	logic [24:0] snorm;
	logic        is_zero;
	logic [31:0] ival;
	logic        iovf;

	sign    = r_sign;
	inexact = rb_q | sk_q;
	case (rn_q)
		2'b00:   up = rb_q & (sk_q | k_q[0]);
		2'b01:   up = 1'b0;
		2'b10:   up = inexact & ~sign;
		default: up = inexact & sign;
	endcase
	kr = {1'b0, k_q} + {64'd0, up};

	to_inf = (rn_q == 2'b00) | ((rn_q == 2'b10) & ~sign) | ((rn_q == 2'b11) & sign);

	rnd_set = 32'd0;
	rnd_fr  = up;
	rnd_fi  = inexact;
	rnd_den = 1'b0;
	ovf     = 1'b0;
	carry   = 1'b0;
	e_res   = top_q;
	b14     = 14'sd0;
	bexp    = 11'd0;
	frac    = 52'd0;
	snorm   = 25'd0;
	is_zero = 1'b0;
	ival    = 32'd0;
	iovf    = 1'b0;

	if (int_q) begin
		// magnitude above 2**31 - 1, or above 2**31 for a negative value
		iovf = sign ? ((|kr[64:32]) | (kr[31] & (|kr[30:0]))) : (|kr[64:31]);
		if (iovf)      ival = sign ? 32'h80000000 : 32'h7FFFFFFF;
		else if (sign) ival = 32'd0 - kr[31:0];
		else           ival = kr[31:0];
		rnd_result = {31'h7FFC0000, sign & (ival == 32'd0), ival};
		rnd_set[B_VXCVI] = iovf;
		rnd_fr = up & ~iovf;
		rnd_fi = inexact & ~iovf;
		rnd_set[B_XX] = rnd_fi;
	end
	else begin
		// The exponent field, from the biased exponent in the wider internal
		// range: bits 9-0 as they are and bit 10 as bit 11 XOR bit 10. The
		// identity for every exponent in range; outside it (an enabled
		// underflow or overflow in single precision whose adjusted exponent
		// still does not fit a double) it is what a 604 delivers (measured).
		if (sgl_q) begin
			// A single-precision denormal is delivered as a normalised
			// double: shift the rounded bits back up to find it.
			snorm   = kr[24:0] << (den_q ? tc_q : 5'd0);
			carry   = snorm[24];
			e_res   = (den_q ? (-14'sd126 - $signed({9'd0, tc_q})) : top_q) + $signed({13'd0, carry});
			frac    = {carry ? 23'd0 : snorm[22:0], 29'd0};
			is_zero = (kr[24:0] == 25'd0);
			ovf     = ~den_q & (e_res > 14'sd127);
			if (ovf & oe) e_res = e_res - 14'sd192;
			b14     = e_res + 14'sd1023;
			bexp    = {b14[11] ^ b14[10], b14[9:0]};
			rnd_den = den_q & (e_res < -14'sd126);    // (rounding can carry into the smallest normal)
		end
		else if (den_q) begin
			// double-precision denormal: held as it is
			frac    = kr[51:0];
			bexp    = {10'd0, kr[52]};
			is_zero = (kr[52:0] == 53'd0);
			rnd_den = ~kr[52];
		end
		else begin
			carry   = kr[53];
			e_res   = top_q + $signed({13'd0, carry});
			frac    = carry ? 52'd0 : kr[51:0];
			ovf     = (e_res > 14'sd1023);
			if (ovf & oe) e_res = e_res - 14'sd1536;
			b14     = e_res + 14'sd1023;
			bexp    = {b14[11] ^ b14[10], b14[9:0]};
		end

		if (rzero_q)
			// an exact zero sum: positive, except when rounding down
			rnd_result = {(fpscr_q[1:0] == 2'b11) ^ neg_q, 63'd0};
		else if (is_zero | ni_flush)
			rnd_result = {sign ^ neg_q, 63'd0};
		else if (ovf & ~oe) begin
			if (to_inf)     rnd_result = {sign ^ neg_q, 11'h7FF, 52'd0};
			else if (sgl_q) rnd_result = {sign ^ neg_q, 63'h47EFFFFFE0000000};
			else            rnd_result = {sign ^ neg_q, 63'h7FEFFFFFFFFFFFFF};
		end
		else
			rnd_result = {sign ^ neg_q, bexp, frac};

		// A disabled overflow is always inexact. FR is left as the rounding
		// of the significand set it, which is what the 604 does. A result
		// flushed in non-IEEE mode is an inexact underflow, exact or not.
		rnd_fi = inexact | (ovf & ~oe) | ni_flush;
		rnd_set[B_OX] = ovf;
		rnd_set[B_XX] = rnd_fi;
		rnd_set[B_UX] = tiny_q & (ue | inexact | ni_flush);

		if (ni_flush) begin
			rnd_fr  = 1'b0;
			rnd_den = 1'b0;
		end
		if (rzero_q) begin
			rnd_set = 32'd0;
			rnd_fr  = 1'b0;
			rnd_fi  = 1'b0;
			rnd_den = 1'b0;
		end
	end
end

// ---- sequencing ------------------------------------------------------------
wire start    = req_valid & (state == S_IDLE) & ~op_simple;
wire need_pre = (use_a & a_den) | (use_b & b_den) | (use_c & c_den);

always_ff @(posedge clk) begin
	case (state)
	S_IDLE: begin
		if (start) begin
			sgl_q   <= op_sgl;
			int_q   <= op_int;
			div_q   <= op_div;
			rsq_q   <= op_rsq;
			neg_q   <= op_neg;
			rc_q    <= ctl.rc;
			rn_q    <= (ctl.op == FPU_CTIWZ) ? 2'b01 : fpscr_in[1:0];
			fpscr_q <= fpscr_in;

			// x * y + z
			mx <= a_m;  ex <= a_e;
			my <= c_m;  ey <= c_e;
			mz <= b_m;  ez <= b_e;
			s_p    <= s_prod;
			s_z    <= sb_eff;
			p_zero <= a_zero | c_zero;
			z_zero <= b_zero;

			case (ctl.op)
			FPU_ADD, FPU_SUB: begin        // a * 1 + b
				my <= 53'h10000000000000;  ey <= -14'sd52;
				s_p    <= a_s;
				p_zero <= a_zero;
			end
			FPU_MUL: begin                 // a * c, no addend
				mz     <= 53'd0;
				s_z    <= s_prod;
				z_zero <= 1'b1;
			end
			FPU_DIV: begin                 // a / b
				s_p <= a_s ^ b_s;
			end
			FPU_RES: begin                 // 1 / b
				mx  <= 53'h10000000000000;  ex <= -14'sd52;
				s_p <= b_s;
			end
			FPU_RSP, FPU_CTIW, FPU_CTIWZ: begin   // b alone
				mx     <= 53'd0;
				s_p    <= b_s;
				s_z    <= b_s;
				p_zero <= 1'b1;
			end
			default: ;
			endcase

			if (sp_valid) begin
				fin_result  <= sp_result;
				fin_set     <= sp_set;
				fin_fr      <= 1'b0;
				fin_fi      <= 1'b0;
				fin_fprf_we <= sp_fprf_we;
				fin_den     <= 1'b0;
				state       <= S_DONE;
			end
			else if (need_pre) state <= S_PREA;
			else if (op_div)   state <= S_DIV0;
			else if (op_rsq)   state <= S_RSQ;
			else               state <= S_MUL1;
		end
	end

	S_PREA: begin
		pre_lz_q  <= pre_lz;
		pre_phase <= ~pre_phase;
		if (pre_phase) begin
			mx <= pre_out;
			ex <= ex - pre_adj;
			state <= S_PREB;
		end
	end

	S_PREB: begin
		pre_lz_q  <= pre_lz;
		pre_phase <= ~pre_phase;
		if (pre_phase) begin
			mz <= pre_out;
			ez <= ez - pre_adj;
			state <= S_PREC;
		end
	end

	S_PREC: begin
		pre_lz_q  <= pre_lz;
		pre_phase <= ~pre_phase;
		if (pre_phase) begin
			my <= pre_out;
			ey <= ey - pre_adj;
			state <= div_q ? S_DIV0 : rsq_q ? S_RSQ : S_MUL1;
		end
	end

	S_MUL1: begin
		pp_ll <= {27'd0, mx[26:0]}  * {27'd0, my[26:0]};
		pp_lh <= {26'd0, mx[26:0]}  * {27'd0, my[52:27]};
		pp_hl <= {27'd0, mx[52:27]} * {26'd0, my[26:0]};
		pp_hh <= {26'd0, mx[52:27]} * {26'd0, my[52:27]};
		e_win <= pin_z ? (ez - 14'sd108) : e_prod;
		sr    <= pin_z ? 8'd0 : (e_dist > 14'sd163) ? 8'd163 : e_dist[7:0];
		state <= S_MUL2;
	end

	S_MUL2: begin
		p_q <= p_sum;
		{zal, zst} <= align_z(mz, sr);
		state <= S_ADD;
	end

	S_ADD: begin
		if (~eff_sub) begin
			r_q    <= add_sum[161:0];
			r_sign <= s_p;
		end
		else if (add_pz[162]) begin
			r_q    <= add_zp[161:0];
			r_sign <= s_z;
		end
		else begin
			r_q    <= add_pz[161:0];
			r_sign <= s_p;
		end
		r_sticky <= zst;
		state    <= S_LZC;
	end

	S_LZC: begin
		lz_q    <= lz_cnt;
		rzero_q <= (r_q == 162'd0) & ~r_sticky;
		state   <= S_NORM;
	end

	S_NORM: begin
		w_q      <= norm[161:98];
		w_sticky <= r_sticky | (|norm[97:0]);
		tiny_q   <= ~int_q & tiny;
		den_q    <= 1'b0;
		top_q    <= top;
		tc_q     <= 5'd0;
		if (int_q) begin
			// integer: the units place goes to bit 0
			l_q <= int_pos[13] ? 7'd0 : (int_pos > 14'sd65) ? 7'd65 : int_pos[6:0];
		end
		else if (tiny & ~ue) begin
			// denormalise: round at the format's smallest place
			den_q <= 1'b1;
			if (sgl_q) l_q <= (under > 14'sd25) ? 7'd65 : (7'd40 + under[6:0]);
			else       l_q <= (under > 14'sd54) ? 7'd65 : (7'd11 + under[6:0]);
			tc_q  <= (under > 14'sd24) ? 5'd24 : under[4:0];
		end
		else begin
			// an enabled underflow delivers the result with a biased exponent
			l_q   <= sgl_q ? 7'd40 : 7'd11;
			if (tiny) top_q <= top + (sgl_q ? 14'sd192 : 14'sd1536);
		end
		state <= S_SHIFT;
	end

	S_SHIFT: begin
		k_q   <= sh_x[128:65];
		rb_q  <= sh_x[64];
		sk_q  <= w_sticky | (|sh_x[63:0]);
		state <= S_ROUND;
	end

	S_ROUND: begin
		fin_result  <= rnd_result;
		fin_set     <= rnd_set;
		fin_fr      <= rnd_fr;
		fin_fi      <= rnd_fi;
		fin_fprf_we <= ~int_q;
		fin_den     <= rnd_den;
		state       <= S_DONE;
	end

	S_DIV0: begin
		// operands are normalised: the quotient is in (1/2, 2)
		if (mx >= mz) begin
			d_rem <= mx - mz;
			d_quo <= 57'd1;
		end
		else begin
			d_rem <= mx;
			d_quo <= 57'd0;
		end
		d_three <= {2'b00, mz} + {1'b0, mz, 1'b0};
		d_cnt   <= sgl_q ? 5'd13 : 5'd27;
		state   <= S_DIV;
	end

	S_DIV: begin
		d_rem <= d_next;
		d_quo <= d_quo_next;
		d_cnt <= d_cnt - 5'd1;
		if (d_cnt == 5'd0) begin
			// the first quotient bit lands on window bit 161
			r_q      <= sgl_q ? {d_quo_next[28:0], 133'd0} : {d_quo_next, 105'd0};
			r_sign   <= s_p;
			r_sticky <= (d_next != 53'd0);
			e_win    <= ex - ez - 14'sd161;
			state    <= S_LZC;
		end
	end

	S_RSQ: begin
		fin_result  <= {1'b0, rsq_bexp, rsqrte_table({rsq_top[0], mz[51:48]}), 45'd0};
		fin_set     <= 32'd0;
		fin_fr      <= 1'b0;
		fin_fi      <= 1'b0;
		fin_fprf_we <= 1'b1;
		fin_den     <= 1'b0;
		state       <= S_DONE;
	end

	default: begin // S_DONE
		if (resp_ready) state <= S_IDLE;
	end
	endcase

	if (state == S_IDLE) pre_phase <= 1'b0;
	if (reset | flush) state <= S_IDLE;
end

assign req_ready = (state == S_IDLE);

// ---- response --------------------------------------------------------------
// An enabled invalid operation or zero divide leaves the target register and
// the result class alone.
wire done_vx       = |(fin_set & VX_ALL);
wire done_suppress = (done_vx & fpscr_q[B_VE]) | (fin_set[B_ZX] & fpscr_q[B_ZE]);
wire [31:0] done_fpscr = fpscr_update(fpscr_q, fin_set, 1'b1,
                                      fin_fr & ~done_suppress, fin_fi & ~done_suppress,
                                      fin_fprf_we & ~done_suppress, fprf_of(fin_result, fin_den));

always_comb begin
	if (state == S_DONE) begin
		resp_valid = req_valid;
		result     = fin_result;
		result_we  = ~done_suppress;
		fpscr_out  = done_fpscr;
		cr_out     = done_fpscr[31:28];
	end
	else begin
		resp_valid = req_valid & (state == S_IDLE) & op_simple;
		result     = simple_result;
		result_we  = 1'b1;
		fpscr_out  = simple_fpscr;
		cr_out     = simple_cr;
	end
	fex = fpscr_out[30];
end

endmodule

//============================================================================
//
//  PPCMac - the machine around the CPU
//  A 68HC05 CPU, for Cuda (PPCMac_cuda)
//
//  The instruction set and flags are MAME's 6805 core with the HC05's tables
//  (src/devices/cpu/m6805: 6805ops.hxx, m6805.cpp s_hc_s_ops, s_hc_cycles),
//  which verilator/hc05ref runs in lockstep with this module. Every
//  instruction takes exactly the bus cycles of s_hc_cycles, so code timed by
//  counting cycles (Cuda's ADB bit cells, its delay loops) runs at the real
//  chip's speed. An interrupt takes 10 cycles, as SWI.
//
//  The address space is 13 bits (the 68HC05E1's 8 KB); the stack pointer is
//  six bits over 00C0-00FF; the condition codes read 111HINZC when pushed.
//
//  One bus cycle per cen, and cen at most every second clock. The cycle's
//  address (and wr, wdata) is presented from the cen that starts it; rdata
//  must hold what the address reads by the cen that ends it (a memory read
//  on every clock with a registered output does). A write happens at the
//  cen that ends the cycle. Reads have no side effects on this chip, so rd
//  marks the cycles that read only for the test bench.
//
//  How an instruction is sequenced: the opcode, its operand bytes, the
//  operand's read, the stack (pushes, pulls, the vector), then idle cycles
//  to the instruction's count; a write to memory is the last cycle, as on
//  the chip. Interrupts are taken between instructions, IRQ before the
//  timer before the one-second interrupt (their vectors' order).
//
//============================================================================

module PPCMac_hc05
(
	input  logic        clk,
	input  logic        reset,
	input  logic        cen,           // one bus cycle
	output logic [12:0] addr,
	output logic        rd,
	output logic        wr,
	output logic [7:0]  wdata,
	input  logic [7:0]  rdata,

	input  logic        irq_n,         // the IRQ pin: BIL/BIH read it, a falling edge interrupts
	input  logic        int_timer,     // the timer's request, a level
	input  logic        int_cpi,       // the one-second interrupt's request, a level

	// for the test bench: one clock after the cen that ends an instruction
	// (or an interrupt's entry), with the registers it left
	output logic        tr_valid,
	output logic        tr_int,        // an interrupt's entry, not an instruction
	output logic [12:0] tr_pc,         // the instruction's address; for an interrupt, the vector's
	output logic [7:0]  tr_op,
	output logic [7:0]  tr_a,
	output logic [7:0]  tr_x,
	output logic [7:0]  tr_sp,
	output logic [7:0]  tr_cc          // 111HINZC
);

// ---- the cycle counts (MAME's s_hc_cycles; its 4 for the opcodes that do not exist) ------
function automatic logic [3:0] cycles(input logic [7:0] op);
	logic [3:0] lo;
	lo = op[3:0];
	case (op[7:4])
		4'h0, 4'h1: cycles = 4'd5;
		4'h2:       cycles = 4'd3;
		4'h3:       cycles = lo == 4'hD ? 4'd4 : 4'd5;
		4'h4:       cycles = lo == 4'h2 ? 4'd11 : 4'd3;
		4'h5:       cycles = 4'd3;
		4'h6:       cycles = lo == 4'hD ? 4'd5 : 4'd6;
		4'h7:       cycles = lo == 4'hD ? 4'd4 : 4'd5;
		4'h8: case (lo)
			4'h0:       cycles = 4'd9;
			4'h1:       cycles = 4'd6;
			4'h3:       cycles = 4'd10;
			4'hE, 4'hF: cycles = 4'd2;
			default:    cycles = 4'd4;
		endcase
		4'h9:       cycles = 4'd2;
		4'hA:       cycles = lo == 4'hD ? 4'd6 : 4'd2;
		default: begin
			// B direct, C extended, D two-byte offset, E one-byte offset, F indexed
			logic [3:0] base;
			case (op[7:4])
				4'hB:    base = 4'd3;
				4'hC:    base = 4'd4;
				4'hD:    base = 4'd5;
				4'hE:    base = 4'd4;
				default: base = 4'd3;
			endcase
			case (lo)
				4'h7, 4'hF: cycles = base + 4'd1;      // STA, STX
				4'hC:       cycles = base - 4'd1;      // JMP
				4'hD:       cycles = base + 4'd2;      // JSR
				default:    cycles = base;
			endcase
		end
	endcase
endfunction

// ---- registers ------------------------------------------------------------------------------
logic [7:0]  a, x;
logic [5:0]  sp;                 // the stack pointer is 00C0 + sp
logic [12:0] pc;
logic        fh, fi, fn, fz, fc;  // H I N Z C
wire  [7:0]  ccr = {3'b111, fh, fi, fn, fz, fc};

typedef enum logic [3:0] {
	S_RST, S_FETCH, S_B1, S_B2, S_RD, S_EXEC, S_PUSH, S_PULL, S_VEC, S_TAIL, S_WAIT
} state_t;

state_t      st;
logic [7:0]  op;                 // the instruction (83, SWI's, for an interrupt's entry)
logic [3:0]  cyc;                // the bus cycle within it
logic [2:0]  seq;                // push, pull and vector steps
logic [12:0] ipc;                // where the instruction started
logic [15:0] ea;                 // the operand's address (wider than the bus for IX2)
logic [7:0]  b1;                 // the first operand byte
logic [7:0]  t;                  // the memory operand (BRSET/BRCLR keep it for the offset)
logic [7:0]  wd;                 // the byte the last cycle writes
logic        do_wr;              // the last cycle writes wd to ea
logic        intr;               // this is an interrupt's entry
logic [12:0] vec;                // the vector it reads
logic        irq_l, irq_q;       // the IRQ pin's falling edge, latched until taken

wire [3:0]  hi   = op[7:4];
wire [3:0]  lo   = op[3:0];
wire [3:0]  ncyc = cycles(op);
wire        last = cyc == ncyc - 4'd1;

// the register the binary and memory forms work on: X for CPX, LDX, STX
wire        use_x = lo == 4'h3 || lo == 4'hE || lo == 4'hF;
wire        is_clr = (hi == 4'h3 || hi == 4'h6 || hi == 4'h7) && lo == 4'hF;

// ---- the arithmetic ----------------------------------------------------------------------
// the read-modify-write group on v (memory, A or X): {N, Z, C, result}; C unchanged where
// the instruction leaves it
function automatic logic [10:0] unary(input logic [3:0] f, input logic [7:0] v, input logic c);
	logic [7:0] r;
	logic       co;
	co = c;
	case (f)
		4'h0:    begin r = 8'h00 - v; co = v != 8'h00; end   // NEG
		4'h3:    begin r = ~v;        co = 1'b1;       end   // COM
		4'h4:    begin r = {1'b0, v[7:1]}; co = v[0];  end   // LSR
		4'h6:    begin r = {c, v[7:1]};    co = v[0];  end   // ROR
		4'h7:    begin r = {v[7], v[7:1]}; co = v[0];  end   // ASR
		4'h8:    begin r = {v[6:0], 1'b0}; co = v[7];  end   // LSL
		4'h9:    begin r = {v[6:0], c};    co = v[7];  end   // ROL
		4'hA:    r = v - 8'h01;                              // DEC
		4'hC:    r = v + 8'h01;                              // INC
		4'hF:    r = 8'h00;                                  // CLR
		default: r = v;                                      // TST
	endcase
	unary = {r[7], r == 8'h00, co, r};
endfunction

// the accumulator group, register g (A, or X for CPX and LDX) and operand m:
// {store, H, N, Z, C, result}
function automatic logic [12:0] binary(input logic [3:0] f, input logic [7:0] g, input logic [7:0] m,
                                       input logic c, input logic h);
	logic [8:0] s;
	logic [7:0] r;
	logic       st_, ho, co;
	st_ = 1'b1; ho = h; co = c; s = 9'h0;
	case (f)
		4'h0, 4'h1, 4'h3: begin s = {1'b0, g} - {1'b0, m};                 r = s[7:0]; co = s[8]; st_ = f == 4'h0; end
		4'h2:             begin s = {1'b0, g} - {1'b0, m} - {8'h00, c};    r = s[7:0]; co = s[8]; end
		4'h4:             r = g & m;
		4'h5:             begin r = g & m; st_ = 1'b0; end
		4'h8:             r = g ^ m;
		4'h9:             begin s = {1'b0, g} + {1'b0, m} + {8'h00, c};    r = s[7:0]; co = s[8]; ho = g[4] ^ m[4] ^ r[4]; end
		4'hA:             r = g | m;
		4'hB:             begin s = {1'b0, g} + {1'b0, m};                 r = s[7:0]; co = s[8]; ho = g[4] ^ m[4] ^ r[4]; end
		default:          r = m;                                           // LDA, LDX
	endcase
	binary = {st_, ho, r[7], r == 8'h00, co, r};
endfunction

// the branch conditions, 20-2F (the odd opcode the opposite of the even one)
function automatic logic branch(input logic [3:0] f, input logic c, input logic z, input logic h,
                                input logic n, input logic i, input logic irq);
	logic b;
	case (f[3:1])
		3'd0:    b = 1'b1;
		3'd1:    b = ~(c | z);
		3'd2:    b = ~c;
		3'd3:    b = ~z;
		3'd4:    b = ~h;
		3'd5:    b = ~n;
		3'd6:    b = ~i;
		default: b = irq;                // BIL: the pin is low
	endcase
	branch = b ^ f[0];
endfunction

// a branch's target while pc is at its offset byte, which rdata holds
wire [12:0] pc_rel = pc + 13'd1 + {{5{rdata[7]}}, rdata};
wire [10:0] un_m   = unary(lo, rdata, fc);
wire [10:0] un_a   = unary(lo, a, fc);
wire [10:0] un_x   = unary(lo, x, fc);
wire [12:0] bi     = binary(lo, use_x ? x : a, rdata, fc, fh);
wire [15:0] mul    = a * x;

// the effective address once the last operand byte is in: rdata is that byte
wire [15:0] ea_dir = {8'h00, rdata};
wire [15:0] ea_ext = {b1, rdata};
wire [15:0] ea_ix2 = {b1, rdata} + {8'h00, x};
wire [15:0] ea_ix1 = {8'h00, rdata} + {8'h00, x};

// what comes after the operand bytes, for the B-F forms: jump, call, store, or read
function automatic state_t after_ea(input logic [3:0] f);
	case (f)
		4'hC:       after_ea = S_TAIL;        // JMP: the pc is set with ea
		4'hD:       after_ea = S_PUSH;        // JSR
		4'h7, 4'hF: after_ea = S_TAIL;        // STA, STX: the write is the last cycle
		default:    after_ea = S_RD;
	endcase
endfunction

// ---- the bus ------------------------------------------------------------------------------
wire [5:0] sp_up = sp + 6'd1;
always_comb begin
	addr  = pc;
	rd    = 1'b0;
	wr    = 1'b0;
	wdata = wd;
	case (st)
		S_RST:   begin addr = {12'hFFF, seq[0]}; rd = 1'b1; end      // 1FFE, 1FFF
		S_FETCH, S_B1, S_B2: rd = 1'b1;
		S_RD:    begin addr = ea[12:0]; rd = ~is_clr; end      // CLR reads nothing (as MAME has it)
		S_PUSH: begin
			addr = {5'h00, 2'b11, sp};
			wr   = 1'b1;
			case (seq)
				3'd0:    wdata = pc[7:0];
				3'd1:    wdata = {3'b000, pc[12:8]};
				3'd2:    wdata = x;
				3'd3:    wdata = a;
				default: wdata = ccr;
			endcase
		end
		S_PULL:  begin addr = {5'h00, 2'b11, sp_up}; rd = 1'b1; end
		S_VEC:   begin addr = {vec[12:1], seq[0]}; rd = 1'b1; end
		S_TAIL:  begin addr = ea[12:0]; wr = do_wr & last; end
		default: ;
	endcase
end

// the interrupt to take at the end of this instruction, if any
wire int_irq = irq_l;
wire int_any = int_irq | int_timer | int_cpi;

// ---- the sequencer ------------------------------------------------------------------------
always_ff @(posedge clk) begin
	tr_valid <= 1'b0;
	if (cen) begin
		irq_q <= irq_n;
		if (irq_q & ~irq_n) irq_l <= 1'b1;

		cyc <= cyc + 4'd1;
		case (st)
			S_RST: begin
				if (seq[0]) begin pc[7:0] <= rdata; st <= S_FETCH; cyc <= 4'd0; end
				else pc[12:8] <= rdata[4:0];
				seq <= seq + 3'd1;
			end

			S_FETCH: begin
				op    <= rdata;
				ipc   <= pc;
				pc    <= pc + 13'd1;
				intr  <= 1'b0;
				do_wr <= 1'b0;
				seq   <= 3'd0;
				ea    <= {8'h00, x};             // the indexed form's address
				case (rdata[7:4])
					4'h4, 4'h5, 4'h9: st <= S_EXEC;
					4'h7:             st <= S_RD;
					4'h8: case (rdata[3:0])
						4'h0, 4'h1: st <= S_PULL;
						4'h3:       st <= S_PUSH;
						default:    st <= S_TAIL;    // STOP, WAIT, and what does not exist
					endcase
					4'hF: st <= after_ea(rdata[3:0]);
					default:          st <= S_B1;
				endcase
				if (rdata[7:4] == 4'hF) begin
					// the indexed form has no operand bytes: JMP and the stores start here
					if (rdata[3:0] == 4'hC) pc <= {5'h00, x};
					if (rdata[3:0] == 4'h7 || rdata[3:0] == 4'hF) begin
						wd    <= rdata[3] ? x : a;
						do_wr <= 1'b1;
						fn    <= rdata[3] ? x[7] : a[7];
						fz    <= (rdata[3] ? x : a) == 8'h00;
					end
				end
			end

			S_B1: begin
				pc <= pc + 13'd1;
				b1 <= rdata;
				case (hi)
					4'h0, 4'h1, 4'h3: begin ea <= ea_dir; st <= S_RD; end
					4'h2: begin
						if (branch(lo, fc, fz, fh, fn, fi, ~irq_n)) pc <= pc_rel;
						st <= S_TAIL;
					end
					4'h6: begin ea <= ea_ix1; st <= S_RD; end
					4'hA: begin
						if (lo == 4'hD) st <= S_PUSH;    // BSR: b1 is the offset
						else if (lo == 4'h7 || lo == 4'hC || lo == 4'hF) st <= S_TAIL;   // not instructions
						else begin
							// immediate
							if (bi[12]) begin if (use_x) x <= bi[7:0]; else a <= bi[7:0]; end
							{fh, fn, fz, fc} <= bi[11:8];
							st <= S_TAIL;
						end
					end
					4'hB: begin
						ea <= ea_dir;
						if (lo == 4'hC) pc <= ea_dir[12:0];
						st <= after_ea(lo);
					end
					4'hE: begin
						ea <= ea_ix1;
						if (lo == 4'hC) pc <= ea_ix1[12:0];
						st <= after_ea(lo);
					end
					default: st <= S_B2;              // C, D
				endcase
				if ((hi == 4'hB || hi == 4'hE) && (lo == 4'h7 || lo == 4'hF)) begin
					// STA, STX
					wd    <= use_x ? x : a;
					do_wr <= 1'b1;
					fn    <= use_x ? x[7] : a[7];
					fz    <= (use_x ? x : a) == 8'h00;
				end
			end

			S_B2: begin
				pc <= pc + 13'd1;
				if (hi == 4'h0) begin
					// BRSET, BRCLR: the bit was read into t; C is the bit
					fc <= t[op[3:1]];
					if (t[op[3:1]] ^ op[0]) pc <= pc_rel;
					st <= S_TAIL;
				end
				else begin
					ea <= hi == 4'hC ? ea_ext : ea_ix2;
					if (lo == 4'hC) pc <= hi == 4'hC ? ea_ext[12:0] : ea_ix2[12:0];
					st <= after_ea(lo);
					if (lo == 4'h7 || lo == 4'hF) begin
						wd    <= use_x ? x : a;
						do_wr <= 1'b1;
						fn    <= use_x ? x[7] : a[7];
						fz    <= (use_x ? x : a) == 8'h00;
					end
				end
			end

			S_RD: begin
				t <= rdata;
				st <= S_TAIL;
				case (hi)
					4'h0: st <= S_B2;                 // the offset byte next
					4'h1: begin
						// BSET, BCLR
						wd    <= op[0] ? rdata & ~(8'h01 << op[3:1]) : rdata | (8'h01 << op[3:1]);
						do_wr <= 1'b1;
					end
					4'h3, 4'h6, 4'h7: begin
						wd    <= un_m[7:0];
						do_wr <= lo != 4'hD;          // TST only reads
						{fn, fz, fc} <= un_m[10:8];
					end
					default: begin
						if (bi[12]) begin if (use_x) x <= bi[7:0]; else a <= bi[7:0]; end
						{fh, fn, fz, fc} <= bi[11:8];
					end
				endcase
			end

			S_EXEC: begin
				st <= S_TAIL;
				case (hi)
					4'h4: begin
						if (lo == 4'h2) begin
							// MUL
							x <= mul[15:8];
							a <= mul[7:0];
							fh <= 1'b0;
							fc <= 1'b0;
						end
						else begin
							a <= un_a[7:0];
							{fn, fz, fc} <= un_a[10:8];
						end
					end
					4'h5: begin
						x <= un_x[7:0];
						{fn, fz, fc} <= un_x[10:8];
					end
					default: case (lo)
						4'h7: x <= a;                 // TAX
						4'h8: fc <= 1'b0;             // CLC
						4'h9: fc <= 1'b1;             // SEC
						4'hA: fi <= 1'b0;             // CLI
						4'hB: fi <= 1'b1;             // SEI
						4'hC: sp <= 6'h3F;            // RSP
						4'hF: a <= x;                 // TXA
						default: ;                    // NOP
					endcase
				endcase
			end

			S_PUSH: begin
				sp  <= sp - 6'd1;
				seq <= seq + 3'd1;
				if (op == 8'h83) begin
					// SWI or an interrupt: pc, x, a, cc, then the vector
					if (seq == 3'd4) begin
						fi  <= 1'b1;
						seq <= 3'd0;
						st  <= S_VEC;
						if (!intr) vec <= 13'h1FFC;
					end
				end
				else if (seq == 3'd1) begin
					// JSR, BSR: the return address is pushed, now the jump
					st <= S_TAIL;
					if (hi == 4'hA) pc <= pc + {{5{b1[7]}}, b1};
					else pc <= ea[12:0];
				end
			end

			S_PULL: begin
				sp  <= sp_up;
				seq <= seq + 3'd1;
				if (lo == 4'h1) begin
					// RTS
					if (seq == 3'd0) pc[12:8] <= rdata[4:0];
					else begin pc[7:0] <= rdata; st <= S_TAIL; end
				end
				else case (seq)
					// RTI
					3'd0: {fh, fi, fn, fz, fc} <= rdata[4:0];
					3'd1: a <= rdata;
					3'd2: x <= rdata;
					3'd3: pc[12:8] <= rdata[4:0];
					default: begin pc[7:0] <= rdata; st <= S_TAIL; end
				endcase
			end

			S_VEC: begin
				seq <= seq + 3'd1;
				if (seq[0]) begin pc[7:0] <= rdata; st <= S_TAIL; end
				else pc[12:8] <= rdata[4:0];
			end

			default: ;                                // S_TAIL, S_WAIT: below
		endcase

		// the instruction's last cycle: the next one, or an interrupt
		if ((st != S_RST && st != S_FETCH && st != S_WAIT && last) || (st == S_WAIT && int_any)) begin
			tr_valid <= st != S_WAIT;
			tr_int   <= intr;
			tr_pc    <= intr ? vec : ipc;
			tr_op    <= op;
			cyc      <= 4'd0;
			seq      <= 3'd0;
			if (st != S_WAIT && op[7:1] == 7'b1000_111) begin
				// STOP, WAIT: I is cleared and nothing runs until an interrupt
				fi <= 1'b0;
				st <= S_WAIT;
			end
			else if (int_any & (~fi | st == S_WAIT)) begin
				// an interrupt's entry: SWI's sequence with the source's vector
				st    <= S_PUSH;
				op    <= 8'h83;
				intr  <= 1'b1;
				ipc   <= pc;
				do_wr <= 1'b0;
				if (int_irq) begin vec <= 13'h1FFA; irq_l <= 1'b0; end
				else if (int_timer) vec <= 13'h1FF8;
				else vec <= 13'h1FF6;
			end
			else st <= S_FETCH;
		end
	end

	if (reset) begin
		st    <= S_RST;
		seq   <= 3'd0;
		cyc   <= 4'd0;
		op    <= 8'h9D;
		a     <= 8'h00;
		x     <= 8'h00;
		sp    <= 6'h3F;
		fh    <= 1'b0;
		fi    <= 1'b1;
		fn    <= 1'b0;
		fz    <= 1'b0;
		fc    <= 1'b0;
		intr  <= 1'b0;
		do_wr <= 1'b0;
		irq_l <= 1'b0;
		irq_q <= 1'b1;
		tr_valid <= 1'b0;
	end
end

assign tr_a  = a;
assign tr_x  = x;
assign tr_sp = {2'b11, sp};
assign tr_cc = ccr;

endmodule

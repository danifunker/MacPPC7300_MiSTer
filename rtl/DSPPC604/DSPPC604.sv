//============================================================================
//
//  DSPPC604 - PowerPC 604-class CPU core
//  The pipeline
//
//    IF1 -> IF2 -> ID -> EX -> MEM -> WB
//
//    IF1  fetch address out
//    IF2  instruction word back
//    ID   decode, register read, sequencer for multi-operation instructions
//    EX   execute units, effective address, branch resolution
//    MEM  data memory access
//    WB   general register write
//
//  How state is committed
//    CR, XER, LR, CTR and FPSCR are written when an instruction leaves EX.
//    Nothing older can still fault at that point (only a memory access in
//    MEM can, and EX cannot be left while MEM is occupied), and the
//    instruction itself can no longer be cancelled. They therefore need no
//    forwarding: EX always reads the committed registers.
//    General and floating-point registers are written in WB and forwarded
//    from MEM and WB. One operation writes at most one of them; a register is
//    named by seven bits, the top one set for a floating-point register.
//    Memory is written in MEM.
//    Invariant: an operation that accesses memory writes none of CR, XER, LR,
//    CTR and FPSCR.
//
//  Buses
//    Both buses use req/gnt for the address and one rvalid per granted
//    request, at least a cycle later. The data bus is described in
//    DSPPC604_mem_unit.
//
//  Branch prediction
//    A small branch target buffer is read with the fetch address. Every
//    instruction carries the address the fetch continued with; EX compares
//    it with where the instruction really goes next and redirects on a
//    difference. So a wrong or stale prediction costs time, never
//    correctness.
//
//  Not here yet: exceptions and supervisor state (an instruction the core
//  does not implement stops it with `halted`), MMU, caches.
//
//============================================================================

module DSPPC604
#(
	parameter int BTB_BITS = 7       // branch target buffer entries, as a power of two
)
(
	input  logic        clk,
	input  logic        reset,
	input  logic [31:0] reset_pc,

	// instruction bus
	output logic        ibus_req,
	output logic [31:0] ibus_addr,
	input  logic        ibus_gnt,
	input  logic        ibus_rvalid,
	input  logic [31:0] ibus_rdata,

	// data bus
	output logic        dbus_req,
	output logic        dbus_we,
	output logic [29:0] dbus_addr,
	output logic [3:0]  dbus_be,
	output logic [31:0] dbus_wdata,
	input  logic        dbus_gnt,
	input  logic        dbus_rvalid,
	input  logic [31:0] dbus_rdata,

	// stopped at an instruction this core does not implement
	output logic        halted,
	output logic [31:0] halt_pc,

	// retirement trace for the test bench: one pulse per operation leaving
	// the pipeline, with the state as that instruction left it
	output logic        trace_valid,
	output logic        trace_last,      // completes an instruction
	output logic [31:0] trace_pc,
	output logic [31:0] trace_insn,
	output logic        trace_reg_we,
	output logic [6:0]  trace_reg_idx,   // 0-31 GPR, 32 scratch, 64-95 FPR
	output logic [63:0] trace_reg_val,
	output logic [31:0] trace_cr,
	output logic [31:0] trace_xer,
	output logic [31:0] trace_lr,
	output logic [31:0] trace_ctr,
	output logic [31:0] trace_fpscr
);

import DSPPC604_pkg::*;

localparam logic [31:0] XER_MASK = 32'hE000007F;   // SO OV CA, byte count

// ---- architectural state ---------------------------------------------------
logic [31:0] gpr [33];      // 32 is the sequencer's scratch register
logic [63:0] fpr [32];
logic [31:0] cr;
logic [31:0] xer;
logic [31:0] lr;
logic [31:0] ctr;
logic [31:0] fpscr;

// ---- pipeline registers ----------------------------------------------------
// IF1 / IF2
logic [31:0] pc_f;          // next address to fetch
logic        if2_valid;     // a fetch is outstanding or its word is held
logic        if2_kill;      // ... but it was cancelled: drop the word
logic        if2_has;       // the word arrived and is waiting for ID
logic [31:0] if2_pc;
logic [31:0] if2_insn;
logic [31:0] if2_pred;      // where the fetch went next
logic        if2_btb;       // the branch target buffer knew this address
logic [1:0]  if2_cnt;       // ... with this taken/not-taken counter

// ID
logic        id_valid;
logic [31:0] id_pc;
logic [31:0] id_insn;
logic [31:0] id_pred;
logic        id_btb;
logic [1:0]  id_cnt;

// EX
logic        ex_valid;
logic [31:0] ex_pc;
logic [31:0] ex_insn;
dec_t        ex_dec;
logic        ex_ill;        // not implemented: stop here
logic        ex_last;
logic [31:0] ex_pred;
logic        ex_btb;
logic [1:0]  ex_cnt;
logic [31:0] ex_a;
logic [31:0] ex_b;
logic [31:0] ex_c;
logic [63:0] ex_fa;
logic [63:0] ex_fb;
logic [63:0] ex_fc;

// MEM
logic        mem_valid;
logic [31:0] mem_pc;
logic [31:0] mem_insn;
logic        mem_last;
logic [6:0]  mem_rd;        // bit 6: a floating-point register
logic        mem_rd_wr;
logic [63:0] mem_result;    // from EX (a load's comes from memory instead)
logic [31:0] mem_ea;
logic        mem_load;
logic        mem_store;
logic [3:0]  mem_n;
logic        mem_sext;
logic        mem_brev;
logic        mem_ljust;
logic        mem_fp;
logic        mem_fsgl;
logic [63:0] mem_wdata;
logic [31:0] mem_t_cr, mem_t_xer, mem_t_lr, mem_t_ctr, mem_t_fpscr;

// WB
logic        wb_valid;
logic [31:0] wb_pc;
logic [31:0] wb_insn;
logic        wb_last;
logic [6:0]  wb_rd;
logic        wb_rd_wr;
logic [63:0] wb_result;
logic [31:0] wb_t_cr, wb_t_xer, wb_t_lr, wb_t_ctr, wb_t_fpscr;

logic        halt_q;        // an unimplemented instruction reached EX

// ---- stage handshakes ------------------------------------------------------
logic        redir;         // EX redirects the fetch at the end of this cycle
logic [31:0] redir_pc;
logic        id_take;       // ID's operation moves to EX
logic        id_leave;      // ... and it was the instruction's last
logic        ex_leave;
logic        mem_leave;

wire id_ready  = ~id_valid | id_leave;
wire ex_ready  = ~ex_valid | ex_leave;
wire mem_ready = ~mem_valid | mem_leave;

// ============================================================================
//  IF1, IF2
// ============================================================================
wire        if2_resp  = if2_valid & (if2_has | ibus_rvalid);
wire [31:0] if2_word  = if2_has ? if2_insn : ibus_rdata;
wire        if2_leave = if2_resp & (if2_kill | id_ready);

assign ibus_req  = ~reset & ~halt_q & (~if2_valid | if2_leave);
assign ibus_addr = pc_f;

wire fetch_go = ibus_req & ibus_gnt;

// ---- branch target buffer --------------------------------------------------
localparam int BTB_SIZE = 1 << BTB_BITS;
localparam int BTB_TAGW = 30 - BTB_BITS;

logic [BTB_SIZE-1:0] btb_valid;
logic [BTB_TAGW-1:0] btb_tag    [BTB_SIZE];
logic [29:0]         btb_target [BTB_SIZE];
logic [1:0]          btb_cnt    [BTB_SIZE];     // 2 and 3 predict taken

wire [BTB_BITS-1:0] btb_idx  = pc_f[BTB_BITS+1:2];
wire                btb_hit  = btb_valid[btb_idx] & (btb_tag[btb_idx] == pc_f[31:BTB_BITS+2]);
wire [1:0]          btb_c    = btb_cnt[btb_idx];
wire [31:0]         pred_pc  = (btb_hit & btb_c[1]) ? {btb_target[btb_idx], 2'b00} : (pc_f + 32'd4);

// written from EX (below)
logic                btb_we;
logic                btb_wtgt;     // ... including the target
logic                btb_clr;
logic [BTB_BITS-1:0] btb_widx;
logic [1:0]          btb_wcnt;

always_ff @(posedge clk) begin
	if (btb_we) begin
		btb_valid[btb_widx]  <= 1'b1;
		btb_tag[btb_widx]    <= ex_pc[31:BTB_BITS+2];
		btb_cnt[btb_widx]    <= btb_wcnt;
		if (btb_wtgt) btb_target[btb_widx] <= redir_pc[31:2];
	end
	if (btb_clr) btb_valid[btb_widx] <= 1'b0;
	if (reset) btb_valid <= '0;
end

always_ff @(posedge clk) begin
	if (if2_valid & ~if2_has & ibus_rvalid & ~if2_leave) begin
		if2_has  <= 1'b1;
		if2_insn <= ibus_rdata;
	end
	if (if2_leave) if2_valid <= 1'b0;

	if (fetch_go) begin
		if2_valid <= 1'b1;
		if2_kill  <= redir;      // fetched from the wrong path in this very cycle
		if2_has   <= 1'b0;
		if2_pc    <= pc_f;
		if2_pred  <= pred_pc;
		if2_btb   <= btb_hit;
		if2_cnt   <= btb_c;
		pc_f      <= pred_pc;
	end

	if (redir) begin
		pc_f <= redir_pc;
		// a fetch still waiting for its word is dropped when the word comes
		if (if2_valid & ~if2_leave) if2_kill <= 1'b1;
	end

	if (reset) begin
		pc_f      <= reset_pc;
		if2_valid <= 1'b0;
		if2_kill  <= 1'b0;
		if2_has   <= 1'b0;
	end
end

// ============================================================================
//  ID
// ============================================================================
dec_t id_dec;
dec_t id_uop;
logic id_first;
logic id_last;
logic id_wait_xer;

DSPPC604_decode decode
(
	.insn (id_insn),
	.dec  (id_dec)
);

DSPPC604_seq seq
(
	.clk       (clk),
	.reset     (reset),
	.flush     (redir),
	.valid     (id_valid),
	.dec       (id_dec),
	.nb        (id_insn[15:11]),
	.xer_count (xer[6:0]),
	.take      (id_take),
	.uop       (id_uop),
	.first     (id_first),
	.last      (id_last),
	.wait_xer  (id_wait_xer)
);

// lswx and stswx read XER's byte count here: wait for anything in EX, the
// only place that could still be changing it
// Nothing follows an unimplemented instruction into EX.
// A redirect in the same cycle does not stop the move: the operation arrives
// in EX already cancelled.
wire   id_hold  = (id_wait_xer & ex_valid) | (ex_valid & ex_ill) | halt_q;
assign id_take  = id_valid & ex_ready & ~id_hold;
assign id_leave = id_take & (id_last | ~id_dec.valid);

// register read, with the value WB is writing in this cycle
function automatic logic [31:0] rf_read(input logic [5:0] idx);
	begin
		rf_read = (wb_valid & wb_rd_wr & (wb_rd == {1'b0, idx})) ? wb_result[31:0] : gpr[idx];
	end
endfunction

function automatic logic [63:0] ff_read(input logic [4:0] idx);
	begin
		ff_read = (wb_valid & wb_rd_wr & (wb_rd == {2'b10, idx})) ? wb_result : fpr[idx];
	end
endfunction

wire [31:0] id_a  = id_uop.ra_rd ? rf_read(id_uop.ra) : 32'd0;
wire [31:0] id_b  = id_uop.b_imm ? id_uop.imm : rf_read(id_uop.rb);
wire [31:0] id_c  = rf_read(id_uop.rc);
// Floating-point register numbers sit in fixed fields, so the read does not
// wait for the decoder. Only a store names its register (frS) elsewhere:
// opcodes 52-55, and the indexed forms under opcode 31, where nothing else
// reads a floating-point register.
wire        id_fp_store = (id_insn[31:28] == 4'b1101) | (id_insn[31:26] == 6'd31);
wire [63:0] id_fa = ff_read(id_insn[20:16]);
wire [63:0] id_fb = ff_read(id_fp_store ? id_insn[25:21] : id_insn[15:11]);
wire [63:0] id_fc = ff_read(id_insn[10:6]);

always_ff @(posedge clk) begin
	if (id_leave) id_valid <= 1'b0;
	if (if2_leave & ~if2_kill) begin
		id_valid <= 1'b1;
		id_pc    <= if2_pc;
		id_insn  <= if2_word;
		id_pred  <= if2_pred;
		id_btb   <= if2_btb;
		id_cnt   <= if2_cnt;
	end
	if (reset | redir | halt_q) id_valid <= 1'b0;
end

// ============================================================================
//  EX
// ============================================================================
// ---- operands, forwarded from MEM and WB ------------------------------------
wire ex_use_b = ex_dec.rb_rd & ~ex_dec.b_imm;

wire fa_mem = mem_valid & mem_rd_wr & ex_dec.ra_rd & (mem_rd == {1'b0, ex_dec.ra});
wire fb_mem = mem_valid & mem_rd_wr & ex_use_b     & (mem_rd == {1'b0, ex_dec.rb});
wire fc_mem = mem_valid & mem_rd_wr & ex_dec.rc_rd & (mem_rd == {1'b0, ex_dec.rc});
wire fa_wb  = wb_valid  & wb_rd_wr  & ex_dec.ra_rd & (wb_rd == {1'b0, ex_dec.ra});
wire fb_wb  = wb_valid  & wb_rd_wr  & ex_use_b     & (wb_rd == {1'b0, ex_dec.rb});
wire fc_wb  = wb_valid  & wb_rd_wr  & ex_dec.rc_rd & (wb_rd == {1'b0, ex_dec.rc});

wire [31:0] op_a = fa_mem ? mem_result[31:0] : fa_wb ? wb_result[31:0] : ex_a;
wire [31:0] op_b = fb_mem ? mem_result[31:0] : fb_wb ? wb_result[31:0] : ex_b;
wire [31:0] op_c = fc_mem ? mem_result[31:0] : fc_wb ? wb_result[31:0] : ex_c;

// the same for the floating-point operands
wire ffa_mem = mem_valid & mem_rd_wr & ex_dec.fra_rd & (mem_rd == {2'b10, ex_dec.fra});
wire ffb_mem = mem_valid & mem_rd_wr & ex_dec.frb_rd & (mem_rd == {2'b10, ex_dec.frb});
wire ffc_mem = mem_valid & mem_rd_wr & ex_dec.frc_rd & (mem_rd == {2'b10, ex_dec.frc});
wire ffa_wb  = wb_valid  & wb_rd_wr  & ex_dec.fra_rd & (wb_rd == {2'b10, ex_dec.fra});
wire ffb_wb  = wb_valid  & wb_rd_wr  & ex_dec.frb_rd & (wb_rd == {2'b10, ex_dec.frb});
wire ffc_wb  = wb_valid  & wb_rd_wr  & ex_dec.frc_rd & (wb_rd == {2'b10, ex_dec.frc});

wire [63:0] fop_a = ffa_mem ? mem_result : ffa_wb ? wb_result : ex_fa;
wire [63:0] fop_b = ffb_mem ? mem_result : ffb_wb ? wb_result : ex_fb;
wire [63:0] fop_c = ffc_mem ? mem_result : ffc_wb ? wb_result : ex_fc;

// a load's data is not there until it reaches WB
wire ex_stall = mem_load & (fa_mem | fb_mem | fc_mem | ffa_mem | ffb_mem | ffc_mem);

// ---- integer unit ----------------------------------------------------------
wire is_int = (ex_dec.unit == UNIT_ALU) | (ex_dec.unit == UNIT_MUL) | (ex_dec.unit == UNIT_DIV);

logic        int_resp;
logic [31:0] int_result;
logic        int_ca;
logic        int_ov;
logic [3:0]  int_cr;
/* verilator lint_off UNUSEDSIGNAL */
logic        int_ready;
/* verilator lint_on UNUSEDSIGNAL */

DSPPC604_int_unit int_unit
(
	.clk        (clk),
	.reset      (reset),
	.flush      (1'b0),
	.req_valid  (ex_valid & ~ex_ill & ~ex_stall & is_int),
	.req_ready  (int_ready),
	.unit       (ex_dec.unit),
	.ctl        (ex_dec.ic),
	.a          (op_a),
	.b          (op_b),
	.ca_in      (xer[29]),
	.so_in      (xer[31]),
	.resp_valid (int_resp),
	.resp_ready (mem_ready),
	.result     (int_result),
	.ca_out     (int_ca),
	.ov_out     (int_ov),
	.cr_out     (int_cr)
);

// ---- floating-point unit ---------------------------------------------------
wire is_fpu = (ex_dec.unit == UNIT_FPU);

logic        fpu_resp;
logic [63:0] fpu_result;
logic        fpu_result_we;
logic [31:0] fpu_fpscr;
logic [3:0]  fpu_cr;
/* verilator lint_off UNUSEDSIGNAL */
logic        fpu_ready;
logic        fpu_fex;
/* verilator lint_on UNUSEDSIGNAL */

DSPPC604_fpu fpu
(
	.clk        (clk),
	.reset      (reset),
	.flush      (1'b0),
	.req_valid  (ex_valid & ~ex_ill & ~ex_stall & is_fpu),
	.req_ready  (fpu_ready),
	.ctl        (ex_dec.fc),
	.a          (fop_a),
	.b          (fop_b),
	.c          (fop_c),
	.fpscr_in   (fpscr),
	.resp_valid (fpu_resp),
	.resp_ready (mem_ready),
	.result     (fpu_result),
	.result_we  (fpu_result_we),
	.fpscr_out  (fpu_fpscr),
	.cr_out     (fpu_cr),
	.fex        (fpu_fex)
);

// ---- the instructions that write FPSCR directly ----------------------------
logic [31:0] fsys_fpscr;
logic [3:0]  fsys_cr;

DSPPC604_fpscr fpscr_ops
(
	.op         (ex_dec.sys),
	.insn       (ex_insn),
	.fpscr      (fpscr),
	.frb        (fop_b[31:0]),
	.fpscr_next (fsys_fpscr),
	.cr_field   (fsys_cr)
);

wire ex_done = ~ex_stall & (ex_ill | (is_int ? int_resp : is_fpu ? fpu_resp : 1'b1));
assign ex_leave = ex_valid & ex_done & mem_ready;

// ---- branch ----------------------------------------------------------------
wire        is_br    = (ex_dec.br != BR_NONE);
wire        cr_bit   = cr[5'd31 - ex_dec.bi];
wire [31:0] ctr_m1   = ctr - 32'd1;
wire        br_count = is_br & ~ex_dec.bo[2];
wire        ctr_ok   = ex_dec.bo[2] | ((ctr_m1 != 32'd0) ^ ex_dec.bo[1]);
wire        cond_ok  = ex_dec.bo[4] | (cr_bit == ex_dec.bo[3]);
wire        br_taken = is_br & ctr_ok & cond_ok;

logic [31:0] br_target;
always_comb begin
	case (ex_dec.br)
		BR_LR:   br_target = {lr[31:2], 2'b00};
		BR_CTR:  br_target = {ctr[31:2], 2'b00};
		default: br_target = (ex_dec.br_aa ? 32'd0 : ex_pc) + ex_dec.imm;
	endcase
end

wire [31:0] ex_pc4 = ex_pc + 32'd4;

// Where this instruction really continues, against where the fetch went.
// Only an instruction's last operation decides.
assign redir_pc = br_taken ? br_target : ex_pc4;
wire   ex_final = ex_leave & ~ex_ill & ex_last;
assign redir    = ex_final & (redir_pc != ex_pred);

// Teach the branch target buffer: a taken branch is entered or strengthened,
// one that was not taken is weakened, and an entry that fired for something
// that is no branch at all is removed.
always_comb begin
	btb_widx = ex_pc[BTB_BITS+1:2];
	btb_we   = 1'b0;
	btb_wtgt = 1'b0;
	btb_clr  = 1'b0;
	btb_wcnt = 2'd2;
	if (ex_final) begin
		if (br_taken) begin
			btb_we   = 1'b1;
			btb_wtgt = 1'b1;
			btb_wcnt = ~ex_btb ? 2'd2 : (ex_cnt == 2'd3) ? 2'd3 : (ex_cnt + 2'd1);
		end
		else if (ex_btb & is_br) begin
			btb_we   = 1'b1;
			btb_wcnt = (ex_cnt == 2'd0) ? 2'd0 : (ex_cnt - 2'd1);
		end
		else if (ex_btb) begin
			btb_clr  = 1'b1;
		end
	end
end

// ---- CR and SPR moves, and what EX commits ---------------------------------
function automatic logic [31:0] cr_insert(input logic [31:0] old, input logic [2:0] fld, input logic [3:0] val);
	logic [4:0] sh;
	begin
		sh = {3'd7 - fld, 2'b00};
		cr_insert = (old & ~(32'hF << sh)) | ({28'd0, val} << sh);
	end
endfunction

function automatic logic [3:0] cr_field(input logic [31:0] v, input logic [2:0] fld);
	logic [31:0] t;
	begin
		t = v >> {3'd7 - fld, 2'b00};
		cr_field = t[3:0];
	end
endfunction

logic [31:0] cr_next;
logic [31:0] xer_next;
logic [31:0] lr_next;
logic [31:0] ctr_next;
logic [31:0] fpscr_next;
logic [31:0] sys_result;

always_comb begin
	cr_next    = cr;
	xer_next   = xer;
	lr_next    = lr;
	ctr_next   = ctr;
	fpscr_next = fpscr;
	sys_result = 32'd0;

	if (is_fpu) begin
		if (ex_dec.fpscr_wr) fpscr_next = fpu_fpscr;
		if (ex_dec.cr_wr)    cr_next    = cr_insert(cr, ex_dec.cr_fld, fpu_cr);
	end
	else if (is_int) begin
		if (ex_dec.ca_wr) xer_next[29] = int_ca;
		if (ex_dec.ov_wr) begin
			xer_next[30] = int_ov;
			xer_next[31] = xer[31] | int_ov;
		end
		if (ex_dec.cr_wr) cr_next = cr_insert(cr, ex_dec.cr_fld, int_cr);
	end
	else begin
		case (ex_dec.sys)
			SYS_CRLOG: cr_next[5'd31 - ex_dec.crbt] =
				ex_dec.crtt[{cr[5'd31 - ex_dec.crba], cr[5'd31 - ex_dec.crbb]}];
			SYS_MCRF:  cr_next = cr_insert(cr, ex_dec.crbt[4:2], cr_field(cr, ex_dec.crba[4:2]));
			SYS_MFCR:  sys_result = cr;
			SYS_MTCRF: begin
				for (int f = 0; f < 8; f++)
					if (ex_dec.crm[7 - f]) cr_next[31 - 4*f -: 4] = op_a[31 - 4*f -: 4];
			end
			SYS_MCRXR: begin
				cr_next  = cr_insert(cr, ex_dec.crbt[4:2], xer[31:28]);
				xer_next[31:28] = 4'd0;
			end
			SYS_MFSPR: begin
				case (ex_dec.spr)
					10'd1:   sys_result = xer;
					10'd8:   sys_result = lr;
					default: sys_result = ctr;
				endcase
			end
			SYS_MTSPR: begin
				case (ex_dec.spr)
					10'd1:   xer_next = op_a & XER_MASK;
					10'd8:   lr_next  = op_a;
					default: ctr_next = op_a;
				endcase
			end
			SYS_MFFS: begin
				// Rc: CR1 from the unchanged FPSCR
				if (ex_dec.cr_wr) cr_next = cr_insert(cr, 3'd1, fpscr[31:28]);
			end
			SYS_MTFSF, SYS_MTFSFI, SYS_MTFSB0, SYS_MTFSB1: begin
				fpscr_next = fsys_fpscr;
				if (ex_dec.cr_wr) cr_next = cr_insert(cr, 3'd1, fsys_fpscr[31:28]);
			end
			SYS_MCRFS: begin
				fpscr_next = fsys_fpscr;
				cr_next    = cr_insert(cr, ex_dec.cr_fld, fsys_cr);
			end
			default: ;
		endcase

		if (br_count)      ctr_next = ctr_m1;
		if (ex_dec.br_lk)  lr_next  = ex_pc4;
	end
end

// The value for the register this operation writes, and which register.
// The upper word mffs delivers is undefined; FFF80000 is what the 604 puts
// there for fctiw.
wire [63:0] ex_result = is_fpu ? fpu_result :
                        is_int ? {32'd0, int_result} :
                        (ex_dec.sys == SYS_MFFS) ? {32'hFFF80000, fpscr} : {32'd0, sys_result};
wire [6:0]  ex_rd     = ex_dec.frd_wr ? {2'b10, ex_dec.frd} : {1'b0, ex_dec.rd};
wire        ex_rd_wr  = ex_dec.rd_wr | (ex_dec.frd_wr & (~is_fpu | fpu_result_we));

// what a store writes
wire [63:0] ex_wdata  = ~ex_dec.mem_fp   ? {32'd0, op_c} :
                        ex_dec.mem_fsgl  ? {32'd0, fp_double_to_single(fop_b)} : fop_b;

always_ff @(posedge clk) begin
	if (ex_leave) ex_valid <= 1'b0;

	if (id_take) begin
		ex_valid <= ~redir;
		ex_pc    <= id_pc;
		ex_insn  <= id_insn;
		ex_dec   <= id_uop;
		ex_ill   <= ~id_dec.valid;
		ex_last  <= id_last | ~id_dec.valid;
		ex_pred  <= id_pred;
		ex_btb   <= id_btb;
		ex_cnt   <= id_cnt;
		ex_a     <= id_a;
		ex_b     <= id_b;
		ex_c     <= id_c;
		ex_fa    <= id_fa;
		ex_fb    <= id_fb;
		ex_fc    <= id_fc;
	end
	else if (ex_valid & ~ex_leave) begin
		// held here: keep what WB forwards, it is gone next cycle
		if (fa_wb & ~fa_mem) ex_a <= wb_result[31:0];
		if (fb_wb & ~fb_mem) ex_b <= wb_result[31:0];
		if (fc_wb & ~fc_mem) ex_c <= wb_result[31:0];
		if (ffa_wb & ~ffa_mem) ex_fa <= wb_result;
		if (ffb_wb & ~ffb_mem) ex_fb <= wb_result;
		if (ffc_wb & ~ffc_mem) ex_fc <= wb_result;
	end

	// commit CR, XER, LR, CTR, FPSCR
	if (ex_leave & ~ex_ill) begin
		cr    <= cr_next;
		xer   <= xer_next;
		lr    <= lr_next;
		ctr   <= ctr_next;
		fpscr <= fpscr_next;
	end

	// stop at an instruction that is not implemented
	if (ex_leave & ex_ill) begin
		halt_q  <= 1'b1;
		halt_pc <= ex_pc;
	end

	if (reset) begin
		ex_valid <= 1'b0;
		halt_q   <= 1'b0;
		cr       <= 32'd0;
		xer      <= 32'd0;
		lr       <= 32'd0;
		ctr      <= 32'd0;
		fpscr    <= 32'd0;
	end
end

assign halted = halt_q & ~mem_valid & ~wb_valid;

// ============================================================================
//  MEM
// ============================================================================
logic        mu_resp;
logic [63:0] mu_rdata;

// what a load delivers to its register
wire [63:0] mem_ldata = (mem_fp & mem_fsgl) ? fp_single_to_double(mu_rdata[31:0]) : mu_rdata;

DSPPC604_mem_unit mem_unit
(
	.clk         (clk),
	.reset       (reset),
	.req_valid   (mem_valid & (mem_load | mem_store)),
	.we          (mem_store),
	.addr        (mem_ea),
	.nbytes      (mem_n),
	.sext        (mem_sext),
	.brev        (mem_brev),
	.ljust       (mem_ljust),
	.wdata       (mem_wdata),
	.resp_valid  (mu_resp),
	.rdata       (mu_rdata),
	.dbus_req    (dbus_req),
	.dbus_we     (dbus_we),
	.dbus_addr   (dbus_addr),
	.dbus_be     (dbus_be),
	.dbus_wdata  (dbus_wdata),
	.dbus_gnt    (dbus_gnt),
	.dbus_rvalid (dbus_rvalid),
	.dbus_rdata  (dbus_rdata)
);

assign mem_leave = mem_valid & (~(mem_load | mem_store) | mu_resp);

always_ff @(posedge clk) begin
	if (mem_leave) mem_valid <= 1'b0;

	if (ex_leave & ~ex_ill) begin
		mem_valid  <= 1'b1;
		mem_pc     <= ex_pc;
		mem_insn   <= ex_insn;
		mem_last   <= ex_last;
		mem_rd     <= ex_rd;
		mem_rd_wr  <= ex_rd_wr;
		mem_result <= ex_result;
		mem_ea     <= int_result;
		mem_load   <= ex_dec.mem_rd;
		mem_store  <= ex_dec.mem_wr;
		mem_n      <= ex_dec.mem_n;
		mem_sext   <= ex_dec.mem_sext;
		mem_brev   <= ex_dec.mem_brev;
		mem_ljust  <= ex_dec.mem_ljust;
		mem_fp     <= ex_dec.mem_fp;
		mem_fsgl   <= ex_dec.mem_fsgl;
		mem_wdata  <= ex_wdata;
		mem_t_cr   <= cr_next;
		mem_t_xer  <= xer_next;
		mem_t_lr   <= lr_next;
		mem_t_ctr  <= ctr_next;
		mem_t_fpscr <= fpscr_next;
	end

	if (reset) mem_valid <= 1'b0;
end

// ============================================================================
//  WB
// ============================================================================
always_ff @(posedge clk) begin
	wb_valid <= mem_leave;
	if (mem_leave) begin
		wb_pc     <= mem_pc;
		wb_insn   <= mem_insn;
		wb_last   <= mem_last;
		wb_rd     <= mem_rd;
		wb_rd_wr  <= mem_rd_wr;
		wb_result <= mem_load ? mem_ldata : mem_result;
		wb_t_cr   <= mem_t_cr;
		wb_t_xer  <= mem_t_xer;
		wb_t_lr   <= mem_t_lr;
		wb_t_ctr  <= mem_t_ctr;
		wb_t_fpscr <= mem_t_fpscr;
	end

	if (wb_valid & wb_rd_wr) begin
		if (wb_rd[6]) fpr[wb_rd[4:0]] <= wb_result;
		else          gpr[wb_rd[5:0]] <= wb_result[31:0];
	end

	if (reset) wb_valid <= 1'b0;
end

assign trace_valid   = wb_valid;
assign trace_last    = wb_last;
assign trace_pc      = wb_pc;
assign trace_insn    = wb_insn;
assign trace_reg_we  = wb_rd_wr;
assign trace_reg_idx = wb_rd;
assign trace_reg_val = wb_result;
assign trace_cr      = wb_t_cr;
assign trace_xer     = wb_t_xer;
assign trace_lr      = wb_t_lr;
assign trace_ctr     = wb_t_ctr;
assign trace_fpscr   = wb_t_fpscr;

endmodule

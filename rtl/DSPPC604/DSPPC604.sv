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
//    Memory is written in MEM. A single loaded by lfs is converted to a
//    double in WB, from the registered word.
//    Invariant: an operation that accesses memory writes none of CR, XER, LR,
//    CTR and FPSCR.
//
//  Caches and memory
//    Two DSPPC604_cache instances, 16 KB each, answer the fetch and the
//    memory unit through req/gnt and one rvalid per granted request, a
//    cycle later on a hit; the MMU translates in the request cycle, in
//    between. Their line requests share one memory port, data first. A
//    snoop port keeps them coherent with whatever else reads or writes
//    memory.
//
//  Branch prediction
//    A small branch target buffer is read with the fetch address. Every
//    instruction carries the address the fetch continued with; EX compares
//    it with where the instruction really goes next and redirects on a
//    difference. So a wrong or stale prediction costs time, never
//    correctness.
//
//  Exceptions
//    Everything that can stop an instruction is known by the time it would
//    leave EX, with one exception below: an interrupt, an illegal or
//    privileged instruction, floating point switched off, a trap, a system
//    call, a misaligned access, a fetch that failed (an ISI, carried with the
//    instruction from the fetch). The instruction is then dropped instead of
//    moving on, SRR0, SRR1 and MSR are written, and the fetch is redirected
//    to the vector, all at that one edge. Because the status registers
//    commit in EX, EX sees the true MSR and FPSCR, so interrupts and pending
//    floating-point exceptions are simply conditions on the instruction that
//    happens to be there. A floating-point instruction that raises an
//    enabled exception itself completes first and traps at the same edge.
//    Interrupts are taken only on the first operation of an instruction.
//
//    The exception: a data access that cannot be translated faults in MEM
//    (a DSI). The instruction in MEM is dropped, the one in EX is cancelled
//    before it commits (EX can only leave in the cycle MEM's access
//    completes, so the fault gates that same edge), and the fetch is
//    redirected. Earlier operations of the same instruction stay done, as
//    for interrupts; that is allowed, the instruction being restartable.
//
//  Memory management
//    DSPPC604_mmu sits between the pipeline and the two buses: BATs, segment
//    registers, a TLB per side, a hardware walk of the page table. The TLBs
//    are read a cycle ahead (the predicted fetch address, the effective
//    address as an access leaves EX), so a hit costs no time.
//
//  Reservation and cache instructions
//    lwarx sets the reservation when its load completes; stwcx. is two
//    operations, the store (made only if the reservation is set, which it
//    clears) and then CR0 from the outcome, so that no memory operation
//    writes a status register. dcbz is eight word stores of zero. dcbf,
//    dcbst, dcbi and icbi translate their address and do nothing else until
//    there is a cache; dcbt and dcbtst do nothing at all.
//
//  Not here yet: caches, trace and machine-check exceptions, little-endian
//  mode.
//
//============================================================================

module DSPPC604
#(
	parameter int          BTB_BITS = 7,              // branch target buffer entries, as a power of two
	parameter int          TLB_BITS = 6,              // entries in each TLB, as a power of two
	parameter int          FPU_OPERAND_REG = 0,       // 1: the FPU takes its operands into a register first (a cycle each; on 2026-10-06 to 2026-10-09 for timing)
	parameter logic [31:0] PVR      = 32'h00040303    // processor version: 604 revision 3.3
)
(
	input  logic        clk,
	input  logic        reset,
	input  logic [31:0] reset_pc,

	input  logic        ext_irq,         // external interrupt request, level
	input  logic        tb_tick,         // one clock: advance the time base and decrementer

	// memory: one line (32 bytes) or one word with byte enables, read or
	// write; req stays up until ack, one request outstanding. Word 0 of a
	// line, the lowest address, is in bits 255-224; a word is in bits 31-0.
	output logic        mem_req,
	output logic        mem_we,
	output logic        mem_line,
	output logic [31:2] mem_addr,
	output logic [3:0]  mem_be,
	output logic [255:0] mem_wdata,
	input  logic        mem_ack,
	input  logic [255:0] mem_rdata,

	// snoop: anything else about to read (snoop_we = 0) or write memory
	// presents the line first and goes ahead after the acknowledge
	input  logic        snoop_req,
	input  logic        snoop_we,
	input  logic [31:5] snoop_addr,
	output logic        snoop_ack,

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
	output logic [31:0] trace_fpscr,
	output logic [31:0] trace_msr,
	// ... and every data access as it reaches the data cache, so that the
	// test bench can see stores the cache absorbs
	output logic        trace_dreq,
	output logic        trace_dwe,
	output logic [2:0]  trace_dkind,
	output logic [31:2] trace_daddr,
	output logic [3:0]  trace_dbe,
	output logic [31:0] trace_dwdata
);

import DSPPC604_pkg::*;

localparam logic [31:0] XER_MASK = 32'hE000FF7F;   // SO OV CA, bits 16-23, byte count: what a 604 keeps (measured)

// ---- architectural state ---------------------------------------------------
// Independent prospective instruction and micro-op reads avoid putting
// ID admission on RAM addresses. Entry 32 is the sequencer's scratch.
(* ramstyle = "M10K, no_rw_check" *) logic [31:0] gpr_fetch_a [33];
(* ramstyle = "M10K, no_rw_check" *) logic [31:0] gpr_fetch_b [33];
(* ramstyle = "M10K, no_rw_check" *) logic [31:0] gpr_fetch_c [33];
(* ramstyle = "M10K, no_rw_check" *) logic [31:0] gpr_sequence_a [33];
(* ramstyle = "M10K, no_rw_check" *) logic [31:0] gpr_sequence_c [33];
(* ramstyle = "M10K, no_rw_check" *) logic [63:0] fpr_a [32];
(* ramstyle = "M10K, no_rw_check" *) logic [63:0] fpr_b [32];
(* ramstyle = "M10K, no_rw_check" *) logic [63:0] fpr_c [32];
logic [31:0] cr;
logic [31:0] xer;
logic [31:0] lr;
logic [31:0] ctr;
logic [31:0] fpscr;

// supervisor state
localparam logic [31:0] MSR_MASK  = 32'h0005FF77;  // the bits the 604 implements (measured: bit 29, PM, is one of them)
localparam logic [31:0] SRR1_MASK = 32'h87C0FFFF;  // MSR bits saved in SRR1 and restored by rfi
localparam int MSR_EE = 15, MSR_PR = 14, MSR_FP = 13, MSR_FE0 = 11, MSR_FE1 = 8, MSR_IP = 6,
               MSR_IR = 5, MSR_DR = 4;

logic [31:0] msr;
logic [31:0] srr0;
logic [31:0] srr1;
logic [31:0] sprg [4];
logic [31:0] dar;
logic [31:0] dsisr;
logic [31:0] dec_r;         // decrementer
logic        dec_pending;   // it passed zero and the exception has not been taken
logic [31:0] tbl;
logic [31:0] tbu;
logic [31:0] sdr1;
logic [15:0][31:0] bat;     // IBAT0U ... DBAT3L, in SPR number order
logic [15:0][31:0] sr;
logic [31:0] hid0;
logic [31:0] ear;
logic [31:0] iabr;
logic [31:0] dabr;
logic [31:0] mmcr0;
logic [31:0] pmc1;
logic [31:0] pmc2;
logic [31:0] sia;
logic [31:0] sda;
logic [3:0]  pir;           // the four bits a 604 keeps

// ---- pipeline registers ----------------------------------------------------
// IF1 / IF2
logic [31:0] pc_f;          // next address to fetch
logic        if2_valid;     // a fetch is outstanding
logic        if2_kill;      // ... but it was cancelled: drop the word
logic [31:0] if2_pc;
logic [31:0] if2_pred;      // where the fetch went next
logic        if2_btb;       // the branch target buffer knew this address
logic        if2_way;
logic [1:0]  if2_cnt;       // ... with this taken/not-taken counter

// Three completed words plus one reserved response slot. Fetch admission
// depends only on registered occupancy, never on ID/EX/MEM readiness.
typedef struct packed {
	logic [31:0] pc, insn, pred, info;
	logic        btb, isi, way;
	logic [1:0]  cnt;
} fetch_t;
fetch_t fetch_queue [4];
logic [1:0] fetch_head, fetch_tail;
logic [2:0] fetch_count;
wire fetch_full = (fetch_count >= 3'd3);
logic fetch_pop;
logic fetch_bypass;
logic fetch_deliver;
fetch_t fetch_word;
// Two output slots retain one spare at sustained single-word throughput.
// Their registered occupancy controls FIFO reads, separating the FIFO RAM
// address/write control from late ID/EX completion readiness.
fetch_t fetch_stage [2];
fetch_t fetch_source_word;
logic fetch_stage_head, fetch_stage_tail;
logic [1:0] fetch_stage_count;
wire fetch_stage_ready = (fetch_stage_count != 2'd2);
wire fetch_stage_push = fetch_pop | fetch_bypass;

// ID
logic        id_valid;
logic [31:0] id_pc;
logic [31:0] id_insn;
logic [31:0] id_pred;
logic [31:0] id_cr_select;
logic        id_btb;
logic        id_way;
logic [1:0]  id_cnt;
logic        id_isi;
logic [31:0] id_isi_info;

// EX
logic        ex_valid;
logic [31:0] ex_pc;
logic [31:0] ex_insn;
dec_t        ex_dec;
logic        ex_ill;        // not an instruction this core implements
logic        ex_isi;
logic [31:0] ex_isi_info;
logic        ex_first;
logic        ex_last;
logic [31:0] ex_pred;
logic        ex_btb;
logic [31:0] ex_cr_select;
logic        ex_way;
logic [1:0]  ex_cnt;
logic [31:0] ex_a;
logic [31:0] ex_b;
logic [31:0] ex_c;
logic [63:0] ex_fa;
logic [63:0] ex_fb;
logic [63:0] ex_fc;

// Completed, speculative ALU operations behind the long operation in EX.
// They cannot fault or modify status. After that older operation commits,
// drain them through the ordinary MEM/WB path before the next EX commits.
typedef struct packed {
	logic [31:0] pc, insn, value;
	logic [5:0] rd;
} completion_t;
completion_t completion_queue [8];
logic [2:0] completion_head, completion_tail;
logic [3:0] completion_count;
logic [3:0] completion_older_count;
logic [7:0] completion_latest_older, completion_latest_younger;
logic completion_push, completion_pop, id_to_ex;
// Reserve the FIFO entry at issue, then execute from registered operands.
// Forward that stage's result to the next registered operands, preserving
// dependent issue without putting decode and execution in the same path.
logic completion_exec_valid;
logic [2:0] completion_exec_slot;
logic [31:0] completion_exec_a, completion_exec_b;
int_ctl_t completion_exec_ctl;
logic [31:0] completion_result;
wire ex_order_ready = (completion_older_count == 4'd0);

// MEM
logic        mem_valid;
logic [31:0] mem_pc;
logic [31:0] mem_insn;
logic        mem_last;
logic        mem_first;
logic [6:0]  mem_rd;        // bit 6: a floating-point register
logic        mem_rd_wr;
logic [63:0] mem_result;    // from EX (a load's comes from memory instead)
logic [31:0] mem_ea;
logic        mem_load;
logic        mem_store;
ck_t         mem_cop;       // what the access asks of the cache
logic [3:0]  mem_n;
logic        mem_sext;
logic        mem_brev;
logic        mem_ljust;
logic        mem_fp;
logic        mem_fsgl;
logic [63:0] mem_sdata;     // the value a store writes
logic [31:0] mem_t_cr, mem_t_xer, mem_t_lr, mem_t_ctr, mem_t_fpscr, mem_t_msr;

// WB
logic        wb_valid;
logic [31:0] wb_pc;
logic [31:0] wb_insn;
logic        wb_last;
logic [6:0]  wb_rd;
logic        wb_rd_wr;
logic [63:0] wb_result;
logic        wb_fsgl;       // ... is a single loaded by lfs, still as it was in memory
logic [31:0] wb_t_cr, wb_t_xer, wb_t_lr, wb_t_ctr, wb_t_fpscr, wb_t_msr;

// The value WB writes and forwards. lfs's single-to-double conversion (a
// leading-zero count and a shift for denormals) is made here, from the
// registered word, rather than in the cache's answer cycle, where it sat in
// series with the tag compare and the way select on the slowest path.
wire [63:0] wb_value = wb_fsgl ? fp_single_to_double(wb_result[31:0]) : wb_result;

// ---- stage handshakes ------------------------------------------------------
logic        redir;         // EX redirects the fetch at the end of this cycle
logic [31:0] redir_pc;
logic        id_take;       // ID's operation moves to EX
logic        id_leave;      // ... and it was the instruction's last
logic        ex_leave;
logic        mem_leave;
logic        mu_accept;
logic        mu_valid, mu_ready, mu_pending;
logic        ex_mem_access;
logic        ex_stall;
logic        ex_done;

// exception decisions made in EX (declared here: the units above them use them)
logic        x_pre;         // known without executing the instruction
logic        ex_abort;      // the instruction in EX is dropped
logic        ex_exc;        // an exception is taken as it leaves
logic [11:0] exc_vector;
logic [31:0] fpscr_next;
logic        mem_fault;     // MEM exception: DSI, or interrupt before the first grant
logic        mem_dsi, mem_irq;

wire id_ready  = ~id_valid | id_leave;
// Admission uses descriptor capacity, independently of late abort/fault
// decisions. A redirect annuls the newly admitted operation at the same edge.
// An abort can leave without descriptor capacity; ID waits in that case and
// is flushed. Normal completion still requires the memory unit's acceptance.
// An interrupt cancels both stages; it need not create speculative capacity
// for the younger ID operation. Use ordinary completion and MEM response
// capacity here, leaving interrupt/exception entry on the commit controls.
wire mem_capacity = ~mem_valid | ~(mem_load | mem_store) | mu_resp;
wire ex_regular_done = ~ex_stall & (is_int ? int_resp : is_fpu ? fpu_resp : 1'b1);
wire ex_ready  = ~ex_valid | (ex_regular_done & mem_capacity & ex_order_ready &
                             (~ex_mem_access | mu_ready));
wire mem_ready = ~mem_valid | mem_leave;

// ---- the buses as the pipeline sees them: through the MMU -------------------
logic        if_req;
logic [31:0] if_addr;
logic        if_gnt;
logic        if_rvalid;
logic [31:0] if_rdata;
logic        if_fault;
logic [31:0] if_srr1;

logic        mu_req, mu_we, mu_gnt, mu_rvalid, mu_bfault;
ck_t         mu_kind;
logic [29:0] mu_addr;
logic [3:0]  mu_be;
logic [31:0] mu_wdata, mu_bus_rdata;
logic        mu_wide, mu_rwide;
logic [31:0] mu_wdata_next, mu_rdata_next;

// ---- the buses between the MMU and the caches -------------------------------
logic        ib_req, ib_gnt, ib_rvalid, ib_ci;
logic [31:0] ib_addr, ib_rdata;
logic        db_req, db_we, db_gnt, db_rvalid, db_ci, db_wt;
ck_t         db_kind;
logic [29:0] db_addr;
logic [3:0]  db_be;
logic [31:0] db_wdata, db_rdata;
logic        db_wide, db_rwide;
logic [31:0] db_wdata_next, db_rdata_next;

// ---- the caches' memory and invalidate ports --------------------------------
logic         im_req, im_we, im_line, im_ack;
logic [31:2]  im_addr;
logic [3:0]   im_be;
logic [255:0] im_wdata;
logic         dm_req, dm_we, dm_line, dm_ack;
logic [31:2]  dm_addr;
logic [3:0]   dm_be;
logic [255:0] dm_wdata;
logic         dc_inv_req, dc_inv_ack;      // icbi, from the data cache to the instruction cache
logic         dc_inv_ack_q;
logic [31:5]  dc_inv_addr;
logic         ic_snoop_ack, dc_snoop_ack;
logic         ic_inval, dc_inval;          // HID0[ICFI], [DCFI]

// ============================================================================
//  IF1, IF2
// ============================================================================
wire if2_resp = if2_valid & if_rvalid;
wire fetch_response = if2_resp & ~if2_kill & ~redir;
wire fetch_push = fetch_response & ~fetch_bypass;
assign fetch_pop = (fetch_count != 3'd0) & fetch_stage_ready;
assign fetch_bypass = (fetch_count == 3'd0) & fetch_stage_ready & fetch_response;
assign fetch_deliver = (fetch_stage_count != 2'd0) & id_ready;
assign fetch_word = fetch_stage[fetch_stage_head];
assign fetch_source_word = (fetch_count != 3'd0) ? fetch_queue[fetch_head] :
                    {if2_pc, if_rdata, if2_pred, if_srr1, if2_btb, if_fault, if2_way, if2_cnt};

assign if_req  = ~reset & ~fetch_full;
assign if_addr = pc_f;

wire fetch_go = if_req & if_gnt;

// ---- branch target buffer --------------------------------------------------
localparam int BTB_SET_BITS = BTB_BITS - 1;
localparam int BTB_SETS = 1 << BTB_SET_BITS;
localparam int BTB_TAGW = 30 - BTB_SET_BITS;

logic [BTB_SETS-1:0] btb_valid0, btb_valid1, btb_lru;
logic btb_valid_q0, btb_valid_q1;
typedef struct packed {
	logic [BTB_TAGW-1:0] tag;
	logic [1:0] count;
	logic call, ret;
} btb_meta_t;
(* ramstyle = "no_rw_check" *) btb_meta_t btb_meta0 [BTB_SETS], btb_meta1 [BTB_SETS];
(* ramstyle = "no_rw_check" *) logic [29:0] btb_target0 [BTB_SETS], btb_target1 [BTB_SETS];
btb_meta_t btb_meta_ram0, btb_meta_ram1, btb_write_meta;
logic [29:0] btb_target_ram0, btb_target_ram1, btb_write_target;
logic btb_forward0, btb_forward1, btb_target_forward0, btb_target_forward1;
logic [BTB_SET_BITS-1:0] btb_read_idx;
logic btb_read_valid;

function automatic logic [BTB_SET_BITS-1:0] btb_index(input logic [31:0] address);
	btb_index = address[BTB_SET_BITS+1:2] ^ address[2*BTB_SET_BITS+1:BTB_SET_BITS+2];
endfunction

// Speculative call/return prediction is restored from the committed stack
// on every redirect, including the branch committing at that edge.
logic [31:0] ras_committed [8], ras_speculative [8];
logic [2:0] ras_cptr, ras_sptr;
logic [3:0] ras_ccount, ras_scount;
logic ras_recover;
logic ras_commit_write, ras_spec_write;
logic [2:0] ras_commit_write_ptr, ras_spec_write_ptr;
logic [31:0] ras_commit_write_data, ras_spec_write_data;
logic ras_push, ras_pop;
wire [2:0] ras_cptr_next = ras_push ? ras_cptr + 3'd1 : ras_pop ? ras_cptr - 3'd1 : ras_cptr;
wire [3:0] ras_ccount_next = ras_push ? ((ras_ccount == 4'd8) ? 4'd8 : ras_ccount + 4'd1) :
                              ras_pop ? ras_ccount - 4'd1 : ras_ccount;
wire [2:0] ras_read_ptr = ras_recover ? ras_cptr : ras_sptr;
wire [3:0] ras_read_count = ras_recover ? ras_ccount : ras_scount;
wire [2:0] ras_top = ras_read_ptr - 3'd1;
wire [31:0] ras_commit_target = (ras_commit_write & (ras_commit_write_ptr == ras_top)) ?
                               ras_commit_write_data : ras_committed[ras_top];
wire [31:0] ras_spec_target = (ras_spec_write & (ras_spec_write_ptr == ras_top)) ?
                             ras_spec_write_data : ras_speculative[ras_top];
wire [31:0] ras_read_target = ras_recover ? ras_commit_target : ras_spec_target;

wire [BTB_SET_BITS-1:0] btb_idx = btb_index(pc_f);
wire [BTB_SET_BITS-1:0] btb_ridx = btb_index(pc_ahead);
wire btb_fresh = btb_read_valid & (btb_read_idx == btb_idx);
wire [$bits(btb_meta_t)-1:0] btb_meta_bits0 = btb_forward0 ? btb_write_meta : btb_meta_ram0;
wire [$bits(btb_meta_t)-1:0] btb_meta_bits1 = btb_forward1 ? btb_write_meta : btb_meta_ram1;
btb_meta_t btb_meta_q0, btb_meta_q1;
assign btb_meta_q0 = btb_meta_bits0;
assign btb_meta_q1 = btb_meta_bits1;
wire btb_hit0 = btb_fresh & btb_valid_q0 & (btb_meta_q0.tag == pc_f[31:BTB_SET_BITS+2]);
wire btb_hit1 = btb_fresh & btb_valid_q1 & (btb_meta_q1.tag == pc_f[31:BTB_SET_BITS+2]);
wire btb_hit = btb_hit0 | btb_hit1;
wire btb_way = btb_hit0 ? 1'b0 : btb_hit1 ? 1'b1 :
               ~btb_valid0[btb_idx] ? 1'b0 : ~btb_valid1[btb_idx] ? 1'b1 : btb_lru[btb_idx];
// The prediction uses the hitting way. Replacement chooses a way only on
// a miss, so its valid/LRU lookup need not feed prediction's target mux.
wire [1:0] btb_c = btb_hit0 ? btb_meta_q0.count : btb_meta_q1.count;
wire btb_is_call = btb_hit0 ? btb_meta_q0.call : btb_meta_q1.call;
wire btb_is_return = btb_hit0 ? btb_meta_q0.ret : btb_meta_q1.ret;
wire [29:0] btb_target_q0 = btb_target_forward0 ? btb_write_target : btb_target_ram0;
wire [29:0] btb_target_q1 = btb_target_forward1 ? btb_write_target : btb_target_ram1;
wire [29:0] btb_target = btb_hit0 ? btb_target_q0 : btb_target_q1;
wire btb_taken = btb_hit & btb_c[1];
wire [31:0] btb_destination = (btb_is_return & (ras_read_count != 4'd0)) ?
                              ras_read_target : {btb_target, 2'b00};
wire [31:0] pred_pc = btb_taken ? btb_destination : (pc_f + 32'd4);

// written from EX (below)
logic                btb_we;
logic                btb_wtgt;     // ... including the target
logic                btb_clr;
logic [BTB_SET_BITS-1:0] btb_widx;
logic [1:0]          btb_wcnt;

// Resolve both possible rows before the late grant/redirect control. Keep
// these lookup nodes so synthesis does not move the row selection back
// in front of the 64-entry validity mux.
wire [BTB_SET_BITS-1:0] btb_next_idx = btb_index(pred_pc);
(* keep = "true" *) wire btb_valid_current0 = btb_valid0[btb_idx];
(* keep = "true" *) wire btb_valid_current1 = btb_valid1[btb_idx];
(* keep = "true" *) wire btb_valid_next0 = btb_valid0[btb_next_idx];
(* keep = "true" *) wire btb_valid_next1 = btb_valid1[btb_next_idx];
(* keep = "true" *) wire btb_write_current = (btb_widx == btb_idx);
(* keep = "true" *) wire btb_write_next = (btb_widx == btb_next_idx);
wire btb_write_read = fetch_go ? btb_write_next : btb_write_current;

always_ff @(posedge clk) begin
	// Read the predicted next set alongside the next fetch address. A redirect
	// to another set uses the normal fallthrough prediction until a fresh
	// lookup arrives. Forward a colliding write; RAM collision data is unused.
	btb_meta_ram0 <= btb_meta0[btb_ridx];
	btb_meta_ram1 <= btb_meta1[btb_ridx];
	btb_target_ram0 <= btb_target0[btb_ridx];
	btb_target_ram1 <= btb_target1[btb_ridx];
	btb_read_idx <= btb_ridx;
	btb_read_valid <= ~reset;
	// Validity is sampled with the same RAM row; forward same-edge updates.
	btb_valid_q0 <= (btb_clr & ~ex_way & btb_write_read) ? 1'b0 :
	                (btb_we & ~ex_way & btb_write_read) ? 1'b1 :
	                fetch_go ? btb_valid_next0 : btb_valid_current0;
	btb_valid_q1 <= (btb_clr & ex_way & btb_write_read) ? 1'b0 :
	                (btb_we & ex_way & btb_write_read) ? 1'b1 :
	                fetch_go ? btb_valid_next1 : btb_valid_current1;
	// Reuse the parallel current/predicted row comparison, as validity does.
	// Selecting the row index before comparison puts late fetch control in
	// front of the six-bit equality check and its forwarding registers.
	btb_forward0 <= btb_we & ~ex_way & btb_write_read & ~reset;
	btb_forward1 <= btb_we & ex_way & btb_write_read & ~reset;
	btb_target_forward0 <= btb_we & btb_wtgt & ~ex_way & (btb_widx == btb_ridx) & ~reset;
	btb_target_forward1 <= btb_we & btb_wtgt & ex_way & (btb_widx == btb_ridx) & ~reset;
	btb_write_meta <= {ex_pc[31:BTB_SET_BITS+2], btb_wcnt, ex_dec.br_lk,
	                  (ex_dec.br == BR_LR) & ~ex_dec.br_lk};
	btb_write_target <= redir_pc[31:2];
	if (btb_we & ~ex_way) begin
		btb_valid0[btb_widx] <= 1'b1;
		btb_meta0[btb_widx] <= {ex_pc[31:BTB_SET_BITS+2], btb_wcnt, ex_dec.br_lk,
		                      (ex_dec.br == BR_LR) & ~ex_dec.br_lk};
		if (btb_wtgt) btb_target0[btb_widx] <= redir_pc[31:2];
	end
	if (btb_we & ex_way) begin
		btb_valid1[btb_widx] <= 1'b1;
		btb_meta1[btb_widx] <= {ex_pc[31:BTB_SET_BITS+2], btb_wcnt, ex_dec.br_lk,
		                      (ex_dec.br == BR_LR) & ~ex_dec.br_lk};
		if (btb_wtgt) btb_target1[btb_widx] <= redir_pc[31:2];
	end
	if (btb_clr & ~ex_way) btb_valid0[btb_widx] <= 1'b0;
	if (btb_clr & ex_way) btb_valid1[btb_widx] <= 1'b0;
	if (btb_we) btb_lru[btb_widx] <= ~ex_way;
	if (reset) begin
		btb_valid0 <= '0;
		btb_valid1 <= '0;
		btb_valid_q0 <= 1'b0;
		btb_valid_q1 <= 1'b0;
		btb_lru <= '0;
	end
end

always_ff @(posedge clk) begin
	// Late commit/fetch admission updates the narrow flags and pointers now.
	// The wide payload writes land one edge later and forward in the meantime.
	ras_commit_write <= ras_push;
	ras_commit_write_ptr <= ras_cptr;
	ras_commit_write_data <= ex_pc + 32'd4;
	ras_spec_write <= fetch_go & btb_taken & btb_is_call;
	ras_spec_write_ptr <= ras_read_ptr;
	ras_spec_write_data <= pc_f + 32'd4;
	if (ras_commit_write) ras_committed[ras_commit_write_ptr] <= ras_commit_write_data;
	ras_cptr <= ras_cptr_next;
	ras_ccount <= ras_ccount_next;
	// A redirect selects the committed stack on the following cycle. Its
	// post-edge state already includes that redirecting branch's push/pop.
	// Restore the speculative array from this registered decision, while
	// applying any prediction at this edge to the same committed base.
	ras_recover <= redir;
	// A simultaneous redirect makes these speculative writes unused: the
	// registered recovery flag selects the committed base at the next edge.
	// Therefore the wide array's write path needs no late redirect gate.
	if (ras_recover) begin
		for (int i = 0; i < 8; i++)
			ras_speculative[i] <= (ras_commit_write & (ras_commit_write_ptr == i[2:0])) ?
			                      ras_commit_write_data : ras_committed[i];
	end
	else if (ras_spec_write) ras_speculative[ras_spec_write_ptr] <= ras_spec_write_data;
	ras_sptr <= ras_read_ptr;
	ras_scount <= ras_read_count;
	if (fetch_go & btb_taken) begin
		if (btb_is_call) begin
			ras_sptr <= ras_read_ptr + 3'd1;
			if (ras_read_count != 4'd8) ras_scount <= ras_read_count + 4'd1;
		end
		else if (btb_is_return & (ras_read_count != 4'd0)) begin
			ras_sptr <= ras_read_ptr - 3'd1;
			ras_scount <= ras_read_count - 4'd1;
		end
	end
	if (reset) begin
		ras_commit_write <= 1'b0;
		ras_spec_write <= 1'b0;
		ras_recover <= 1'b0;
		ras_cptr <= 3'd0;
		ras_sptr <= 3'd0;
		ras_ccount <= 4'd0;
		ras_scount <= 4'd0;
	end
end

// the address pc_f takes at the end of this cycle; the MMU reads its TLB
// ahead with the predicted one (a redirect into another page costs a cycle
// there, which keeps branch resolution away from the TLB's address)
wire [31:0] pc_next = reset ? reset_pc : redir ? redir_pc : fetch_go ? pred_pc : pc_f;
wire [31:0] pc_ahead = fetch_go ? pred_pc : pc_f;

always_ff @(posedge clk) begin
	if (fetch_stage_push) begin
		fetch_stage[fetch_stage_tail] <= fetch_source_word;
		fetch_stage_tail <= ~fetch_stage_tail;
	end
	if (fetch_deliver) fetch_stage_head <= ~fetch_stage_head;
	case ({fetch_stage_push, fetch_deliver})
		2'b10: fetch_stage_count <= fetch_stage_count + 2'd1;
		2'b01: fetch_stage_count <= fetch_stage_count - 2'd1;
		default: ;
	endcase
	if (fetch_push) begin
		fetch_queue[fetch_tail] <= {if2_pc, if_rdata, if2_pred, if_srr1, if2_btb, if_fault, if2_way, if2_cnt};
		fetch_tail <= fetch_tail + 2'd1;
	end
	if (fetch_pop) fetch_head <= fetch_head + 2'd1;
	case ({fetch_push, fetch_pop})
		2'b10: fetch_count <= fetch_count + 3'd1;
		2'b01: fetch_count <= fetch_count - 3'd1;
		default: ;
	endcase
	if (if2_resp) if2_valid <= 1'b0;

	if (fetch_go) begin
		if2_valid <= 1'b1;
		if2_kill  <= redir;      // fetched from the wrong path in this very cycle
		if2_pc    <= pc_f;
		if2_pred  <= pred_pc;
		if2_btb   <= btb_hit;
		if2_way   <= btb_way;
		if2_cnt   <= btb_c;
	end

	// a fetch still waiting for its word is dropped when the word comes
	if (redir & if2_valid & ~if2_resp) if2_kill <= 1'b1;
	if (reset | redir) begin
		fetch_stage_count <= 2'd0;
		fetch_stage_head <= 1'b0;
		fetch_stage_tail <= 1'b0;
		fetch_count <= 3'd0;
		fetch_head <= 2'd0;
		fetch_tail <= 2'd0;
	end

	pc_f <= pc_next;

	if (reset) begin
		if2_valid <= 1'b0;
		if2_kill  <= 1'b0;
	end
end

// ============================================================================
//  ID
// ============================================================================
dec_t id_dec;
dec_t id_uop;
dec_t fetch_dec;
logic [5:0] id_completion_ra, id_completion_rb;
logic id_completion_ra_rd, id_completion_rb_rd, id_completion_b_imm;
logic id_completion_simple;
logic id_first;
logic id_last;
logic id_wait_xer;

DSPPC604_decode decode
(
	.insn (id_insn),
	.dec  (id_dec)
);

// Capture single-operation ALU indices and eligibility with ID, keeping
// opcode decode out of the queue's dependency-to-fetch-readiness path.
DSPPC604_decode fetch_decode (.insn(fetch_word.insn), .dec(fetch_dec));
wire fetch_completion_simple = fetch_dec.valid & (fetch_dec.unit == UNIT_ALU) &
    (fetch_dec.seq == SEQ_NONE) & fetch_dec.rd_wr & ~fetch_dec.rc_rd &
    ~fetch_dec.priv & ~fetch_dec.fp_use & ~fetch_dec.trap &
    ~fetch_dec.mem_rd & ~fetch_dec.mem_wr & (fetch_dec.br == BR_NONE) &
    ~fetch_dec.ca_wr & ~fetch_dec.ov_wr & ~fetch_dec.cr_wr & ~fetch_dec.fpscr_wr &
    (fetch_dec.ic.cin != CIN_CA);

// lswx and stswx, from the opcode bits: the sequencer's wait for XER must
// not come through the decoder (see wait_xer there)
wire id_strx = (id_insn[31:26] == 6'd31) & ((id_insn[10:1] == 10'd533) | (id_insn[10:1] == 10'd661));
// lbzux, lhzux, lhaux, lwzux (extended opcodes 119, 311, 375, 55: bits 9
// and 7 clear, 5-0 = 110111) with rD = rB, likewise: the sequencer then
// reads the scratch register, which must not wait for the decoder either
wire id_ldux_rb = (id_insn[31:26] == 6'd31) & ~id_insn[10] & ~id_insn[8] & (id_insn[6:1] == 6'b110111) &
                  (id_insn[25:21] == id_insn[15:11]);

logic [5:0] seq_next_ra, seq_next_rc;
DSPPC604_seq seq
(
	.clk       (clk),
	.reset     (reset),
	.flush     (redir),
	.valid     (id_valid),
	.dec       (id_dec),
	.nb        (id_insn[15:11]),
	.strx      (id_strx),
	.ldux_rb   (id_ldux_rb),
	.xer_count (xer[6:0]),
	.take      (id_take),
	.uop       (id_uop),
	.first     (id_first),
	.last      (id_last),
	.wait_xer  (id_wait_xer),
	.next_ra   (seq_next_ra),
	.next_rc   (seq_next_rc)
);

// lswx and stswx read XER's byte count here: wait for anything in EX, the
// only place that could still be changing it
// A redirect in the same cycle does not stop the move: the operation arrives
// in EX already cancelled.
wire   id_hold  = id_wait_xer & ex_valid;
assign id_to_ex = id_valid & ex_ready & ~id_hold;
assign id_take  = id_to_ex | completion_push;
assign id_leave = (id_to_ex & (id_last | ~id_dec.valid)) | completion_push;

// Read the prospective fetched word and next sequencer operation at every
// edge. Late ID take selects a registered sample, never a RAM address. A
// stalled operand retains its sample and any subsequent WB write. RB does
// not change across a sequenced instruction, so it needs only a fetch copy.
wire gpr_write = wb_valid & wb_rd_wr & ~wb_rd[6];
wire gpr_seq_take = id_take & ~id_last;
logic [31:0] gpr_ram_fa, gpr_ram_fb, gpr_ram_fc, gpr_ram_sa, gpr_ram_sc;
logic [4:0] gpr_collision;
logic [31:0] gpr_collision_value;
logic gpr_held_ac, gpr_held_b, gpr_from_sequence;
logic [31:0] gpr_held_a_value, gpr_held_b_value, gpr_held_c_value;
always_ff @(posedge clk) begin
	gpr_ram_fa <= gpr_fetch_a[fetch_dec.ra];
	gpr_ram_fb <= gpr_fetch_b[fetch_dec.rb];
	gpr_ram_fc <= gpr_fetch_c[fetch_dec.rc];
	gpr_ram_sa <= gpr_sequence_a[seq_next_ra];
	gpr_ram_sc <= gpr_sequence_c[seq_next_rc];
	if (gpr_write) begin
		gpr_fetch_a[wb_rd[5:0]] <= wb_result[31:0];
		gpr_fetch_b[wb_rd[5:0]] <= wb_result[31:0];
		gpr_fetch_c[wb_rd[5:0]] <= wb_result[31:0];
		gpr_sequence_a[wb_rd[5:0]] <= wb_result[31:0];
		gpr_sequence_c[wb_rd[5:0]] <= wb_result[31:0];
	end
	gpr_collision[0] <= gpr_write & (wb_rd[5:0] == fetch_dec.ra);
	gpr_collision[1] <= gpr_write & (wb_rd[5:0] == fetch_dec.rb);
	gpr_collision[2] <= gpr_write & (wb_rd[5:0] == fetch_dec.rc);
	gpr_collision[3] <= gpr_write & (wb_rd[5:0] == seq_next_ra);
	gpr_collision[4] <= gpr_write & (wb_rd[5:0] == seq_next_rc);
	gpr_collision_value <= wb_result[31:0];
end
wire [31:0] id_reg_a = (gpr_write & (wb_rd[5:0] == id_uop.ra)) ? wb_result[31:0] :
    gpr_held_ac ? gpr_held_a_value :
    gpr_from_sequence ? (gpr_collision[3] ? gpr_collision_value : gpr_ram_sa) :
                        (gpr_collision[0] ? gpr_collision_value : gpr_ram_fa);
wire [31:0] id_reg_b = (gpr_write & (wb_rd[5:0] == id_uop.rb)) ? wb_result[31:0] :
    gpr_held_b ? gpr_held_b_value :
    gpr_collision[1] ? gpr_collision_value : gpr_ram_fb;
wire [31:0] id_reg_c = (gpr_write & (wb_rd[5:0] == id_uop.rc)) ? wb_result[31:0] :
    gpr_held_ac ? gpr_held_c_value :
    gpr_from_sequence ? (gpr_collision[4] ? gpr_collision_value : gpr_ram_sc) :
                        (gpr_collision[2] ? gpr_collision_value : gpr_ram_fc);
always_ff @(posedge clk) begin
	gpr_held_a_value <= id_reg_a;
	gpr_held_b_value <= id_reg_b;
	gpr_held_c_value <= id_reg_c;
	gpr_held_ac <= ~(fetch_deliver | gpr_seq_take);
	gpr_held_b <= ~fetch_deliver;
	gpr_from_sequence <= ~fetch_deliver;
	if (reset) begin
		gpr_held_ac <= 1'b0;
		gpr_held_b <= 1'b0;
		gpr_from_sequence <= 1'b0;
	end
end
wire [31:0] id_a = id_uop.ra_rd ? id_reg_a : 32'd0;
wire [31:0] id_b = id_uop.b_imm ? id_uop.imm : id_reg_b;
wire [31:0] id_c = id_reg_c;

// Resolve a speculative integer operand in program order: architectural
// state/WB, MEM, the outstanding EX result, then each completed younger
// ALU result. A younger write supersedes an older unavailable value. The
// latest bits give one matching writer per register, so selection is a
// parallel masked OR rather than eight cascaded value multiplexers.
function automatic logic [7:0] completion_match(input logic [5:0] idx, input logic before_ex);
	for (int n = 0; n < 8; n++)
		completion_match[n] = (before_ex ? completion_latest_older[n] : completion_latest_younger[n]) &
		                      (completion_queue[n].rd == idx);
endfunction
function automatic logic [32:0] completion_read(input logic [5:0] idx, input logic [31:0] rf_value);
	logic [32:0] value;
	logic [7:0] writer_mask;
	logic [31:0] queued_value;
	begin
		value = {1'b0, rf_value};
		if (mem_valid & mem_rd_wr & (mem_rd == {1'b0, idx}))
			value = {mem_load, mem_result[31:0]};
		writer_mask = completion_match(idx, 1'b1);
		queued_value = '0;
		for (int n = 0; n < 8; n++) queued_value |= completion_queue[n].value & {32{writer_mask[n]}};
		if (|writer_mask) value = {1'b0, queued_value};
		if (completion_exec_valid & writer_mask[completion_exec_slot])
			value = {1'b0, completion_result};
		if (ex_valid & ex_dec.rd_wr & (ex_dec.rd == idx)) value[32] = 1'b1;
		writer_mask = completion_match(idx, 1'b0);
		queued_value = '0;
		for (int n = 0; n < 8; n++) queued_value |= completion_queue[n].value & {32{writer_mask[n]}};
		if (|writer_mask) value = {1'b0, queued_value};
		if (completion_exec_valid & writer_mask[completion_exec_slot])
			value = {1'b0, completion_result};
		completion_read = value;
	end
endfunction
wire [32:0] completion_a = id_completion_ra_rd ? completion_read(id_completion_ra, id_reg_a) : 33'd0;
wire [32:0] completion_b = id_completion_b_imm ? {1'b0, id_uop.imm} :
                           id_completion_rb_rd ? completion_read(id_completion_rb, id_reg_b) : 33'd0;
wire completion_eligible = id_completion_simple & id_first & ~id_isi &
    (id_pred == id_pc + 32'd4);
wire completion_wait = ex_valid & ~x_pre & ~ex_stall & ~ex_done &
    ((ex_dec.unit == UNIT_MUL) | (ex_dec.unit == UNIT_DIV) | (ex_dec.unit == UNIT_FPU));
assign completion_push = id_valid & completion_eligible & completion_wait &
    (completion_count < 4'd8) &
    ~completion_a[32] & ~completion_b[32] & ~mem_fault & ~reset;
// completion_wait requires ~ex_done, so EX cannot redirect while pushing.
// Only the older MEM fault can cancel this admission. Avoid putting branch
// resolution into queue admission and the following ID/fetch readiness.
DSPPC604_alu completion_alu
(
	.ctl (completion_exec_ctl),
	.a (completion_exec_a),
	.b (completion_exec_b),
	.ca_in (1'b0),
	.result (completion_result),
	/* verilator lint_off PINCONNECTEMPTY */
	.sum (), .ca_out (), .ov_out (), .lt (), .gt (), .eq (), .lt_s (), .lt_u ()
	/* verilator lint_on PINCONNECTEMPTY */
);
assign completion_pop = (completion_older_count != 4'd0) &
                        ~(completion_exec_valid & (completion_exec_slot == completion_head)) &
                        mem_ready & ~mem_fault & ~reset;
always_ff @(posedge clk) begin
	completion_exec_valid <= completion_push;
	if (completion_exec_valid)
		completion_queue[completion_exec_slot].value <= completion_result;
	if (completion_push) begin
		completion_exec_slot <= completion_tail;
		completion_exec_a <= completion_a[31:0];
		completion_exec_b <= completion_b[31:0];
		completion_exec_ctl <= id_uop.ic;
		completion_queue[completion_tail].pc <= id_pc;
		completion_queue[completion_tail].insn <= id_insn;
		completion_queue[completion_tail].rd <= id_uop.rd;
		completion_tail <= completion_tail + 3'd1;
		for (int n = 0; n < 8; n++)
			if (completion_queue[n].rd == id_uop.rd) completion_latest_younger[n] <= 1'b0;
		completion_latest_younger[completion_tail] <= 1'b1;
	end
	if (completion_pop) begin
		completion_head <= completion_head + 3'd1;
		completion_latest_older[completion_head] <= 1'b0;
		completion_older_count <= completion_older_count - 4'd1;
	end
	case ({completion_push, completion_pop})
		2'b10: completion_count <= completion_count + 4'd1;
		2'b01: completion_count <= completion_count - 4'd1;
		default: ;
	endcase
	// The next EX is younger than everything already in the queue. New ALU
	// completions may append while those older entries drain, allowing the
	// next long operation and its independent work to overlap retirement.
	if (ex_leave) begin
		completion_older_count <= completion_count;
		completion_latest_older <= completion_latest_younger;
		completion_latest_younger <= '0;
	end
	if (reset | redir) begin
		completion_exec_valid <= 1'b0;
		completion_head <= 3'd0;
		completion_tail <= 3'd0;
		completion_count <= 4'd0;
		completion_older_count <= 4'd0;
		completion_latest_older <= '0;
		completion_latest_younger <= '0;
	end
end
// Floating-point register numbers sit in fixed fields, so the read does not
// wait for the decoder. Only a store names its register (frS) elsewhere:
// opcodes 52-55, and the indexed forms under opcode 31, where nothing else
// reads a floating-point register.
wire        id_fp_store = (id_insn[31:28] == 4'b1101) | (id_insn[31:26] == 6'd31);
// Read the prospective fetch word at the edge that installs it in ID.
// Three single-read copies give Quartus a simple dual-port RAM per operand.
// Forward a same-edge write/read collision and the current WB value.
wire [31:0] fpr_read_insn = fetch_word.insn;
wire fpr_read_store = (fpr_read_insn[31:28] == 4'b1101) | (fpr_read_insn[31:26] == 6'd31);
wire [4:0] fpr_read_a = fpr_read_insn[20:16];
wire [4:0] fpr_read_b = fpr_read_store ? fpr_read_insn[25:21] : fpr_read_insn[15:11];
wire [4:0] fpr_read_c = fpr_read_insn[10:6];
logic [63:0] fpr_ram_a, fpr_ram_b, fpr_ram_c, fpr_collision_value;
logic [63:0] fpr_held_a, fpr_held_b, fpr_held_c;
logic fpr_held;
logic fpr_collision_a, fpr_collision_b, fpr_collision_c;
wire fpr_write = wb_valid & wb_rd_wr & wb_rd[6];
always_ff @(posedge clk) begin
	fpr_ram_a <= fpr_a[fpr_read_a];
	fpr_ram_b <= fpr_b[fpr_read_b];
	fpr_ram_c <= fpr_c[fpr_read_c];
	if (fpr_write) begin
		fpr_a[wb_rd[4:0]] <= wb_value;
		fpr_b[wb_rd[4:0]] <= wb_value;
		fpr_c[wb_rd[4:0]] <= wb_value;
	end
	fpr_collision_a <= fpr_write & (wb_rd[4:0] == fpr_read_a);
	fpr_collision_b <= fpr_write & (wb_rd[4:0] == fpr_read_b);
	fpr_collision_c <= fpr_write & (wb_rd[4:0] == fpr_read_c);
	fpr_collision_value <= wb_value;
end
wire [4:0] id_frb = id_fp_store ? id_insn[25:21] : id_insn[15:11];
wire [63:0] id_fa = (fpr_write & (wb_rd[4:0] == id_insn[20:16])) ? wb_value :
                   fpr_held ? fpr_held_a :
                   fpr_collision_a ? fpr_collision_value : fpr_ram_a;
wire [63:0] id_fb = (fpr_write & (wb_rd[4:0] == id_frb)) ? wb_value :
                   fpr_held ? fpr_held_b :
                   fpr_collision_b ? fpr_collision_value : fpr_ram_b;
wire [63:0] id_fc = (fpr_write & (wb_rd[4:0] == id_insn[10:6])) ? wb_value :
                   fpr_held ? fpr_held_c :
                   fpr_collision_c ? fpr_collision_value : fpr_ram_c;

// The RAM reads the prospective fetch word without ID admission on its
// address path. Save the ID operands if it stays put; keep WB forwarding
// live and capture it so a held instruction retains committed writes.
always_ff @(posedge clk) begin
	fpr_held <= ~fetch_deliver;
	// A new ID word selects its fresh RAM sample instead. Its predecessor's
	// saved operands are unused, so capturing them needs no admission enable.
	fpr_held_a <= id_fa;
	fpr_held_b <= id_fb;
	fpr_held_c <= id_fc;
	if (reset) fpr_held <= 1'b0;
end

always_ff @(posedge clk) begin
	if (id_leave) id_valid <= 1'b0;
	if (fetch_deliver) begin
		id_valid    <= 1'b1;
		id_pc       <= fetch_word.pc;
		id_insn     <= fetch_word.isi ? 32'd0 : fetch_word.insn;
		id_completion_ra <= fetch_dec.ra;
		id_completion_rb <= fetch_dec.rb;
		id_completion_ra_rd <= fetch_dec.ra_rd;
		id_completion_rb_rd <= fetch_dec.rb_rd;
		id_completion_b_imm <= fetch_dec.b_imm;
		id_completion_simple <= fetch_completion_simple;
		id_pred     <= fetch_word.pred;
		// Branch BI is a fixed instruction field. Decode its one-hot selector
		// before ID, leaving an AND/reduction on the preceding CR result path.
		id_cr_select <= 32'h80000000 >> fetch_word.insn[20:16];
		id_btb      <= fetch_word.btb;
		id_way      <= fetch_word.way;
		id_cnt      <= fetch_word.cnt;
		id_isi      <= fetch_word.isi;
		id_isi_info <= fetch_word.info;
	end
	if (reset | redir) id_valid <= 1'b0;
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

wire [63:0] fop_a = ffa_mem ? mem_result : ffa_wb ? wb_value : ex_fa;
wire [63:0] fop_b = ffb_mem ? mem_result : ffb_wb ? wb_value : ex_fb;
wire [63:0] fop_c = ffc_mem ? mem_result : ffc_wb ? wb_value : ex_fc;

// their classes, beside the operands: for a single still as lfs loaded it,
// from the single's own fields, so the conversion is not in front of them
// (MEM's result forwarded to an FP operation is never a load's: ex_stall)
fp_cls_t wb_cls, mem_cls, fcls_a, fcls_b, fcls_c;
assign wb_cls  = wb_fsgl ? fp_classify_single(wb_result[31:0]) : fp_classify(wb_result);
assign mem_cls = fp_classify(mem_result);
assign fcls_a  = ffa_mem ? mem_cls : ffa_wb ? wb_cls : fp_classify(ex_fa);
assign fcls_b  = ffb_mem ? mem_cls : ffb_wb ? wb_cls : fp_classify(ex_fb);
assign fcls_c  = ffc_mem ? mem_cls : ffc_wb ? wb_cls : fp_classify(ex_fc);

// a load's data is not there until it reaches WB
wire completion_dependency =
    ((ex_dec.ra_rd & (|completion_match(ex_dec.ra, 1'b1))) |
     (ex_use_b & (|completion_match(ex_dec.rb, 1'b1))) |
     (ex_dec.rc_rd & (|completion_match(ex_dec.rc, 1'b1))));
assign ex_stall = completion_dependency | (mem_load & (fa_mem | fb_mem | fc_mem | ffa_mem | ffb_mem | ffc_mem));

// ---- integer unit ----------------------------------------------------------
wire is_int = (ex_dec.unit == UNIT_ALU) | (ex_dec.unit == UNIT_MUL) | (ex_dec.unit == UNIT_DIV);

logic        int_resp;
logic [31:0] int_result;
logic [31:0] int_sum;                      // the adder alone: the effective address
logic        int_ca;
logic        int_ov;
logic [3:0]  int_cr;
logic        int_lts, int_ltu, int_eq;     // the ALU's compare, for the traps
/* verilator lint_off UNUSEDSIGNAL */
logic        int_ready;
/* verilator lint_on UNUSEDSIGNAL */

// an instruction in EX is cancelled by its own exception or by a fault in MEM
wire ex_flush = (ex_leave & ex_abort) | mem_fault;

DSPPC604_int_unit int_unit
(
	.clk        (clk),
	.reset      (reset),
	.flush      (ex_flush),
	.req_valid  (ex_valid & ~x_pre & ~ex_stall & is_int),
	.req_ready  (int_ready),
	.unit       (ex_dec.unit),
	.ctl        (ex_dec.ic),
	.a          (op_a),
	.b          (op_b),
	.ca_in      (xer[29]),
	.so_in      (xer[31]),
	.resp_valid (int_resp),
	.resp_ready (mem_ready & ex_order_ready),
	.result     (int_result),
	.sum        (int_sum),
	.ca_out     (int_ca),
	.ov_out     (int_ov),
	.cr_out     (int_cr),
	.cmp_lts    (int_lts),
	.cmp_ltu    (int_ltu),
	.cmp_eq     (int_eq)
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

DSPPC604_fpu #(.OPERAND_REG (FPU_OPERAND_REG)) fpu
(
	.clk        (clk),
	.reset      (reset),
	.flush      (ex_flush),
	.req_valid  (ex_valid & ~x_pre & ~ex_stall & is_fpu),
	.req_ready  (fpu_ready),
	.ctl        (ex_dec.fc),
	.a          (fop_a),
	.b          (fop_b),
	.c          (fop_c),
	.cls_a      (fcls_a),
	.cls_b      (fcls_b),
	.cls_c      (fcls_c),
	.fpscr_in   (fpscr),
	.resp_valid (fpu_resp),
	.resp_ready (mem_ready & ex_order_ready),
	.result     (fpu_result),
	.result_we  (fpu_result_we),
	.fpscr_out  (fpu_fpscr),
	.cr_out     (fpu_cr),
	.fex        (fpu_fex)
);

// ---- the instructions that write FPSCR directly ----------------------------
logic [31:0] fsys_fpscr;
logic [3:0]  fsys_cr;

// FPSCR instructions use only frB's low word. An LFS in WB needs at most
// its lowest three fraction bits and the two highest denormal bits here,
// avoiding full normalization and its variable shift.
function automatic logic [31:0] single_double_low(input logic [31:0] w);
	begin
		if (w[30:23] != 8'd0) single_double_low = {w[2:0], 29'd0};
		else if (w[22]) single_double_low = {w[1:0], 1'b0, 29'd0};
		else if (w[21]) single_double_low = {w[0], 2'b00, 29'd0};
		else single_double_low = 32'd0;
	end
endfunction
wire [31:0] wb_fp_low = wb_fsgl ? single_double_low(wb_result[31:0]) : wb_result[31:0];

// Apply each operand before selecting its FPSCR result, placing late
// forwarding-tag comparison after FEX summarization instead of before it.
(* keep = "true" *) wire [31:0] fsys_mem_next, fsys_wb_next, fsys_held_next;
DSPPC604_fpscr fpscr_mem_ops
(
	.op         (ex_dec.sys),
	.insn       (ex_insn),
	.fpscr      (fpscr),
	.frb        (mem_result[31:0]),
	.fpscr_next (fsys_mem_next),
	/* verilator lint_off PINCONNECTEMPTY */
	.cr_field   ()
	/* verilator lint_on PINCONNECTEMPTY */
);
DSPPC604_fpscr fpscr_wb_ops
(
	.op         (ex_dec.sys),
	.insn       (ex_insn),
	.fpscr      (fpscr),
	.frb        (wb_fp_low),
	.fpscr_next (fsys_wb_next),
	/* verilator lint_off PINCONNECTEMPTY */
	.cr_field   ()
	/* verilator lint_on PINCONNECTEMPTY */
);
DSPPC604_fpscr fpscr_held_ops
(
	.op         (ex_dec.sys),
	.insn       (ex_insn),
	.fpscr      (fpscr),
	.frb        (ex_fb[31:0]),
	.fpscr_next (fsys_held_next),
	.cr_field   (fsys_cr)
);
assign fsys_fpscr = ffb_mem ? fsys_mem_next : ffb_wb ? fsys_wb_next : fsys_held_next;

assign ex_done = x_pre | (~ex_stall & (is_int ? int_resp : is_fpu ? fpu_resp : 1'b1));
// These outer guards already qualify mu_valid. For a non-aborted memory
// operation, mu_ready is therefore sufficient here; using mu_accept repeats
// the same completion/backpressure guards in the EX-leave timing cone.
assign ex_leave = ex_valid & ex_done & mem_ready & ex_order_ready & ~mem_fault &
                  (ex_abort | ~ex_mem_access | mu_ready);

// ---- branch ----------------------------------------------------------------
wire        is_br    = (ex_dec.br != BR_NONE);
wire        cr_bit   = |(cr & ex_cr_select);
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
// Only an instruction's last operation decides. An exception goes to its
// vector; mtmsr, rfi and anything that changes how addresses translate
// (segment registers, BATs, SDR1, tlbie) always refetch, because what
// follows them was fetched under the old state. A fault in MEM redirects
// too, and the instruction in EX goes with it.
wire        is_sys    = ~is_int & ~is_fpu;
wire        is_rfi    = is_sys & (ex_dec.sys == SYS_RFI);
wire        is_mtmsr  = is_sys & (ex_dec.sys == SYS_MTMSR);
wire        is_mtspr  = is_sys & (ex_dec.sys == SYS_MTSPR);
wire        is_tlbie  = is_sys & (ex_dec.sys == SYS_TLBIE);
wire        is_xlate  = is_tlbie | (is_sys & ((ex_dec.sys == SYS_MTSR) | (ex_dec.sys == SYS_ISYNC))) |
                        (is_mtspr & ((ex_dec.spr == 10'd25) | (ex_dec.spr[9:4] == 6'b100001) | (ex_dec.spr == 10'd1008)));
wire [31:0] next_pc   = is_rfi ? {srr0[31:2], 2'b00} : br_taken ? br_target : ex_pc4;
wire [31:0] vec_base  = {{12{msr[MSR_IP]}}, 8'h00, 12'h000};
assign redir_pc = mem_fault ? (vec_base | (mem_irq ? (ext_irq ? 32'h500 : 32'h900) :
                                                         (mu_falign ? 32'h600 : 32'h300))) :
                  ex_exc    ? (vec_base | {20'd0, exc_vector}) : next_pc;
wire   ex_final = ex_leave & ~ex_exc & ex_last;
assign ras_push = ex_final & br_taken & ex_dec.br_lk;
assign ras_pop = ex_final & br_taken & (ex_dec.br == BR_LR) & ~ex_dec.br_lk & (ras_ccount != 4'd0);
assign redir    = mem_fault |
                  (ex_leave & (ex_exc | (ex_last & (is_rfi | is_mtmsr | is_xlate | (next_pc != ex_pred)))));

// Teach the branch target buffer: a taken branch is entered or strengthened,
// one that was not taken is weakened, and an entry that fired for something
// that is no branch at all is removed.
always_comb begin
	btb_widx = btb_index(ex_pc);
	btb_we   = 1'b0;
	btb_wtgt = 1'b0;
	btb_clr  = 1'b0;
	btb_wcnt = 2'd2;
	if (ex_final & ~is_rfi) begin
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

// ---- special-purpose registers ----------------------------------------------
// The set a 604 has (measured: mfspr of all 1,024 numbers in both modes).
// 268 and 269 read the time base through mfspr as well as mftb, in user mode
// too; they cannot be written.
logic        spr_known;
logic [31:0] spr_rdata;

always_comb begin
	spr_known = 1'b1;
	spr_rdata = 32'd0;
	case (ex_dec.spr)
		10'd1:    spr_rdata = xer;
		10'd8:    spr_rdata = lr;
		10'd9:    spr_rdata = ctr;
		10'd18:   spr_rdata = dsisr;
		10'd19:   spr_rdata = dar;
		10'd22:   spr_rdata = dec_r;
		10'd25:   spr_rdata = sdr1;
		10'd26:   spr_rdata = srr0;
		10'd27:   spr_rdata = srr1;
		10'd268:  begin spr_rdata = tbl; spr_known = (ex_dec.sys == SYS_MFSPR); end
		10'd269:  begin spr_rdata = tbu; spr_known = (ex_dec.sys == SYS_MFSPR); end
		10'd272, 10'd273, 10'd274, 10'd275: spr_rdata = sprg[ex_dec.spr[1:0]];
		10'd282:  spr_rdata = ear;
		10'd284:  spr_rdata = tbl;
		10'd285:  spr_rdata = tbu;
		10'd287:  spr_rdata = PVR;
		10'd952:  spr_rdata = mmcr0;
		10'd953:  spr_rdata = pmc1;
		10'd954:  spr_rdata = pmc2;
		10'd955:  spr_rdata = sia;
		10'd959:  spr_rdata = sda;
		10'd1008: spr_rdata = hid0;
		10'd1010: spr_rdata = iabr;
		10'd1013: spr_rdata = dabr;
		10'd1023: spr_rdata = {28'd0, pir};
		default: begin
			if (ex_dec.spr[9:4] == 6'b100001) spr_rdata = bat[ex_dec.spr[3:0]];   // 528-543
			else spr_known = 1'b0;
		end
	endcase
end

// segment register number: in the instruction, or the top of operand B
wire [3:0] sr_idx = ex_dec.rb_rd ? op_b[31:28] : ex_insn[19:16];

// ---- exceptions -------------------------------------------------------------
wire fp_trap_on = msr[MSR_FE0] | msr[MSR_FE1];

// conditions that do not need the instruction to execute
wire irq_ext  = ex_first & msr[MSR_EE] & ext_irq;
wire irq_dec  = ex_first & msr[MSR_EE] & dec_pending & ~ext_irq;
wire x_isi    = ex_isi;
wire fpe_pend = ex_first & fpscr[30] & fp_trap_on;      // FEX was already set when traps were enabled
// an SPR the 604 does not have is an illegal instruction in either mode
// (measured; the manual's "privileged in user mode" is not what the chip does)
wire x_spr    = is_sys & ((ex_dec.sys == SYS_MFSPR) | (ex_dec.sys == SYS_MTSPR)) & ~spr_known;
wire x_priv   = ex_dec.priv & msr[MSR_PR] & ~x_spr;
wire x_ill    = ex_ill | x_spr;
wire x_fpu    = ex_dec.fp_use & ~msr[MSR_FP];
assign x_pre  = irq_ext | irq_dec | x_isi | fpe_pend | x_priv | x_ill | x_fpu;

// conditions that come out of executing it: a trap instruction compares in
// the ALU and its TO field tests the flags
wire        trap_hit = (ex_dec.bo[4] & int_lts) | (ex_dec.bo[3] & ~int_lts & ~int_eq) |
                       (ex_dec.bo[2] & int_eq) |
                       (ex_dec.bo[1] & int_ltu) | (ex_dec.bo[0] & ~int_ltu & ~int_eq);
wire x_sc     = is_sys & (ex_dec.sys == SYS_SC);
wire x_trap   = is_int & ex_dec.trap & trap_hit;
// the effective address: the adder's sum on its own (every memory access is
// an add), ahead of the result mux the rotator feeds too; for dcbz, the line
wire        ex_zero = (ex_dec.cop == CK_ZERO);
wire [31:0] ex_ea   = ex_zero ? {int_sum[31:5], 5'b00000} : int_sum;

// the 604 does not perform these accesses unless they are word-aligned
wire x_align_w = (ex_dec.mem_rd | ex_dec.mem_wr) &
                 ((ex_dec.seq == SEQ_MULTI) | ex_dec.mem_fp | (ex_dec.resv != RESV_NONE)) &
                 (int_sum[1:0] != 2'b00);
// ... and dcbz takes an alignment exception while the data cache is
// disabled or locked (HID0[DCE], HID0[DLOCK]); the same for a write-through
// or cache-inhibited page is decided in MEM, where the page is known
wire x_align_z = ex_zero & (~hid0[14] | hid0[12]);
// ... nor a string operation that is not word-aligned and crosses a 4 KB
// boundary, or is word-aligned and crosses a 256 MB boundary (604 manual
// 2.3.4.3); checked on its first access, which carries the whole count.
// The 4 KB test is made from the operands beside the adder (every access is
// a plain A + B), not from its sum, which put the adder in series with it.
// The operation crosses when its last byte is in another page than its
// first: with t = a[11:0] + b[11:0] + (count - 1) and c the carry out of
// a[11:0] + b[11:0], the last byte's offset in the first byte's page is
// t - 4096 c, and t[12] differs from c exactly when that reaches 4096. The
// three-input sum is written as a 3:2 compression and one adder, so that
// it is one carry chain beside the other and not two in series. It is
// made once for each place A can come from (the register, MEM, WB) and
// the forwarding selects choose among the three results, so that the
// operand mux is not in front of it; B is the sequencer's displacement,
// an immediate, so ex_b is B.
function automatic logic str_cross(input logic [11:0] a, input logic [11:0] b, input logic [6:0] last);
	logic [11:0] x, k;
	logic [12:0] lo;
	logic [13:0] t;
	begin
		x  = a ^ b ^ {5'd0, last};
		k  = (a & b) | ((a | b) & {5'd0, last});
		lo = {1'b0, a} + {1'b0, b};
		t  = {2'b00, x} + {1'b0, k, 1'b0};
		str_cross = t[12] ^ lo[12];
	end
endfunction
wire [6:0]  str_last  = ex_dec.str_bytes - 7'd1;
wire        str_4k    = fa_mem ? str_cross(mem_result[11:0], ex_b[11:0], str_last) :
                        fa_wb  ? str_cross(wb_result[11:0],  ex_b[11:0], str_last) :
                                 str_cross(ex_a[11:0],       ex_b[11:0], str_last);
wire        x_align_s = (ex_dec.str_bytes != 7'd0) & str_4k &
                        ((int_sum[1:0] != 2'b00) | (&int_sum[27:12]));
wire x_align  = x_align_w | x_align_s | x_align_z;
// eciwx and ecowx: a DSI, this machine having no external control facility
wire x_ecx    = ex_dec.mem_ext;

assign ex_abort = x_pre | x_sc | x_trap | x_align | x_ecx;   // the instruction has no effect

// an enabled floating-point exception this instruction raises itself: it
// completes, then traps
wire x_fpen   = ~ex_abort & ex_dec.fpscr_wr & fpscr_next[30] & fp_trap_on;
assign ex_exc = ex_abort | x_fpen;

logic [31:0] exc_info;      // the cause bits of SRR1

always_comb begin
	exc_info = 32'd0;
	if (irq_ext)       exc_vector = 12'h500;
	else if (irq_dec)  exc_vector = 12'h900;
	else if (x_isi)    begin exc_vector = 12'h400; exc_info = ex_isi_info; end
	// a pending exception is taken at a later instruction: SRR1[15] says so (measured)
	else if (fpe_pend) begin exc_vector = 12'h700; exc_info = 32'h00110000; end
	else if (x_priv)   begin exc_vector = 12'h700; exc_info = 32'h00040000; end
	else if (x_ill)    begin exc_vector = 12'h700; exc_info = 32'h00080000; end
	else if (x_fpu)    exc_vector = 12'h800;
	else if (x_sc)     exc_vector = 12'hC00;
	else if (x_trap)   begin exc_vector = 12'h700; exc_info = 32'h00020000; end
	else if (x_align)  exc_vector = 12'h600;
	else if (x_ecx)    exc_vector = 12'h300;
	else               begin exc_vector = 12'h700; exc_info = 32'h00100000; end   // x_fpen
end

// What the alignment handler is told about the instruction. The opcode
// fields are the architecture's. In the register fields a 604 puts, not rD
// and rA as the architecture says, rD and rD - 1 (8 and 7 for dcbz, whose
// rD field means nothing): measured for lmw, stmw, lfd, stfd, lwarx, stwcx.
// and dcbz; not for the update forms.
function automatic logic [31:0] align_info(input logic [31:0] insn);
	logic [4:0] rd;
	begin
		rd = (insn[31:26] == 6'd31 && insn[10:1] == 10'd1014) ? 5'd8 : insn[25:21];
		align_info = (insn[31:26] == 6'd31)
			? {15'd0, insn[2:1], insn[6],  insn[10:7],  rd, rd - 5'd1}
			: {15'd0, 2'b00,     insn[26], insn[30:27], rd, rd - 5'd1};
	end
endfunction
wire [31:0] align_dsisr = align_info(ex_insn);
// ... and the DSI handler about eciwx/ecowx: DSISR[11], and [6] for a store
wire [31:0] ecx_dsisr = 32'h00100000 | (ex_dec.mem_wr ? 32'h02000000 : 32'd0);

// MSR on exception entry: interrupts, translation, floating point and user
// mode off; ME, IP and ILE kept; LE takes ILE
wire [31:0] msr_exc = (msr & 32'h00011040) | {31'd0, msr[16]};

// ---- the reservation ---------------------------------------------------------
// Set when lwarx's load completes, cleared when stwcx.'s store completes,
// with no address compare (as the 604 and dingusppc). An exception leaves it
// alone. stwcx. in EX decides on the value as of the end of this cycle, so a
// lwarx completing in MEM at the same time counts.
logic resv_valid;
logic stwcx_ok;        // the last stwcx. found the reservation and stored
logic mem_resv_set;    // the access in MEM is lwarx's
logic mem_resv_clr;    // ... stwcx.'s, and was made

wire  mem_done_ok = mem_leave & ~mem_fault;
wire  resv_next   = (resv_valid | (mem_done_ok & mem_resv_set)) & ~(mem_done_ok & mem_resv_clr);
wire  stwcx_store = (ex_dec.resv == RESV_STORE) & resv_next;
assign ex_mem_access = ex_dec.mem_rd | (ex_dec.mem_wr & ((ex_dec.resv != RESV_STORE) | stwcx_store));

logic [31:0] cr_next;
logic [31:0] xer_next;
logic [31:0] lr_next;
logic [31:0] ctr_next;
logic [31:0] msr_next;
logic [31:0] sys_result;

always_comb begin
	cr_next    = cr;
	xer_next   = xer;
	lr_next    = lr;
	ctr_next   = ctr;
	fpscr_next = fpscr;
	msr_next   = msr;
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
			SYS_MFSPR: sys_result = spr_rdata;
			SYS_MTSPR: begin
				// the registers kept here; the rest are written below
				case (ex_dec.spr)
					10'd1:   xer_next = op_a & XER_MASK;
					10'd8:   lr_next  = op_a;
					10'd9:   ctr_next = op_a;
					default: ;
				endcase
			end
			SYS_MFMSR: sys_result = msr;
			SYS_MTMSR: msr_next = op_a & MSR_MASK;
			SYS_RFI:   msr_next = ((msr & ~SRR1_MASK) | (srr1 & SRR1_MASK)) & MSR_MASK;
			SYS_MFSR:  sys_result = sr[sr_idx];
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
			SYS_STWCX_CR: cr_next = cr_insert(cr, 3'd0, {2'b00, stwcx_ok, xer[31]});
			default: ;
		endcase

		if (br_count)      ctr_next = ctr_m1;
		if (ex_dec.br_lk)  lr_next  = ex_pc4;
	end
end

// The value for the register this operation writes, and which register.
// The upper word mffs delivers is undefined; FFF80000 is what the 604 puts
// there (measured, as for fctiw).
wire [63:0] ex_result = is_fpu ? fpu_result :
                        is_int ? {32'd0, int_result} :
                        (ex_dec.sys == SYS_MFFS) ? {32'hFFF80000, fpscr} : {32'd0, sys_result};
wire [6:0]  ex_rd     = ex_dec.frd_wr ? {2'b10, ex_dec.frd} : {1'b0, ex_dec.rd};
wire        ex_rd_wr  = ex_dec.rd_wr | (ex_dec.frd_wr & (~is_fpu | fpu_result_we));

// A forwarded LFS still carries its original single in WB. STFS can use that
// word directly: converting to double and back preserves every single bit.
// Keep the conversion input free of that WB path so synthesis can remove the
// single-to-double normalization from the store's timing cone. MEM forwarding
// has priority; unavailable MEM loads already hold EX until their WB result.
wire [63:0] store_fp_double = ffb_mem ? mem_result :
                             (ffb_wb & ~wb_fsgl) ? wb_result : ex_fb;
wire [31:0] store_fp_single = (ffb_wb & wb_fsgl & ~ffb_mem) ? wb_result[31:0] :
                             fp_double_to_single(store_fp_double);

// Doubleword stores retain the full converted forwarding value.
wire [63:0] ex_wdata  = ~ex_dec.mem_fp   ? {32'd0, op_c} :
                        ex_dec.mem_fsgl  ? {32'd0, store_fp_single} : fop_b;

// MTSR/MTSPR have no memory descriptor or long-unit response. Their
// writes use ordinary capacity directly, then precise abort/fault/order
// guards, instead of the generic EX-leave mux feeding wide register banks.
wire sys_reg_write = is_sys & ((ex_dec.sys == SYS_MTSR) | (ex_dec.sys == SYS_MTSPR));
wire sys_write_commit = ex_valid & sys_reg_write & ~ex_stall & mem_capacity &
                        ex_order_ready & ~mem_fault & ~ex_abort;

always_ff @(posedge clk) begin
	if (ex_leave) ex_valid <= 1'b0;

	if (id_to_ex) begin
		ex_valid <= ~redir;
		ex_pc    <= id_pc;
		ex_insn  <= id_insn;
		ex_dec   <= id_uop;
		ex_ill   <= ~id_dec.valid;
		ex_isi   <= id_isi;
		ex_isi_info <= id_isi_info;
		ex_first <= id_first;
		ex_last  <= id_last | ~id_dec.valid;
		ex_pred  <= id_pred;
		ex_btb   <= id_btb;
		// The preceding EX commits CR at this edge; MEM and queued ALUs cannot
		// change it. Select the branch condition from that registered state in
		// EX instead of appending selection to the predecessor's CR datapath.
		ex_cr_select <= id_cr_select;
		ex_way   <= id_way;
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
		if (ffa_wb & ~ffa_mem) ex_fa <= wb_value;
		if (ffb_wb & ~ffb_mem) ex_fb <= wb_value;
		if (ffc_wb & ~ffc_mem) ex_fc <= wb_value;
	end

	// time base and decrementer
	if (tb_tick) begin
		{tbu, tbl} <= {tbu, tbl} + 64'd1;
		dec_r      <= dec_r - 32'd1;
		if (dec_r == 32'd0) dec_pending <= 1'b1;
	end

	// the reservation
	resv_valid <= resv_next;
	if (ex_leave & ~ex_abort & (ex_dec.resv == RESV_STORE)) stwcx_ok <= stwcx_store;

	// commit CR, XER, LR, CTR, FPSCR, MSR and the SPRs
	if (ex_leave & ~ex_abort) begin
		cr    <= cr_next;
		xer   <= xer_next;
		lr    <= lr_next;
		ctr   <= ctr_next;
		fpscr <= fpscr_next;
		msr   <= msr_next;

	end

	if (sys_write_commit) begin
		if (ex_dec.sys == SYS_MTSR) sr[sr_idx] <= op_a;

		// the bits each register keeps are the measured ones (7300 run, two
		// patterns written to and read back from every supervisor register)
		if (ex_dec.sys == SYS_MTSPR) begin
			case (ex_dec.spr)
				10'd18:   dsisr <= op_a;
				10'd19:   dar   <= op_a;
				10'd22:   begin
					dec_r <= op_a;
					if (~dec_r[31] & op_a[31]) dec_pending <= 1'b1;
				end
				10'd25:   sdr1  <= op_a & 32'hFFFF01FF;     // HTABORG, HTABMASK
				10'd26:   srr0  <= op_a & 32'hFFFFFFFC;
				10'd27:   srr1  <= op_a;
				10'd272, 10'd273, 10'd274, 10'd275: sprg[ex_dec.spr[1:0]] <= op_a;
				10'd282:  ear   <= op_a & 32'h8000003F;     // E, RID
				10'd284:  tbl   <= op_a;
				10'd285:  tbu   <= op_a;
				10'd952:  mmcr0 <= op_a;
				10'd953:  pmc1  <= op_a;
				10'd954:  pmc2  <= op_a;
				10'd955:  sia   <= op_a;
				10'd959:  sda   <= op_a;
				10'd1008: hid0  <= op_a & ~32'h00000C00;    // ICFI and DCFI act once and clear
				10'd1010: iabr  <= op_a;
				10'd1013: dabr  <= op_a;
				10'd1023: pir   <= op_a[3:0];
				default:  if (ex_dec.spr[9:4] == 6'b100001)
					// upper: BEPI, BL, Vs, Vp; lower: BRPN, WIMG, PP (W and G kept by the IBATs too)
					bat[ex_dec.spr[3:0]] <= op_a & (ex_dec.spr[0] ? 32'hFFFE007B : 32'hFFFE1FFF);
			endcase
		end
	end

	// exception entry
	if (ex_leave & ex_exc) begin
		srr0 <= x_sc ? ex_pc4 : ex_pc;
		srr1 <= (msr & SRR1_MASK) | exc_info;
		msr  <= msr_exc;
		if ((x_align | x_ecx) & ~x_pre) begin
			dar   <= int_sum;
			dsisr <= x_align ? align_dsisr : ecx_dsisr;
		end
		if (irq_dec) dec_pending <= 1'b0;
	end

	// ... for the access in MEM that cannot be made (EX did not commit): a
	// DSI, or the alignment exception of dcbz on a page it may not touch
	if (mem_fault) begin
		ex_valid <= 1'b0;
		srr0  <= mem_pc;
		srr1  <= msr & SRR1_MASK;
		msr   <= msr_exc;
		if (mem_dsi) begin
			dar   <= mu_dar;
			dsisr <= mu_falign ? align_info(mem_insn) : mu_dsisr;
		end
		if (mem_irq & ~ext_irq) dec_pending <= 1'b0;
	end

	if (reset) begin
		ex_valid    <= 1'b0;
		resv_valid  <= 1'b0;
		cr          <= 32'd0;
		xer         <= 32'd0;
		lr          <= 32'd0;
		ctr         <= 32'd0;
		fpscr       <= 32'd0;
		msr         <= 32'h00000040;   // exception vectors at FFFxxxxx
		dec_pending <= 1'b0;
		dec_r       <= 32'hFFFFFFFF;
		tbl         <= 32'd0;
		tbu         <= 32'd0;
		hid0        <= 32'd0;
	end
end

// ============================================================================
//  MEM
// ============================================================================
logic        mu_resp;
logic        mu_fault;
logic        mu_falign;     // ... and it is an alignment exception, not a DSI
logic [63:0] mu_rdata;
logic [31:0] mu_dsisr;
logic [31:0] mu_dar;
logic [31:0] mu_ea;

DSPPC604_mem_unit mem_unit
(
	.clk         (clk),
	.reset       (reset | mem_irq),
	.req_valid   (mu_valid),
	.req_ready   (mu_ready),
	.pending_ungranted (mu_pending),
	.we          (ex_dec.mem_wr),
	.kind        (ex_dec.cop),
	.addr        (ex_ea),
	.nbytes      (ex_dec.mem_n),
	.sext        (ex_dec.mem_sext),
	.brev        (ex_dec.mem_brev),
	.ljust       (ex_dec.mem_ljust),
	.wdata       (ex_wdata),
	.resp_valid  (mu_resp),
	.resp_fault  (mu_fault),
	.rdata       (mu_rdata),
	.dbus_req    (mu_req),
	.dbus_we     (mu_we),
	.dbus_kind   (mu_kind),
	.dbus_addr   (mu_addr),
	.dbus_ea     (mu_ea),
	.dbus_be     (mu_be),
	.dbus_wdata  (mu_wdata),
	.dbus_wide   (mu_wide),
	.dbus_wdata_next (mu_wdata_next),
	.dbus_gnt    (mu_gnt),
	.dbus_rvalid (mu_rvalid),
	.dbus_fault  (mu_bfault),
	.dbus_rdata  (mu_bus_rdata),
	.dbus_rwide  (mu_rwide),
	.dbus_rdata_next (mu_rdata_next)
);

assign mu_valid = ex_valid & ex_done & mem_ready & ex_order_ready & ~mem_fault & ~ex_abort & ex_mem_access;
assign mu_accept = mu_valid & mu_ready;
// Before its first grant, a saved descriptor has no memory side effect.
// Preserve the old interrupt boundary while decoupling EX admission from
// translation/cache readiness. Later micro-ops finish before an interrupt.
assign mem_irq = mem_valid & mem_first & mu_pending & msr[MSR_EE] & (ext_irq | dec_pending);
assign mem_leave = mem_valid & (~(mem_load | mem_store) | mu_resp | mem_irq);
assign mem_dsi = mem_valid & mu_resp & mu_fault;
assign mem_fault = mem_dsi | mem_irq;

DSPPC604_mmu #(.TLB_BITS (TLB_BITS), .CANDIDATE_D_ADDR (1'b1)) mmu
(
	.clk         (clk),
	.reset       (reset),
	.msr_ir      (msr[MSR_IR]),
	.msr_dr      (msr[MSR_DR]),
	.msr_pr      (msr[MSR_PR]),
	.bat         (bat),
	.sr          (sr),
	.sr_changed  (ex_leave & ~ex_abort & is_sys & (ex_dec.sys == SYS_MTSR)),
	.sdr1        (sdr1),
	.tlbie       (ex_leave & ~ex_abort & is_tlbie),
	.tlbie_ea    (op_b),
	.i_req       (if_req),
	.i_addr      (if_addr),
	.i_cancel    (redir),
	.i_addr_next (pred_pc),
	.i_gnt       (if_gnt),
	.i_rvalid    (if_rvalid),
	.i_rdata     (if_rdata),
	.i_fault     (if_fault),
	.i_srr1      (if_srr1),
	.ibus_req    (ib_req),
	.ibus_addr   (ib_addr),
	.ibus_ci     (ib_ci),
	.ibus_gnt    (ib_gnt),
	.ibus_rvalid (ib_rvalid),
	.ibus_rdata  (ib_rdata),
	.d_pre       (ex_leave & ~ex_abort & (ex_dec.mem_rd | ex_dec.mem_wr)),
	.d_ea_next   (ex_ea),
	.d_req       (mu_req),
	.d_we        (mu_we),
	.d_kind      (mu_kind),
	.d_addr      (mu_addr),
	.d_be        (mu_be),
	.d_wdata     (mu_wdata),
	.d_wide      (mu_wide),
	.d_wdata_next (mu_wdata_next),
	.d_ea        (mu_ea),
	.d_cancel    (redir),
	.d_gnt       (mu_gnt),
	.d_rvalid    (mu_rvalid),
	.d_rdata     (mu_bus_rdata),
	.d_rwide     (mu_rwide),
	.d_rdata_next (mu_rdata_next),
	.d_fault     (mu_bfault),
	.d_falign    (mu_falign),
	.d_dsisr     (mu_dsisr),
	.d_dar       (mu_dar),
	.dbus_req    (db_req),
	.dbus_we     (db_we),
	.dbus_kind   (db_kind),
	.dbus_addr   (db_addr),
	.dbus_be     (db_be),
	.dbus_wdata  (db_wdata),
	.dbus_wide   (db_wide),
	.dbus_wdata_next (db_wdata_next),
	.dbus_ci     (db_ci),
	.dbus_wt     (db_wt),
	.dbus_gnt    (db_gnt),
	.dbus_rvalid (db_rvalid),
	.dbus_rdata  (db_rdata),
	.dbus_rwide  (db_rwide),
	.dbus_rdata_next (db_rdata_next)
);

// ============================================================================
//  The caches, the memory port, the snoop port
// ============================================================================
// HID0: bits 16-21 are ICE, DCE, ILOCK, DLOCK, ICFI, DCFI
wire hid0_ice = hid0[15], hid0_dce = hid0[14], hid0_ilock = hid0[13], hid0_dlock = hid0[12];
// The flash invalidations start the cycle after the write commits: the
// caches take inval_all combinationally into their grant, and the commit
// decision (ex_abort, with its fan-out) must not reach a RAM's address
// through it. Nothing can see the difference: the instruction after the
// mtspr is refetched (is_xlate), and no access is in a cache in that cycle.
wire hid0_wr  = ex_leave & ~ex_abort & is_mtspr & (ex_dec.spr == 10'd1008);
always_ff @(posedge clk) begin
	ic_inval <= hid0_wr & op_a[11];
	dc_inval <= hid0_wr & op_a[10];
	if (reset) begin
		ic_inval <= 1'b0;
		dc_inval <= 1'b0;
	end
end

// An external snoop goes to both caches, each of which answers in its own
// time; the answer goes out when both have. The data cache's icbi goes to
// the instruction cache's snoop port when no external snoop is in progress.
logic ic_snoop_done, dc_snoop_done;
always_ff @(posedge clk) begin
	if (~snoop_req | reset) begin
		ic_snoop_done <= 1'b0;
		dc_snoop_done <= 1'b0;
	end
	else begin
		if (ic_snoop_ack) ic_snoop_done <= 1'b1;
		if (dc_snoop_ack) dc_snoop_done <= 1'b1;
	end
end
// (the icbi is served as soon as the instruction cache's part of an external
// snoop is done, so that a data cache waiting on it cannot hold the snoop up)
wire        ic_ext        = snoop_req & ~ic_snoop_done;
wire        ic_snoop_req  = ic_ext | (dc_inv_req & ~dc_inv_ack_q);
wire        ic_snoop_we   = ic_ext ? snoop_we   : 1'b1;
wire [31:5] ic_snoop_addr = ic_ext ? snoop_addr : dc_inv_addr;
wire        dc_snoop_req  = snoop_req & ~dc_snoop_done;
assign snoop_ack  = snoop_req & (ic_snoop_ack | ic_snoop_done) & (dc_snoop_ack | dc_snoop_done);
// Complete icbi from a registered I-cache acknowledge. Suppress another
// internal snoop while that acknowledge is delivered; an external snoop
// keeps its usual priority and can start in the meantime.
always_ff @(posedge clk) begin
	dc_inv_ack_q <= dc_inv_req & ~ic_ext & ic_snoop_ack;
	if (reset) dc_inv_ack_q <= 1'b0;
end
assign dc_inv_ack = dc_inv_ack_q;

DSPPC604_cache #(.WRITABLE (0)) icache
(
	.clk        (clk),
	.reset      (reset),
	.enable     (hid0_ice),
	.lock       (hid0_ilock),
	.inval_all  (ic_inval),
	.req        (ib_req),
	.we         (1'b0),
	.kind       (CK_WORD),
	.addr       (ib_addr[31:2]),
	.be         (4'b1111),
	.wdata      (32'd0),
	.wide       (1'b0),
	.wdata_next (32'd0),
	.ci         (ib_ci),
	.wt         (1'b0),
	.gnt        (ib_gnt),
	.rvalid     (ib_rvalid),
	.rdata      (ib_rdata),
	/* verilator lint_off PINCONNECTEMPTY */
	.rvalid_wide (),
	.rdata_next (),
	.inv_req    (),
	.inv_addr   (),
	/* verilator lint_on PINCONNECTEMPTY */
	.inv_ack    (1'b0),
	.snoop_req  (ic_snoop_req),
	.snoop_we   (ic_snoop_we),
	.snoop_addr (ic_snoop_addr),
	.snoop_ack  (ic_snoop_ack),
	.mem_req    (im_req),
	.mem_we     (im_we),
	.mem_line   (im_line),
	.mem_addr   (im_addr),
	.mem_be     (im_be),
	.mem_wdata  (im_wdata),
	.mem_ack    (im_ack),
	.mem_rdata  (mem_rdata)
);

DSPPC604_cache #(.WRITABLE (1), .LATE_ANSWER (0)) dcache
(
	.clk        (clk),
	.reset      (reset),
	.enable     (hid0_dce),
	.lock       (hid0_dlock),
	.inval_all  (dc_inval),
	.req        (db_req),
	.we         (db_we),
	.kind       (db_kind),
	.addr       (db_addr),
	.be         (db_be),
	.wdata      (db_wdata),
	.wide       (db_wide),
	.wdata_next (db_wdata_next),
	.ci         (db_ci),
	.wt         (db_wt),
	.gnt        (db_gnt),
	.rvalid     (db_rvalid),
	.rdata      (db_rdata),
	.rvalid_wide (db_rwide),
	.rdata_next (db_rdata_next),
	.inv_req    (dc_inv_req),
	.inv_addr   (dc_inv_addr),
	.inv_ack    (dc_inv_ack),
	.snoop_req  (dc_snoop_req),
	.snoop_we   (snoop_we),
	.snoop_addr (snoop_addr),
	.snoop_ack  (dc_snoop_ack),
	.mem_req    (dm_req),
	.mem_we     (dm_we),
	.mem_line   (dm_line),
	.mem_addr   (dm_addr),
	.mem_be     (dm_be),
	.mem_wdata  (dm_wdata),
	.mem_ack    (dm_ack),
	.mem_rdata  (mem_rdata)
);

// the memory port: data before instructions, a request once started keeps it
logic mem_owner_i;      // the instruction cache's request is on the port
logic mem_busy;
always_ff @(posedge clk) begin
	if (mem_ack) mem_busy <= 1'b0;
	else if (~mem_busy & (dm_req | im_req)) begin
		mem_busy    <= 1'b1;
		mem_owner_i <= ~dm_req;
	end
	if (reset) mem_busy <= 1'b0;
end
// An ACK still belongs to the saved owner after its request drops. Drain
// that level before presenting another request, and deliver it only once.
wire sel_i = (mem_busy | mem_ack) ? mem_owner_i : ~dm_req;
assign mem_req   = (mem_busy | ~mem_ack) & (sel_i ? im_req : dm_req);
assign mem_we    = sel_i ? im_we    : dm_we;
assign mem_line  = sel_i ? im_line  : dm_line;
assign mem_addr  = sel_i ? im_addr  : dm_addr;
assign mem_be    = sel_i ? im_be    : dm_be;
assign mem_wdata = sel_i ? im_wdata : dm_wdata;
assign im_ack    = mem_ack & mem_busy &  mem_owner_i;
assign dm_ack    = mem_ack & mem_busy & ~mem_owner_i;

// Capture completed EX payload when MEM has ordinary response capacity.
// The payload may be speculative while descriptor acceptance/abort/fault
// decides mem_valid. All readers qualify it with mem_valid. An unfinished
// older MEM operation retains its payload; queued completions have priority
// through ex_order_ready. This separates the wide capture enables from the
// late commit/descriptor controls without adding a pipeline cycle.
wire mem_payload_take = ex_valid & ex_regular_done & mem_capacity & ex_order_ready;
always_ff @(posedge clk) begin
	if (mem_leave) mem_valid <= 1'b0;
	if (ex_leave & ~ex_abort) mem_valid <= 1'b1;
	if (completion_pop) begin
		mem_valid <= 1'b1;
		mem_pc <= completion_queue[completion_head].pc;
		mem_insn <= completion_queue[completion_head].insn;
		mem_last <= 1'b1;
		mem_first <= 1'b1;
		mem_rd <= {1'b0, completion_queue[completion_head].rd};
		mem_rd_wr <= 1'b1;
		mem_result <= {32'd0, completion_queue[completion_head].value};
		mem_load <= 1'b0;
		mem_store <= 1'b0;
		mem_resv_set <= 1'b0;
		mem_resv_clr <= 1'b0;
		mem_fp <= 1'b0;
		mem_fsgl <= 1'b0;
		mem_t_cr <= cr;
		mem_t_xer <= xer;
		mem_t_lr <= lr;
		mem_t_ctr <= ctr;
		mem_t_fpscr <= fpscr;
		mem_t_msr <= msr;
	end

	if (mem_payload_take) begin
		mem_pc     <= ex_pc;
		mem_insn   <= ex_insn;
		mem_last   <= ex_last;
		mem_first  <= ex_first;
		mem_rd     <= ex_rd;
		mem_rd_wr  <= ex_rd_wr;
		mem_result <= ex_result;
		mem_ea     <= ex_ea;
		mem_load   <= ex_dec.mem_rd;
		mem_store  <= ex_dec.mem_wr & ((ex_dec.resv != RESV_STORE) | stwcx_store);
		mem_cop    <= ex_dec.cop;
		mem_resv_set <= (ex_dec.resv == RESV_SET);
		mem_resv_clr <= stwcx_store;
		mem_n      <= ex_dec.mem_n;
		mem_sext   <= ex_dec.mem_sext;
		mem_brev   <= ex_dec.mem_brev;
		mem_ljust  <= ex_dec.mem_ljust;
		mem_fp     <= ex_dec.mem_fp;
		mem_fsgl   <= ex_dec.mem_fsgl;
		mem_sdata  <= ex_wdata;
		mem_t_cr   <= cr_next;
		mem_t_xer  <= xer_next;
		mem_t_lr   <= lr_next;
		mem_t_ctr  <= ctr_next;
		mem_t_fpscr <= fpscr_next;
		mem_t_msr   <= x_fpen ? msr_exc : msr_next;
	end

	if (reset) mem_valid <= 1'b0;
end

// ============================================================================
//  WB
// ============================================================================
always_ff @(posedge clk) begin
	wb_valid <= mem_leave & ~mem_fault;
	if (mem_leave) begin
		wb_pc     <= mem_pc;
		wb_insn   <= mem_insn;
		wb_last   <= mem_last;
		wb_rd     <= mem_rd;
		wb_rd_wr  <= mem_rd_wr;
		wb_result <= mem_load ? mu_rdata : mem_result;
		wb_fsgl   <= mem_load & mem_fp & mem_fsgl;
		wb_t_cr   <= mem_t_cr;
		wb_t_xer  <= mem_t_xer;
		wb_t_lr   <= mem_t_lr;
		wb_t_ctr  <= mem_t_ctr;
		wb_t_fpscr <= mem_t_fpscr;
		wb_t_msr   <= mem_t_msr;
	end

	if (reset) wb_valid <= 1'b0;
end

assign trace_valid   = wb_valid;
assign trace_last    = wb_last;
assign trace_pc      = wb_pc;
assign trace_insn    = wb_insn;
assign trace_reg_we  = wb_rd_wr;
assign trace_reg_idx = wb_rd;
assign trace_reg_val = wb_value;
assign trace_cr      = wb_t_cr;
assign trace_xer     = wb_t_xer;
assign trace_lr      = wb_t_lr;
assign trace_ctr     = wb_t_ctr;
assign trace_fpscr   = wb_t_fpscr;
assign trace_msr     = wb_t_msr;
assign trace_dreq    = db_req & db_gnt;
assign trace_dwe     = db_we;
assign trace_dkind   = db_kind;
assign trace_daddr   = db_addr;
assign trace_dbe     = db_be;
assign trace_dwdata  = db_wdata;

// Simulation-only observation: no counters or extra ports in the FPGA.
// Events overlap; the bench reports them separately from exclusive cycle buckets.
/* synthesis translate_off */
always_ff @(posedge clk) begin
	if (~reset) begin
		if (fetch_go & if2_valid & ~if_rvalid) $fatal(1, "fetch response overtaken");
		if (fetch_count > 3'd4) $fatal(1, "fetch queue overflow");
		if (fetch_push & (fetch_count == 3'd4) & ~fetch_pop) $fatal(1, "unreserved fetch response");
		if (mu_resp & ~(mem_valid & (mem_load | mem_store))) $fatal(1, "unowned memory response");
		if (completion_count > 4'd8) $fatal(1, "completion queue overflow");
		if (completion_pop & ex_leave) $fatal(1, "two operations entered MEM");
		if (mem_payload_take & mem_valid & ~mem_leave)
			$fatal(1, "EX payload overwrote an unfinished MEM operation");
		if (mem_payload_take & completion_pop)
			$fatal(1, "EX payload overwrote a queued completion");
		if (ex_leave & ~ex_abort & ~mem_payload_take)
			$fatal(1, "committed EX operation did not capture its MEM payload");
		if (completion_push & redir) $fatal(1, "completion admitted during redirect");
		if (ex_valid & sys_reg_write & ex_mem_access)
			$fatal(1, "system register write has a memory descriptor");
		if (sys_write_commit != (ex_leave & ~ex_abort & sys_reg_write))
			$fatal(1, "system write commit differs from architectural EX commit");
		if (id_to_ex & ex_valid & ~ex_leave & ~redir)
			$fatal(1, "ID admission overwrote a live EX operation");
		if (~ex_order_ready & mu_accept) $fatal(1, "memory access overtook queued result");
		if (completion_older_count > completion_count) $fatal(1, "completion queue order lost");
		if (completion_exec_valid & (completion_count == 4'd0)) $fatal(1, "unreserved completion execution");
	end
end
wire [19:0] perf_events /* verilator public_flat_rd */ = {
    completion_pop & completion_push,
    completion_pop, completion_push,
    mmu.walk_cancel_event,
    ex_leave | completion_pop, fetch_full, if2_valid & if2_kill, redir,
    fetch_go, dm_req & ~dm_ack, im_req & ~im_ack,
    ex_final & is_br & (next_pc != ex_pred),
    ex_ready & ~id_valid,
    ex_valid & ex_done & (~mem_ready | (ex_mem_access & ~mu_accept & ~ex_abort)),
    ex_valid & ~ex_stall & is_fpu & ~fpu_resp,
    ex_valid & ~ex_stall & is_int & ~int_resp,
    (mem_valid & (mem_load | mem_store) & ~mu_resp) | (ex_valid & ex_mem_access & ~ex_abort & ~mu_accept),
    ex_valid & ex_stall, id_take, wb_valid & wb_last
};
/* synthesis translate_on */

endmodule

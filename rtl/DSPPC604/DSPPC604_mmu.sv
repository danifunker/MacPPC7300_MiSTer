//============================================================================
//
//  DSPPC604 - PowerPC 604-class CPU core
//  Memory management unit
//
//  Sits between the pipeline and the two buses and translates every
//  instruction fetch and data access while MSR[IR] or MSR[DR] is set:
//
//    block address translation first (IBATs for fetches, DBATs for data),
//    then the segment register and a translation lookaside buffer per side,
//    filled by a hardware walk of the hashed page table. One walker serves
//    both sides, data first. It sets the referenced bit, and the changed bit
//    for a store, in the page table entry with byte writes, as the 604 does.
//
//  A translation that fails is answered like a bus response, with a fault
//  flag and the cause bits the handler must see: the SRR1 bits of an ISI for
//  a fetch, DSISR and DAR of a DSI for a data access.
//
//  Each TLB is direct-mapped and indexed by EA bits 14-19, the 604's
//  congruence class, so tlbie invalidates one entry in each. An entry holds
//  the PTE fields and the segment's VSID; the segment register's keys and
//  no-execute bit are looked up on every access, so a segment register can
//  be changed without invalidating anything. The referenced bit is not kept:
//  it is set in memory whenever an entry is loaded.
//
//  Timing: a fetch or an access that hits is translated in the cycle it is
//  requested, which needs the TLB read a cycle ahead. i_addr_next is where
//  the fetch expects to continue (the predicted address, not a redirect:
//  that would put branch resolution in front of the RAM); d_pre and
//  d_ea_next announce a data access that starts in the next cycle. A request
//  for a page other than the one read ahead (a redirect into another page,
//  the second word of an access that crosses a page boundary) costs one
//  extra cycle. Each side has at most one request outstanding, as the
//  pipeline and the memory unit guarantee.
//
//  Walks take the data bus between the memory unit's accesses. A walk for a
//  fetch is abandoned at the next entry if the fetch has moved on.
//
//============================================================================

module DSPPC604_mmu
#(
	parameter int TLB_BITS = 6,               // entries in each TLB, as a power of two
	parameter bit CANDIDATE_D_ADDR = 1'b0     // current bus address is already the candidate next request
)
(
	input  logic        clk,
	input  logic        reset,

	input  logic        msr_ir,
	input  logic        msr_dr,
	input  logic        msr_pr,
	input  logic [15:0][31:0] bat,            // SPR 528-543: IBAT0U, IBAT0L, ... DBAT3U, DBAT3L
	input  logic [15:0][31:0] sr,
	input  logic        sr_changed,           // one cycle: mtsr is writing one of them
	input  logic [31:0] sdr1,
	input  logic        tlbie,                // one cycle: invalidate tlbie_ea's entries
	input  logic [31:0] tlbie_ea,

	// instruction fetch
	input  logic        i_req,
	input  logic [31:0] i_addr,
	input  logic [31:0] i_addr_next,
	input  logic        i_cancel,             // discard an ungranted speculative walk
	output logic        i_gnt,
	output logic        i_rvalid,
	output logic [31:0] i_rdata,
	output logic        i_fault,              // with i_rvalid: no word, an ISI instead
	output logic [31:0] i_srr1,               // ... with these SRR1 bits

	output logic        ibus_req,
	output logic [31:0] ibus_addr,
	output logic        ibus_ci,              // the page is cache-inhibited
	input  logic        ibus_gnt,
	input  logic        ibus_rvalid,
	input  logic [31:0] ibus_rdata,

	// data access, in the memory unit's bus terms
	input  logic        d_pre,
	input  logic [31:0] d_ea_next,
	input  logic        d_req,
	input  logic        d_we,
	input  DSPPC604_pkg::ck_t d_kind,         // what the cache is asked; dcbz faults on a W or I page
	input  logic [29:0] d_addr,               // word address
	// d_addr's adder, when the memory unit passes this cycle's effective
	// address straight through (d_sum_direct): its operands and carry-in,
	// for the page compares below (sum-addressed: no 32-bit add in front)
	input  logic [31:0] d_sum_a,
	input  logic [31:0] d_sum_b,
	input  logic        d_sum_ci,
	input  logic        d_sum_direct,
	input  logic [29:0] d_addr_held,          // d_addr when not d_sum_direct, from registers (no adder in front)
	input  logic [3:0]  d_be,
	input  logic [31:0] d_wdata,
	input  logic        d_wide,
	input  logic [31:0] d_wdata_next,
	input  logic [31:0] d_ea,                 // the access's effective address, for DAR
	input  logic        d_cancel,             // an ungranted EX request was flushed
	input  logic        d_xl_flush,           // MSR, BAT, SDR1 or SR may have changed: drop the cached translations
	output logic        d_gnt,
	output logic        d_rvalid,
	output logic [31:0] d_rdata,
	output logic        d_rwide,
	output logic [31:0] d_rdata_next,
	output logic        d_fault,              // with d_rvalid: not done, a DSI instead
	output logic        d_falign,             // ... or an alignment exception (dcbz)
	output logic [31:0] d_dsisr,
	output logic [31:0] d_dar,

	output logic        dbus_req,
	output logic        dbus_we,
	output DSPPC604_pkg::ck_t dbus_kind,
	output logic [29:0] dbus_addr,
	output logic [3:0]  dbus_be,
	output logic [31:0] dbus_wdata,
	output logic        dbus_wide,
	output logic [31:0] dbus_wdata_next,
	output logic        dbus_ci,              // the page is cache-inhibited
	output logic        dbus_wt,              // ... write-through
	input  logic        dbus_gnt,
	input  logic        dbus_rvalid,
	input  logic [31:0] dbus_rdata,
	input  logic        dbus_rwide,
	input  logic [31:0] dbus_rdata_next
);

import DSPPC604_pkg::*;

localparam int TLB_SIZE = 1 << TLB_BITS;
localparam int TAGW     = 16 - TLB_BITS;      // page index bits above the TLB index

// the cause bits: SRR1 of an ISI, DSISR of a DSI
localparam logic [31:0] X_DIRECT  = 32'h80000000;   // DSI: direct-store segment (T = 1)
localparam logic [31:0] X_NOPAGE  = 32'h40000000;   // no page table entry
localparam logic [31:0] X_NOEXEC  = 32'h10000000;   // ISI: no-execute or guarded, or T = 1
localparam logic [31:0] X_PROT    = 32'h08000000;   // protection violation
localparam logic [31:0] X_STORE   = 32'h02000000;   // DSI: the access was a store

typedef struct packed {
	logic [23:0]     vsid;
	logic [TAGW-1:0] tag;
	logic [19:0]     rpn;
	logic            c;
	logic [3:0]      wimg;
	logic [1:0]      pp;
} tlbe_t;

// the outcome of looking an address up
typedef struct packed {
	logic        ok;          // pa is the physical address
	logic        fault;       // take the exception, with info
	logic        align;       // ... an alignment exception: dcbz on a W or I page
	logic        miss;        // no entry: walk
	logic        cwalk;       // entry found, but a store needs the changed bit set: walk
	logic [31:0] pa;
	logic [31:0] info;
	logic [3:0]  wimg;        // the page's attributes (the architecture's default when off)
} xl_t;

// key = 1 forbids: any access with PP = 00, a store unless PP = 10
// key = 0 forbids: a store with PP = 11
function automatic logic prot_fault(input logic key, input logic [1:0] pp, input logic store);
	begin
		prot_fault = key ? ((pp == 2'b00) | (store & (pp != 2'b10))) : (store & (pp == 2'b11));
	end
endfunction

// Everything about one address that does not need a page table walk.
function automatic xl_t translate(
	input logic             on,         // MSR[IR] or MSR[DR]
	input logic             fetch,
	input logic             store,
	input logic             line,       // dcbz: a W or I page is an alignment exception
	input logic             pr,
	input logic [31:0]      ea,
	input logic [7:0][31:0] b,          // this side's four BAT pairs, upper then lower
	input logic [31:0]      s,          // the segment register
	input logic             tv,         // the TLB entry at ea's index is valid
	input tlbe_t            te);
	logic        bhit;
	logic [31:0] bpa;
	logic [1:0]  bpp;
	logic [3:0]  bwimg;
	logic [10:0] bl;
	logic        key;
	begin
		translate = '0;

		// block address translation: the lowest-numbered matching BAT
		bhit = 1'b0; bpa = 32'd0; bpp = 2'b00; bwimg = 4'd0;
		for (int i = 3; i >= 0; i--) begin
			bl = b[2*i][12:2];
			if ((pr ? b[2*i][0] : b[2*i][1]) && (ea[31:28] == b[2*i][31:28]) &&
			    ((ea[27:17] & ~bl) == (b[2*i][27:17] & ~bl))) begin
				bhit  = 1'b1;
				bpa   = {b[2*i+1][31:28], (b[2*i+1][27:17] & ~bl) | (ea[27:17] & bl), ea[16:0]};
				bpp   = b[2*i+1][1:0];
				bwimg = b[2*i+1][6:3];
			end
		end

		key = pr ? s[29] : s[30];

		if (!on) begin
			translate.ok   = 1'b1;
			translate.pa   = ea;
			translate.wimg = 4'b0011;
		end
		else if (bhit) begin
			translate.pa   = bpa;
			translate.wimg = bwimg;
			if (fetch ? (bpp == 2'b00) : ((bpp == 2'b00) | (store & (bpp != 2'b10)))) begin
				translate.fault = 1'b1;
				translate.info  = X_PROT | (store ? X_STORE : 32'd0);
			end
			else if (fetch & bwimg[0]) begin
				translate.fault = 1'b1;
				translate.info  = X_NOEXEC;
			end
			else if (line & (bwimg[3] | bwimg[2])) begin
				translate.fault = 1'b1;
				translate.align = 1'b1;
			end
			else translate.ok = 1'b1;
		end
		else if (s[31]) begin
			// direct-store segment: nothing here to serve it
			translate.fault = 1'b1;
			translate.info  = fetch ? X_NOEXEC : (X_DIRECT | (store ? X_STORE : 32'd0));
		end
		else if (fetch & s[28]) begin
			translate.fault = 1'b1;
			translate.info  = X_NOEXEC;
		end
		else if (tv && te.vsid == s[23:0] && te.tag == ea[27 -: TAGW]) begin
			translate.pa   = {te.rpn, ea[11:0]};
			translate.wimg = te.wimg;
			if (prot_fault(key, te.pp, store)) begin
				translate.fault = 1'b1;
				translate.info  = X_PROT | (store ? X_STORE : 32'd0);
			end
			else if (fetch & te.wimg[0]) begin
				translate.fault = 1'b1;
				translate.info  = X_NOEXEC;
			end
			else if (line & (te.wimg[3] | te.wimg[2])) begin
				translate.fault = 1'b1;
				translate.align = 1'b1;
			end
			else if (store & ~te.c) translate.cwalk = 1'b1;
			else translate.ok = 1'b1;
		end
		else translate.miss = 1'b1;
	end
endfunction

// ============================================================================
//  The TLBs
// ============================================================================
// One write port (the walker) and one read port each, read a cycle ahead.
// Retry and read-collision freshness discard an entry sampled while it is
// written, so the RAM needs no read-during-write logic.
(* ramstyle = "no_rw_check" *) tlbe_t itlb_mem [TLB_SIZE];
(* ramstyle = "no_rw_check" *) tlbe_t dtlb_mem [TLB_SIZE];
logic [TLB_SIZE-1:0] itlb_valid;
logic [TLB_SIZE-1:0] dtlb_valid;
tlbe_t itlb_q;
tlbe_t dtlb_q;
logic [19:0] i_page_q;         // the page itlb_q was read for
logic [19:0] d_page_q;         // ... and dtlb_q
logic i_tlb_collision, d_tlb_collision;

// written by the walker
logic              w_we;
logic              w_side;      // 0 data, 1 instruction
logic [TLB_BITS-1:0] w_idx;
tlbe_t             w_entry;

wire [19:0]         d_page   = d_addr[29:10];

// Whether the effective address's page equals k, without the 32-bit add:
// a + b = k exactly when every bit's carry in (a ^ b ^ k) is the carry out
// of the bit below as k says it ((a & b) | ((a | b) & ~k)), the lowest
// page bit's carry being the low 12 bits' own (a 12-bit add).
wire [12:0] d_sum_lo = {1'b0, d_sum_a[11:0]} + {1'b0, d_sum_b[11:0]} + {12'd0, d_sum_ci};
function automatic logic d_sum_page_eq(input logic [19:0] k);
	logic [19:0] x, c;
	begin
		x = d_sum_a[31:12] ^ d_sum_b[31:12] ^ k;
		c = (d_sum_a[31:12] & d_sum_b[31:12]) | ((d_sum_a[31:12] | d_sum_b[31:12]) & ~k);
		d_sum_page_eq = (x == {c[18:0], d_sum_lo[12]});
	end
endfunction
// (when not direct, the page comes from the requester's registers, so
// that the adder is not in front of the compare on a path never used)
function automatic logic d_page_is(input logic [19:0] k);
	d_page_is = d_sum_direct ? d_sum_page_eq(k) : (d_addr_held[29:10] == k);
endfunction
// a segment register written since the read-ahead makes it stale too
logic               i_stale, d_stale;
// (the I-side's segment register is read a cycle after its page, from
// the registered page, so the prediction is not in front of its 16:1
// choice; a fetch into another segment waits a cycle for it)
logic [3:0]         i_sr_seg;
wire                i_fresh  = (i_page_q == i_addr[31:12]) & (i_sr_seg == i_page_q[19:16]) &
                               ~i_stale & ~i_tlb_collision;
wire                d_fresh  = d_page_is(d_page_q) & ~d_stale & ~d_tlb_collision;
logic               d_rd;                          // read the DTLB for d_page now
wire [TLB_BITS-1:0] d_idx    = d_page[TLB_BITS-1:0];

// the reads: ahead for what comes next, or again for the request in hand;
// the segment register goes with them, so that its 16:1 choice is not in
// the lookup's cycle (a fresh page means a fresh segment register too)
wire [19:0]         i_rpage  = i_fresh ? i_addr_next[31:12] : i_addr[31:12];
wire                d_read   = CANDIDATE_D_ADDR | d_pre | d_rd;
wire [19:0]         d_rpage  = CANDIDATE_D_ADDR ? d_page : d_pre ? d_ea_next[31:12] : d_page;
logic [31:0]        i_sr_q, d_sr_q;

always_ff @(posedge clk) begin
	itlb_q   <= itlb_mem[i_rpage[TLB_BITS-1:0]];
	i_page_q <= i_rpage;
	i_sr_q   <= sr[i_page_q[19:16]];
	i_sr_seg <= i_page_q[19:16];
	i_tlb_collision <= w_we & w_side & (w_idx == i_rpage[TLB_BITS-1:0]);
	if (d_read) begin
		dtlb_q   <= dtlb_mem[d_rpage[TLB_BITS-1:0]];
		d_page_q <= d_rpage;
		d_sr_q   <= sr[d_rpage[19:16]];
		d_tlb_collision <= w_we & ~w_side & (w_idx == d_rpage[TLB_BITS-1:0]);
	end
	// mtsr: what was read ahead is read again (the write lands at this edge)
	if (sr_changed)      begin i_stale <= 1'b1; d_stale <= 1'b1; end
	else begin
		if (~i_fresh)        i_stale <= 1'b0;
		if (d_read)          d_stale <= 1'b0;
	end
	if (reset) begin
		i_stale <= 1'b0; d_stale <= 1'b0;
		i_tlb_collision <= 1'b0; d_tlb_collision <= 1'b0;
	end
	if (w_we &  w_side) itlb_mem[w_idx] <= w_entry;
	if (w_we & ~w_side) dtlb_mem[w_idx] <= w_entry;
end

/* synthesis translate_off */
always_ff @(posedge clk) begin
	// The CPU presents a descriptor's first address before admission, so
	// the bus page is its look-ahead page whenever that descriptor starts.
	if (~reset & d_req & ~d_sum_direct & (d_addr != d_addr_held))
		$fatal(1, "held data address differs from the bus address");
	if (CANDIDATE_D_ADDR & ~reset & d_pre & d_req)
		if (d_ea_next[31:12] != d_page)
			$fatal(1, "candidate data page differs from accepted descriptor");
end
/* synthesis translate_on */

always_ff @(posedge clk) begin
	if (w_we &  w_side) itlb_valid[w_idx] <= 1'b1;
	if (w_we & ~w_side) dtlb_valid[w_idx] <= 1'b1;
	if (tlbie) begin
		itlb_valid[tlbie_ea[12 +: TLB_BITS]] <= 1'b0;
		dtlb_valid[tlbie_ea[12 +: TLB_BITS]] <= 1'b0;
	end
	if (reset) begin
		itlb_valid <= '0;
		dtlb_valid <= '0;
	end
end

// ============================================================================
//  The lookups
// ============================================================================
wire [31:0] d_ea_w = {d_addr, 2'b00};

wire d_line = (d_kind == CK_ZERO);

xl_t ixl, dxl, d_lookup_load, d_lookup_store;
// The last few pages' registered lookups, matched in parallel by page and
// MSR[DR,PR]; a program's stack, globals and arrays each keep theirs.
localparam int DXL_N = 4;
xl_t d_cached_load [DXL_N], d_cached_store [DXL_N];
logic [31:0] d_cached_sr_e [DXL_N];
logic [DXL_N-1:0] d_cached_valid;
logic [19:0] d_cached_page [DXL_N];
logic [DXL_N-1:0] d_cached_dr, d_cached_pr;
logic [1:0] d_cached_next;                 // round-robin replacement
logic [DXL_N-1:0] d_cached_match;
always_comb
	for (int n = 0; n < DXL_N; n++)
		d_cached_match[n] = d_cached_valid[n] & d_page_is(d_cached_page[n]) &
		                    (d_cached_dr[n] == msr_dr) & (d_cached_pr[n] == msr_pr);
wire d_cached_hit = |d_cached_match;
xl_t d_hit_load, d_hit_store;
logic [31:0] d_cached_sr;
always_comb begin
	d_hit_load = '0;
	d_hit_store = '0;
	d_cached_sr = '0;
	for (int n = 0; n < DXL_N; n++)
		if (d_cached_match[n]) begin
			d_hit_load = d_hit_load | d_cached_load[n];
			d_hit_store = d_hit_store | d_cached_store[n];
			d_cached_sr = d_cached_sr | d_cached_sr_e[n];
		end
end
// The fetch's page from the registered read-ahead page: ixl is used only
// when it is fresh (i_ready), so the fetch address's multiplexers are not
// in front of the BAT compares; with translation off the address is used
// as it is.
assign ixl = translate(msr_ir, 1'b1, 1'b0, 1'b0, msr_pr, {i_page_q, 12'd0}, bat[7:0], i_sr_q,
                       itlb_valid[i_page_q[TLB_BITS-1:0]], itlb_q);
// Resolve a page from the registered read-ahead address. The fresh-page
// check qualifies installation, so neither the EA adder nor forwarding
// feeds the BAT permission/physical-page datapath in this cycle.
assign d_lookup_load = translate(msr_dr, 1'b0, 1'b0, 1'b0, msr_pr,
                                {d_page_q, 12'd0}, bat[15:8], d_sr_q,
                                dtlb_valid[d_page_q[TLB_BITS-1:0]], dtlb_q);
assign d_lookup_store = translate(msr_dr, 1'b0, 1'b1, 1'b0, msr_pr,
                                 {d_page_q, 12'd0}, bat[15:8], d_sr_q,
                                 dtlb_valid[d_page_q[TLB_BITS-1:0]], dtlb_q);
always_comb begin
	dxl = d_we ? d_hit_store : d_hit_load;
	// All addresses within a page have the same translation and protection.
	dxl.pa[11:0] = d_ea_w[11:0];
	// Protection precedes dcbz's W/I alignment exception, which precedes a
	// store's changed-bit walk. Keep that priority from translate().
	if (d_cached_hit & ~dxl.fault & d_line & (dxl.wimg[3] | dxl.wimg[2])) begin
		dxl.ok = 1'b0;
		dxl.fault = 1'b1;
		dxl.align = 1'b1;
		dxl.cwalk = 1'b0;
	end
end

// ============================================================================
//  The walker
// ============================================================================
typedef enum logic [2:0] {
	W_IDLE,
	W_RD0,       // reading PTE word 0 of entry w_i
	W_RD1,       // ... word 1 of the matching entry
	W_WR,        // setting R and/or C in it
	W_END        // one cycle: the result is out
} wstate_t;

wstate_t     w_state;
logic        w_out;          // a bus request of the walker is outstanding
logic        w_side_q;       // 0 data, 1 instruction
logic [31:0] w_ea;
logic [23:0] w_vsid;
logic        w_key;
logic        w_store;
logic        w_line;         // dcbz: no C bit for a page it will not be allowed to touch
logic        w_cstore;       // the store will be made: set C
logic        w_h;            // on the secondary hash
logic [2:0]  w_i;
logic [31:0] w_w1;           // PTE word 1 as read
logic        w_found;
logic        w_pfault;
logic        w_abort;        // given up because the fetch moved on
logic        w_need_r;
logic        w_need_c;
logic        w_tlbie_seen;   // a tlbie happened during the walk: do not load the entry

// A walk's inputs, taken in every idle cycle (no enable behind the EA's
// translation compare); D_WREQ starts the walk from them a cycle later, so
// the walker's start and state no longer wait for that compare.
logic [31:0] dw_ea;
logic [23:0] dw_vsid;
logic        dw_key, dw_store, dw_line;

// requests from the two sides (declared here, decided below)
logic w_req_d, w_req_i;
logic d_outstanding;      // a data access is on the bus
logic w_bus;              // the walker has the data bus

// the walker's request
logic        w_dreq;
logic        w_dwe;
logic [31:0] w_daddr;
logic [3:0]  w_dbe;
logic [31:0] w_dwdata;
wire  w_start_d = (w_state == W_IDLE) & w_req_d;
wire  w_start_i = (w_state == W_IDLE) & w_req_i & ~w_req_d;
wire  w_done    = (w_state == W_END);

wire [18:0] w_hash1 = {3'b000, w_ea[27:12]} ^ w_vsid[18:0];
wire [18:0] w_hash  = w_h ? ~w_hash1 : w_hash1;
wire [31:0] w_pteg  = {sdr1[31:25], sdr1[24:16] | (w_hash[18:10] & sdr1[8:0]), w_hash[9:0], 6'b000000};
wire [31:0] w_pte   = w_pteg + {26'd0, w_i, 3'b000};
wire [31:0] w_match = {1'b1, w_vsid, w_h, w_ea[27:22]};

// a walk for a fetch is abandoned when the fetch has moved to another page
wire w_moved = w_side_q & ~(i_req & (i_addr[31:12] == w_ea[31:12]));

wire w_want = (w_state == W_RD0) | (w_state == W_RD1) | (w_state == W_WR);

always_ff @(posedge clk) begin
	if (w_start_d | w_start_i) begin
		w_state      <= W_RD0;
		w_side_q     <= ~w_start_d;
		w_ea         <= w_start_d ? dw_ea : i_addr;
		// Walk admission already requires a fresh lookup. Its segment payload
		// is registered with that lookup, so the late I/D arbitration need not
		// drive another 16-way segment-register mux before these registers.
		w_vsid       <= w_start_d ? dw_vsid : i_sr_q[23:0];
		w_key        <= w_start_d ? dw_key : (msr_pr ? i_sr_q[29] : i_sr_q[30]);
		w_store      <= w_start_d & dw_store;
		w_line       <= w_start_d & dw_line;
		w_cstore     <= 1'b0;
		w_h          <= 1'b0;
		w_i          <= 3'd0;
		w_found      <= 1'b0;
		w_pfault     <= 1'b0;
		w_abort      <= 1'b0;
		w_need_r     <= 1'b0;
		w_need_c     <= 1'b0;
		w_tlbie_seen <= 1'b0;
	end

	if (tlbie) w_tlbie_seen <= 1'b1;

	if (w_bus & w_dreq & dbus_gnt) w_out <= 1'b1;
	if (w_out & dbus_rvalid) begin
		w_out <= 1'b0;
		case (w_state)
			W_RD0: begin
				if (dbus_rdata == w_match) w_state <= W_RD1;
				else if (w_moved)          begin w_abort <= 1'b1; w_state <= W_END; end
				else if (w_i != 3'd7)      w_i <= w_i + 3'd1;
				else if (~w_h)             begin w_h <= 1'b1; w_i <= 3'd0; end
				else                       w_state <= W_END;
			end
			W_RD1: begin
				w_w1    <= dbus_rdata;
				w_found <= 1'b1;
				if (prot_fault(w_key, dbus_rdata[1:0], w_store)) begin
					w_pfault <= 1'b1;
					w_state  <= W_END;
				end
				else if (w_moved) begin w_abort <= 1'b1; w_state <= W_END; end
				else begin
					// C only for a store that will be made: not dcbz on a
					// write-through or cache-inhibited page (W = bit 6, I = bit 5)
					w_cstore <= w_store & ~(w_line & (dbus_rdata[6] | dbus_rdata[5]));
					w_need_r <= ~dbus_rdata[8];
					w_need_c <= w_store & ~dbus_rdata[7] & ~(w_line & (dbus_rdata[6] | dbus_rdata[5]));
					w_state  <= (~dbus_rdata[8] | (w_store & ~dbus_rdata[7] & ~(w_line & (dbus_rdata[6] | dbus_rdata[5]))))
					            ? W_WR : W_END;
				end
			end
			default: w_state <= W_END;      // W_WR
		endcase
	end

	if (w_state == W_END) w_state <= W_IDLE;

	if (reset) begin
		w_state <= W_IDLE;
		w_out   <= 1'b0;
	end
end

// the entry it loads
assign w_we    = w_done & w_found & ~w_pfault & ~w_abort & ~w_moved & ~w_tlbie_seen & ~tlbie;
assign w_side  = w_side_q;
assign w_idx   = w_ea[12 +: TLB_BITS];
assign w_entry = {w_vsid, w_ea[27 -: TAGW], w_w1[31:12], w_w1[7] | w_cstore, w_w1[6:3], w_w1[1:0]};

// ============================================================================
//  The data bus: the walker between the memory unit's accesses
// ============================================================================
assign w_bus = w_want & ~d_outstanding;

always_comb begin
	w_dreq   = w_want & ~w_out;
	w_dwe    = (w_state == W_WR);
	w_daddr  = (w_state == W_RD0) ? w_pte : (w_pte + 32'd4);
	w_dbe    = (w_state == W_WR) ? {2'b00, w_need_r, w_need_c} : 4'b1111;
	w_dwdata = {16'd0, w_w1[15:8] | 8'h01, w_w1[7:0] | 8'h80};
end

// ============================================================================
//  The data side
// ============================================================================
typedef enum logic [2:0] {
	D_IDLE,
	D_WREQ,      // a walk wanted: started from the registers below, a cycle on
	D_WALK,
	D_RETRY,     // the entry was loaded: read it again
	D_FAULT      // answer with the fault this cycle
} dstate_t;

dstate_t     d_state;
logic        d_cancelled;
/* synthesis translate_off */
wire walk_cancel_event = d_cancel & (d_state == D_WALK);
/* synthesis translate_on */
logic [31:0] d_info_q;
logic [31:0] d_dar_q;
logic        d_align_q;

wire         d_lookup_ready = d_fresh;
wire         d_ready = d_cached_hit;
wire [31:0]  d_dar_now = (d_addr == d_ea[31:2]) ? d_ea : d_ea_w;

// Register a page's lookup before it can grant a request. Repeated accesses
// use the registered load/store outcomes without a BAT mux behind the EA
// adder. A cold page waits here; the elastic memory unit holds its descriptor.
// The CPU's translation-changing redirects (rfi, mtmsr, the BAT, SDR1 and SR
// writes, isync, tlbie, exceptions) and SR/TLB writes invalidate them all; a
// mispredicted branch keeps them.
always_ff @(posedge clk) begin
	if ((d_state == D_IDLE) & d_req & ~d_cached_hit & d_lookup_ready) begin
		d_cached_page[d_cached_next] <= d_page_q;
		d_cached_dr[d_cached_next] <= msr_dr;
		d_cached_pr[d_cached_next] <= msr_pr;
		d_cached_load[d_cached_next] <= d_lookup_load;
		d_cached_store[d_cached_next] <= d_lookup_store;
		d_cached_sr_e[d_cached_next] <= d_sr_q;
		d_cached_valid[d_cached_next] <= 1'b1;
		d_cached_next <= d_cached_next + 2'd1;
	end
	if (reset | d_xl_flush | sr_changed | tlbie | w_we) d_cached_valid <= '0;
	if (reset) d_cached_next <= 2'd0;
end

// the data side's own bus request
wire d_dreq = (d_state == D_IDLE) & d_req & d_ready & dxl.ok & ~w_bus;

always_comb begin
	d_rd    = 1'b0;
	w_req_d = 1'b0;
	d_gnt   = 1'b0;
	case (d_state)
		D_IDLE: if (d_req) begin
			if (~d_lookup_ready & ~d_ready)  d_rd  = 1'b1;
			else if (~d_ready)              ;      // wait for the registered lookup
			else if (dxl.ok)                d_gnt = dbus_gnt & ~w_bus;
			else if (dxl.fault)             d_gnt = 1'b1;
			// else a miss or a changed-bit walk: D_WREQ, a cycle on
		end
		D_WREQ:                             w_req_d = 1'b1;
		D_WALK: if (w_done & ~d_cancelled & d_req) begin
			if (~w_found | w_pfault)        d_gnt = 1'b1;
		end
		D_RETRY:                            d_rd  = 1'b1;
		default: ;
	endcase
end

always_ff @(posedge clk) begin
	case (d_state)
		D_IDLE: if (d_req & d_ready) begin
			if (dxl.fault) d_state <= D_FAULT;     // (its DSISR and DAR: below)
			else if (~dxl.ok) d_state <= D_WREQ;
		end
		D_WREQ: if (w_start_d) begin
			d_state <= D_WALK;
			d_cancelled <= d_cancel;
		end
		else if (d_cancel) d_state <= D_IDLE;
		D_WALK: if (w_done) begin
			if (d_cancelled | d_cancel | ~d_req) d_state <= D_IDLE;
			else if (~w_found) begin
				d_state   <= D_FAULT;
				d_info_q  <= X_NOPAGE | (d_we ? X_STORE : 32'd0);
				d_align_q <= 1'b0;
				d_dar_q   <= d_dar_now;
			end
			else if (w_pfault) begin
				d_state   <= D_FAULT;
				d_info_q  <= X_PROT | (d_we ? X_STORE : 32'd0);
				d_align_q <= 1'b0;
				d_dar_q   <= d_dar_now;
			end
			else d_state <= D_RETRY;
		end
		D_RETRY: d_state <= D_IDLE;
		default: d_state <= D_IDLE;         // D_FAULT
	endcase
	if (d_cancel & (d_state == D_WALK)) d_cancelled <= 1'b1;
	if (d_state == D_IDLE) begin
		// A fault found here is answered from these in D_FAULT; they are
		// read nowhere else, so they need no enable behind the compare.
		d_info_q  <= dxl.info;
		d_align_q <= dxl.align;
		d_dar_q   <= d_dar_now;
		dw_ea    <= d_ea_w;
		dw_vsid  <= d_cached_sr[23:0];
		dw_key   <= msr_pr ? d_cached_sr[29] : d_cached_sr[30];
		dw_store <= d_we;
		dw_line  <= d_line;
	end

	if (d_outstanding & dbus_rvalid) d_outstanding <= 1'b0;
	if (d_dreq & dbus_gnt) d_outstanding <= 1'b1;

	if (reset) begin
		d_state       <= D_IDLE;
		d_outstanding <= 1'b0;
		d_cancelled   <= 1'b0;
	end
end

assign d_rvalid = (d_outstanding & dbus_rvalid) | (d_state == D_FAULT);
assign d_rdata  = dbus_rdata;
assign d_rwide  = d_outstanding & dbus_rwide;
assign d_rdata_next = dbus_rdata_next;
assign d_fault  = (d_state == D_FAULT);
assign d_falign = d_align_q;
assign d_dsisr  = d_info_q;
assign d_dar    = d_dar_q;

// the walker's accesses are cacheable words, as the 604's table search's
assign dbus_req   = w_bus ? w_dreq        : d_dreq;
assign dbus_we    = w_bus ? w_dwe         : d_we;
assign dbus_kind  = w_bus ? CK_WORD       : d_kind;
// Translation never changes the page offset. Keep the RAM's set index
// independent of BAT/TLB hit and protection decisions, including on misses.
assign dbus_addr  = w_bus ? w_daddr[31:2] : {dxl.pa[31:12], d_addr[9:0]};
assign dbus_be    = w_bus ? w_dbe         : d_be;
assign dbus_wdata = w_bus ? w_dwdata      : d_wdata;
assign dbus_wide = ~w_bus & d_wide;
assign dbus_wdata_next = w_bus ? 32'd0 : d_wdata_next;
assign dbus_ci    = ~w_bus & dxl.wimg[2];
assign dbus_wt    = ~w_bus & dxl.wimg[3];

// ============================================================================
//  The instruction side
// ============================================================================
typedef enum logic [1:0] {
	I_IDLE,
	I_WALK,
	I_RETRY,
	I_FAULT
} istate_t;

istate_t     i_state;
logic [31:0] i_info_q;
logic        i_outstanding;
logic        i_cancelled;

// the fetch the walk was for is still wanted
wire i_same  = i_req & (i_addr[31:12] == w_ea[31:12]);
wire i_ready = ~msr_ir | i_fresh;

always_comb begin
	w_req_i = 1'b0;
	i_gnt   = 1'b0;
	case (i_state)
		I_IDLE: if (i_req & i_ready) begin
			if (ixl.ok)                     i_gnt = ibus_gnt;
			else if (~i_outstanding) begin
				if (ixl.fault)             i_gnt = 1'b1;
				else                      w_req_i = 1'b1;
			end
		end
		I_WALK: if (w_done & i_same & ~i_cancel & ~i_cancelled & ~w_abort & (~w_found | w_pfault)) i_gnt = 1'b1;
		default: ;
	endcase
end

always_ff @(posedge clk) begin
	case (i_state)
		I_IDLE: if (i_req & i_ready & ~i_outstanding) begin
			if (ixl.fault) begin
				i_state  <= I_FAULT;
				i_info_q <= ixl.info;
			end
			else if (~ixl.ok & w_start_i) begin
				i_state <= I_WALK;
				// a redirect in its first cycle cancels it too: an exception's
				// vector in the same page must not take its result
				i_cancelled <= i_cancel;
			end
		end
		I_WALK: if (w_done) begin
			if (~i_same | w_abort | i_cancel | i_cancelled) i_state <= I_IDLE;
			else if (~w_found)  begin i_state <= I_FAULT; i_info_q <= X_NOPAGE; end
			else if (w_pfault)  begin i_state <= I_FAULT; i_info_q <= X_PROT; end
			else                i_state <= I_RETRY;
		end
		I_RETRY: i_state <= I_IDLE;
		default: i_state <= I_IDLE;         // I_FAULT
	endcase
	if (i_cancel & (i_state == I_WALK)) i_cancelled <= 1'b1;

	// A speculative next fetch must not return an ISI ahead of an older
	// cache response. Cache hits can still accept a new request each cycle.
	if (ibus_rvalid) i_outstanding <= 1'b0;
	if (ibus_req & ibus_gnt) i_outstanding <= 1'b1;
	if (reset) begin
		i_state <= I_IDLE;
		i_outstanding <= 1'b0;
		i_cancelled <= 1'b0;
	end
end

assign ibus_req  = (i_state == I_IDLE) & i_req & i_ready & ixl.ok;
assign ibus_addr = msr_ir ? {ixl.pa[31:12], i_addr[11:0]} : i_addr;
assign ibus_ci   = ixl.wimg[2];
assign i_rvalid  = ibus_rvalid | (i_state == I_FAULT);
assign i_rdata   = ibus_rdata;
assign i_fault   = (i_state == I_FAULT);
assign i_srr1    = i_info_q;

endmodule

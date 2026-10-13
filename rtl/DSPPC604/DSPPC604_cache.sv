//============================================================================
//
//  DSPPC604 - PowerPC 604-class CPU core
//  Cache: 16 KB, four ways of 128 sets of 32-byte lines, as the 604's
//
//  One module for both caches; WRITABLE makes the data cache (write-back,
//  write-allocate, a dirty bit per line, the cache instructions and the
//  snoop port's write-back), the other is read-only. Replacement is a
//  pseudo-LRU tree per set, an invalid way first.
//
//  Request port: the requester presents a physical address and holds req
//  until gnt (a store's data, wdata and wdata_next, is presented in the
//  cycle after the grant instead, and held while the request is looked at:
//  the cache reads it in S_LOOK), which comes in any cycle the cache is idle, or is answering a
//  read hit (so that fetches flow one per cycle). The set is read at that
//  edge, the tags are compared in the next cycle, and a hit is answered
//  then: rvalid one cycle after the grant, the timing of the simplest bus.
//  A miss takes as long as the memory does. A write's RAM update happens in
//  the answer cycle, and the requester never asks again in that same cycle
//  (the memory unit and the page table walker leave a cycle between
//  accesses), so nothing reads what is being written.
//
//  Kinds of request (data cache): a word read or write with byte enables;
//  line zero (dcbz: allocate without a fill, all zero, dirty); flush (dcbf:
//  write back if dirty, invalidate); store (dcbst: write back if dirty);
//  invalidate (dcbi); icbi, which is passed on through the inv port (to the
//  instruction cache's snoop port). An access marked cache-inhibited, or
//  any access with the cache disabled, or a miss with the cache locked, is
//  a single word on the memory port and touches no line. A store to a
//  write-through page updates the line if present, allocates nothing, and
//  goes to memory as well. With the cache disabled the cache instructions
//  do nothing.
//
//  Memory port: one line (32 bytes, write data presented whole, read data
//  returned whole with the acknowledge; word 0, the lowest address, in bits
//  255-224) or one word with byte enables in bits 31-0; req stays up until
//  ack. One outstanding.
//
//  Snoop port: before anything else reads or writes memory, it presents the
//  line; a dirty copy is written back, a copy is invalidated for a write,
//  then ack.
//
//  inval_all (HID0[ICFI] or [DCFI]) marks every line invalid, dirty or not,
//  by sweeping the sets; so does reset. Requests wait meanwhile.
//
//============================================================================

module DSPPC604_cache
#(
	parameter bit WRITABLE    = 1,
	parameter bit LATE_ANSWER = 0,           // rvalid and rdata from a register, a cycle later
	parameter int IDXW        = 7            // set index bits: 7 is 128 sets (16 KB), 8 is 256 (32 KB, the 604e's)
)
(
	input  logic        clk,
	input  logic        reset,

	input  logic        enable,              // HID0[ICE] or [DCE]
	input  logic        lock,                // HID0[ILOCK] or [DLOCK]
	input  logic        inval_all,           // one cycle (remembered while busy)

	// request port
	input  logic        req,
	input  logic        we,
	input  DSPPC604_pkg::ck_t kind,
	input  logic [31:2] addr,
	input  logic [3:0]  be,
	input  logic [31:0] wdata,
	input  logic        wide,                // two adjacent words, within one line
	input  logic [31:0] wdata_next,
	input  logic        ci,                  // cache-inhibited (WIMG I)
	input  logic        wt,                  // write-through (WIMG W)
	output logic        gnt,
	output logic        rvalid,
	output logic [31:0] rdata,
	output logic        rvalid_wide,
	output logic [31:0] rdata_next,
	output logic        wide_sure,           // the request in hand (S_LOOK on) is wide and will be answered wide
	output logic        slow,                // busy beyond a lookup: a miss, a write-back, a snoop, a sweep
	output logic        posted,              // a posted write has not reached memory yet (sync waits)

	// icbi passed on (data cache only; the other side acknowledges)
	output logic        inv_req,
	output logic [31:5] inv_addr,
	input  logic        inv_ack,

	// snoop port
	input  logic        snoop_req,
	input  logic        snoop_we,
	input  logic [31:5] snoop_addr,
	output logic        snoop_ack,

	// memory port
	output logic        mem_req,
	output logic        mem_we,
	output logic        mem_line,
	output logic [31:2] mem_addr,
	output logic [3:0]  mem_be,
	output logic [255:0] mem_wdata,
	input  logic        mem_ack,
	input  logic [255:0] mem_rdata
);

import DSPPC604_pkg::*;

localparam int WAYS = 4;
localparam int SETS = 1 << IDXW;
localparam int TAGW = 27 - IDXW;            // address bits 31 down to 5+IDXW

typedef struct packed {
	logic            valid;
	logic            dirty;
	logic [TAGW-1:0] tag;
} tag_t;

// ---- the RAMs: one per way, so that a whole set is read at once -----------
// (the tags; the data in two DSPPC604_cache_ram per way, the even and the
// odd words, each giving the one word asked for: a read gives the word
// addressed and the next, which a wide access wants, without picking them
// out of the line; word 0 of a line is the lowest address, bits 255-224)
(* ramstyle = "no_rw_check" *) tag_t tag_mem [WAYS][SETS];
tag_t         tag_q  [WAYS];
tag_t         tag_ram_q [WAYS];
logic [31:0]  even_q [WAYS], odd_q [WAYS];
logic [2:0]   plru   [SETS];                // pseudo-LRU tree: [0] ways 01 vs 23, [1] 0 vs 1, [2] 2 vs 3

logic [IDXW-1:0]   rd_idx;                       // the set read at this edge
logic [2:0]   rd_word;                      // ... and the word (with the next: a wide access's)
logic [1:0]   rd_even, rd_odd;              // the slots read in the even and odd RAMs
wire  [2:0]   rd_word_next = rd_word + 3'd1;
logic [WAYS-1:0] tag_we;
logic [WAYS-1:0] data_we;
logic [7:0]   data_wwe;                     // words of the line written (bit j: bits 32j+31 downward)
logic [IDXW-1:0]   wr_idx;
tag_t         tag_wd;
logic [255:0] data_wd;

// A write decided from the tags just read (a store hit, a line zero, a cache
// instruction's or a snoop's invalidate) lands at the next edge, from these
// registers: the tag RAM's output, the compare and the way select are then
// not in front of the RAMs' write ports. A following word hit may use that
// set immediately: the pending write and a write coinciding with the RAM
// read are forwarded below. Snoops still wait for a pending same-set write.
logic            wr_pend;
logic [WAYS-1:0] l_tag_we, l_data_we, wr_tag_we, wr_data_we;
logic [7:0]      l_wwe, wr_wwe;
logic [IDXW-1:0]      wr_idx_q;
tag_t            l_tag_wd, wr_tag_wd;
logic [255:0]    l_data_wd, wr_data_wd;
logic            l_dzero, l_dwide;     // l_data_wd is zero (dcbz); ... has a wide store's second word

always_ff @(posedge clk) begin
	for (int w = 0; w < WAYS; w++) begin
		tag_ram_q[w] <= tag_mem[w][rd_idx];
		if (tag_we[w]) tag_mem[w][wr_idx] <= tag_wd;
	end
end

// data_wd's word 2s+1 (bits 32(6-2s) up) is the odd RAM's slot s, word 2s
// (bits 32(7-2s) up) the even RAM's; data_wwe likewise
genvar gw;
generate
	for (gw = 0; gw < WAYS; gw++) begin : way
		DSPPC604_cache_ram #(.IDXW (IDXW)) even
		(
			.clk   (clk),
			.raddr ({rd_idx, rd_even}),
			.q     (even_q[gw]),
			.we    ({4{data_we[gw]}} & {data_wwe[1], data_wwe[3], data_wwe[5], data_wwe[7]}),
			.waddr (wr_idx),
			.d     ({data_wd[63:32], data_wd[127:96], data_wd[191:160], data_wd[255:224]})
		);
		DSPPC604_cache_ram #(.IDXW (IDXW)) odd
		(
			.clk   (clk),
			.raddr ({rd_idx, rd_odd}),
			.q     (odd_q[gw]),
			.we    ({4{data_we[gw]}} & {data_wwe[0], data_wwe[2], data_wwe[4], data_wwe[6]}),
			.waddr (wr_idx),
			.d     ({data_wd[31:0], data_wd[95:64], data_wd[159:128], data_wd[223:192]})
		);
	end
endgenerate

// ---- the request in hand ---------------------------------------------------
typedef enum logic [3:0] {
	S_SWEEP,     // invalidating every set (after reset, inval_all)
	S_IDLE,
	S_LOOK,      // the set is out: hit or miss
	S_UNC,       // a word on the memory port, cache untouched
	S_WB,        // writing a line back: the victim, or what a cache instruction or snoop named
	S_FILL,      // reading the line
	S_RETRY,     // the line is in (or the victim gone): look again
	S_ICBI,      // waiting for the other side
	S_SNOOP,     // a snoop: the set is out
	S_PWAIT,     // the memory port is wanted while a posted write drains: look again after it
	S_WBREAD,    // reading the line to write back, two words a cycle
	S_UANS       // answering an uncached word from a register (its data came from the memory port)
} state_t;

state_t      state;
// A cache-inhibited word store (device registers, the frame buffer) is
// answered at once and written from here while the cache goes on; whatever
// next wants the memory port (a miss, a write-back, an uncached access, a
// snoop) waits until it is out, so the order on the port is kept.
logic        post_v;
logic [31:2] post_addr;
logic [3:0]  post_be;
logic [31:0] post_data;
logic        r_we;
ck_t         r_kind;
logic [31:2] r_addr;
logic [3:0]  r_be;
logic [31:0] r_wdata;
logic        r_wide;
logic        r_ci;
logic        r_wt;
logic        r_snoop;        // the request in hand is the snoop's
logic        r_snoop_we;
logic [1:0]  r_way;          // the way chosen for a write-back or fill
logic        r_after_wb;     // the write-back is followed by a fill
logic [255:0] wb_data;
logic [31:0] unc_data;       // an uncached word read, answered from here in S_UANS
logic [2:0]  wb_slot;        // S_WBREAD: the slot read at the end of this cycle (4: done)
logic [TAGW-1:0] wb_tag;
logic        inval_pend;
logic [IDXW-1:0]  sweep_idx;

wire [IDXW-1:0]  r_idx  = r_addr[IDXW+4:5];
wire [TAGW-1:0]  r_tag  = r_addr[31:IDXW+5];
wire [2:0]       r_word = r_addr[4:2];

// RAM read-during-write values are deliberately unspecified. Register the
// colliding write's enables and value at the read edge, then replace every
// affected word/tag. A queued write is newer and takes priority; this also
// permits back-to-back byte stores to merge against the latest whole word.
logic [WAYS-1:0] landed_tag_we, landed_tag_wq;
logic [7:0] landed_data_we [WAYS], landed_data_wq [WAYS];
logic [IDXW-1:0] landed_idx;                  // the set written at the read's edge
tag_t landed_tag;
logic [255:0] landed_data;
// the colliding write's words that the read wants (the word read and the
// next), picked out at the read's edge, when the word read is known
logic [31:0] landed_word, landed_word_next;
// The set compares are made in the answer's cycle, from registers: the
// set then read is r_idx (the request's payload is taken at the edge that
// reads it; checked below), so the incoming address, behind EX's adder and
// the MMU, is not in front of a compare at the read's edge.
always_ff @(posedge clk) begin
	landed_idx <= wr_idx;
	for (int w = 0; w < WAYS; w++) begin
		landed_tag_wq[w] <= tag_we[w] & ~reset;
		landed_data_wq[w] <= {8{data_we[w] & ~reset}} & data_wwe;
	end
	landed_tag <= tag_wd;
	landed_data <= data_wd;
	landed_word <= data_wd[255 - 32*rd_word -: 32];
	landed_word_next <= data_wd[255 - 32*rd_word_next -: 32];
end
wire landed_set = (landed_idx == r_idx);
always_comb
	for (int w = 0; w < WAYS; w++) begin
		landed_tag_we[w] = landed_tag_wq[w] & landed_set;
		landed_data_we[w] = landed_data_wq[w] & {8{landed_set}};
	end
// the pending write (registered from r_idx at the last edge, as wr_idx_q)
// is to the set the answer was read from
wire pending_set_match = (wr_idx_q == r_idx);
wire forward_pending = wr_pend & pending_set_match;
/* synthesis translate_off */
logic [IDXW-1:0] rd_idx_q;
always_ff @(posedge clk) begin
	rd_idx_q <= rd_idx;
	if (~reset & ((state == S_LOOK) | (state == S_SNOOP)) & (rd_idx_q != r_idx))
		$fatal(1, "the set answered is not the set read");
end
/* synthesis translate_on */
always_comb begin
	for (int w = 0; w < WAYS; w++)
		tag_q[w] = (forward_pending & wr_tag_we[w]) ? wr_tag_wd :
		           landed_tag_we[w] ? landed_tag : tag_ram_q[w];
end

// hit? One bit per way; the answer's way select takes these directly
// (each way's hit gates its own word), the encoded number serves the rest.
logic [WAYS-1:0] hit_w;
// Compare each candidate before selecting the newest forwarded tag. A
// pending write takes priority over the colliding write, then the RAM.
// Keep the comparisons separate so the wide tag mux is off the hit path.
(* keep = "true" *) wire pending_tag_hit = wr_tag_wd.valid && wr_tag_wd.tag == r_tag;
(* keep = "true" *) wire landed_tag_hit = landed_tag.valid && landed_tag.tag == r_tag;
(* keep = "true" *) wire [WAYS-1:0] ram_tag_hit;
genvar gh;
generate
	for (gh = 0; gh < WAYS; gh++) begin : parallel_tag_compare
		assign ram_tag_hit[gh] = tag_ram_q[gh].valid && tag_ram_q[gh].tag == r_tag;
	end
endgenerate
logic            hit /* verilator public_flat_rd */;
logic [1:0]      hit_sel;
always_comb begin
	hit_sel = 2'd0;
	for (int w = 0; w < WAYS; w++) begin
		hit_w[w] = (forward_pending & wr_tag_we[w]) ? pending_tag_hit :
		           landed_tag_we[w] ? landed_tag_hit : ram_tag_hit[w];
		if (hit_w[w]) hit_sel = w[1:0];
	end
	hit = |hit_w;
end

// the victim: an invalid way, else what the pseudo-LRU tree says
wire [2:0] tree = plru[r_idx];
logic [1:0] victim;
always_comb begin
	victim = tree[0] ? {1'b1, tree[2]} : {1'b0, tree[1]};
	for (int w = WAYS - 1; w >= 0; w--)
		if (!tag_q[w].valid) victim = w[1:0];
end
wire victim_dirty = tag_q[victim].valid & tag_q[victim].dirty;

// the tree after touching way w: the next victim is the other branch everywhere
function automatic logic [2:0] touch(input logic [2:0] t, input logic [1:0] w);
	begin
		touch = t;
		touch[0] = ~w[1];
		if (w[1]) touch[2] = ~w[0];
		else      touch[1] = ~w[0];
	end
endfunction

wire k_word  = (r_kind == CK_WORD);
wire k_zero  = (r_kind == CK_ZERO);
wire k_flush = (r_kind == CK_FLUSH);
wire k_store = (r_kind == CK_STORE);
wire k_inval = (r_kind == CK_INVAL);
wire k_icbi  = (r_kind == CK_ICBI);

// an uncached word: cache-inhibited, cache disabled, a miss with the cache
// locked, or a store miss on a write-through page
wire unc = k_word & (r_ci | ~enable | (lock & ~hit) | (WRITABLE & r_we & r_wt & ~hit));

wire [1:0] wsel = hit ? hit_sel : victim;   // the way a line-zero takes

// the answer: as decided in this cycle, or from a register a cycle later
logic        ans_now, ans_q;
logic [31:0] ans_data, ans_data_q;
logic        ans_wide, ans_wide_q;
logic [31:0] ans_data_next, ans_data_next_q;
always_ff @(posedge clk) begin
	ans_q      <= ans_now & ~reset;
	ans_data_q <= ans_data;
	ans_wide_q <= ans_wide;
	ans_data_next_q <= ans_data_next;
end
assign rvalid = LATE_ANSWER ? ans_q      : ans_now;
assign rdata  = LATE_ANSWER ? ans_data_q : ans_data;
assign rvalid_wide = LATE_ANSWER ? ans_wide_q : ans_wide;
assign rdata_next = LATE_ANSWER ? ans_data_next_q : ans_data_next;

// the word a read delivers: the word is picked within each way first
// (its index is known before the tags are compared), the way last, so that
// only a four-way choice follows the compare
logic [31:0] way_word [WAYS];
logic [31:0] way_word_next [WAYS];
wire [2:0] r_word_next = r_word + 3'd1;
wire [2:0] word_bit = 3'd7 - r_word;
wire [2:0] word_bit_next = 3'd7 - r_word_next;
// the pending write's words that the read wants, picked out when that
// write was registered (below)
// (the stored word and a wide store's second registered as they are, and
// which of them the read wants chosen in the answer's cycle from the two
// word numbers, both registers then: the next access's address is not in
// front of them)
logic [31:0] pending_st, pending_wn;
logic        pending_dwide;
logic [2:0]  pending_wword;              // the pending write's first word
wire [31:0] pending_word      = (pending_dwide & (r_word == pending_wword + 3'd1)) ? pending_wn : pending_st;
wire [31:0] pending_word_next = (pending_dwide & (r_word == pending_wword)) ? pending_wn : pending_st;
always_comb
	for (int w = 0; w < WAYS; w++) begin
		// The RAMs give the word and the next (even and odd, in either
		// order); a pending or colliding write of either replaces it.
		way_word[w] = (forward_pending & wr_data_we[w] & wr_wwe[word_bit]) ? pending_word :
		              landed_data_we[w][word_bit] ? landed_word : (r_word[0] ? odd_q[w] : even_q[w]);
		way_word_next[w] = (forward_pending & wr_data_we[w] & wr_wwe[word_bit_next]) ? pending_word_next :
		                   landed_data_we[w][word_bit_next] ? landed_word_next : (r_word[0] ? even_q[w] : odd_q[w]);
	end
logic [31:0] hit_word;
logic [31:0] hit_word_next;
always_comb begin
	hit_word = '0;
	hit_word_next = '0;
	for (int w = 0; w < WAYS; w++) begin
		hit_word |= way_word[w] & {32{hit_w[w]}};
		hit_word_next |= way_word_next[w] & {32{hit_w[w]}};
	end
end

// the store's bytes merged into that word, which is then written whole
logic [31:0] st_mask;
always_comb for (int j = 0; j < 4; j++) st_mask[8*j +: 8] = {8{r_be[j]}};
wire [31:0] st_word = (hit_word & ~st_mask) | (wdata & st_mask);
wire [7:0]  st_wwe  = 8'd1 << (3'd7 - r_word);
wire wide_hit = r_wide & (r_word != 3'd7);
// A wide word request (no snoop) is answered wide when it is cached: not
// cache-inhibited, the cache on and not locked, and not a write-through
// store (which memory takes a word at a time). A miss is filled and looked
// at again, then answered wide. From the request's registers only.
assign wide_sure = WRITABLE & k_word & wide_hit & ~r_ci & enable & ~lock & ~(r_we & r_wt) & ~r_snoop;
wire [7:0] st_wwe_next = 8'd1 << (3'd6 - r_word);

// A cached word hit can admit the next request. Writes to the same set are
// covered by forwarding; a write-through store still waits for memory.
wire wr_sclash = wr_pend & (snoop_addr[IDXW+4:5] == wr_idx_q);
wire word_hit = (state == S_LOOK) & k_word & hit & ~unc & (~r_we | ~r_wt) & ~r_snoop;
// (an uncached word's answer from its register takes the next request too)
wire can_take = ((state == S_IDLE) | word_hit | (state == S_UANS)) & ~snoop_req & ~inval_all & ~inval_pend;
assign gnt = can_take & req;
wire payload_take = (state == S_IDLE) | word_hit | ((state == S_UANS) & ~snoop_req);
wire payload_snoop = (state == S_IDLE) & snoop_req;   // a snoop's registers instead (it wins, when it goes)
assign slow = (state != S_IDLE) & (state != S_LOOK);

// the posted write: taken by a word store that memory must get (cache-
// inhibited, write-through, the cache off) found in S_LOOK while the buffer
// is free (a write-through hit updates its line as well); driven on the
// memory port whenever the cache itself is not using it (never at once:
// below); S_LOOK goes to S_PWAIT instead of any state that uses the port
// while it is full. A wide write-through hit is not posted: its answer
// covers one word, the memory unit sends the second. (Never in a cycle
// that takes the next request:
// word_hit leaves these out.)
wire post_take = WRITABLE & (state == S_LOOK) & k_word & r_we & ~post_v & (unc | (enable & hit & r_wt & ~wide_hit));
wire post_drv  = post_v & (state != S_UNC) & (state != S_WB) & (state != S_FILL);
wire look_port = (state == S_LOOK) & ~post_take &
                 (unc ? 1'b1 :
                  enable & (k_word ? (hit ? (WRITABLE & r_we & r_wt) : 1'b1) :
                            k_zero ? (~hit & victim_dirty) :
                            ((k_flush | k_store) & hit & tag_q[hit_sel].dirty)));
assign posted = post_v;

always_comb begin
	tag_we    = '0;
	data_we   = '0;
	data_wwe  = '1;
	wr_idx    = r_idx;
	tag_wd    = {1'b1, 1'b0, r_tag};
	data_wd   = mem_rdata;
	l_tag_we  = '0;
	l_data_we = '0;
	l_wwe     = '1;
	l_tag_wd  = {1'b1, 1'b0, r_tag};
	l_data_wd = {8{st_word}};
	l_dzero   = 1'b0;
	l_dwide   = 1'b0;
	// Read the candidate set even if it is not granted. Only a granted
	// request consumes that read; preserve a dirty victim before replacing it.
	rd_idx    = (state == S_IDLE) ? (snoop_req ? snoop_addr[IDXW+4:5] : addr[IDXW+4:5]) :
	            ((state == S_LOOK) | (state == S_UANS)) ? addr[IDXW+4:5] : r_idx;
	rd_word   = (state == S_IDLE) ? (snoop_req ? 3'd0 : addr[4:2]) :
	            ((state == S_LOOK) | (state == S_UANS)) ? addr[4:2] : r_word;
	// the word and the next: word k is the odd RAM's slot k/2 if k is odd,
	// else the even RAM's; the next one is the other RAM's, slot (k+1)/2 in
	// the even one (a wide access never starts at word 7)
	rd_even   = (state == S_WBREAD) ? wb_slot[1:0] : 2'((rd_word + 3'd1) >> 1);
	rd_odd    = (state == S_WBREAD) ? wb_slot[1:0] : rd_word[2:1];
	ans_now    = 1'b0;
	ans_data     = hit_word;
	ans_wide = 1'b0;
	ans_data_next = hit_word_next;
	snoop_ack = 1'b0;
	inv_req   = 1'b0;
	inv_addr  = r_addr[31:5];
	mem_req   = 1'b0;
	mem_we    = 1'b0;
	mem_line  = 1'b1;
	mem_addr  = r_addr;
	mem_be    = r_be;
	mem_wdata = WRITABLE ? wb_data : '0;

	case (state)
	S_SWEEP: begin
		wr_idx = sweep_idx;
		tag_wd = '0;
		tag_we = '1;
	end

	S_LOOK: begin
		if (unc) ans_now = post_take;                    // -> S_UNC, or posted (answered now)
		else if (~enable) ans_now = 1'b1;                 // a cache instruction with the cache off
		else if (k_word & hit) begin
			ans_now = 1'b1;
			ans_wide = wide_hit;
			if (WRITABLE & r_we) begin
				l_data_we[hit_sel] = 1'b1;
				l_wwe = st_wwe;
				if (wide_hit) begin
					l_wwe = st_wwe | st_wwe_next;
					l_dwide = 1'b1;
					for (int j = 0; j < 8; j++)
						if (j[2:0] == (3'd6 - r_word)) l_data_wd[32*j +: 32] = wdata_next;
				end
				l_tag_we[hit_sel] = ~r_wt;               // dirty, unless memory gets it too
				l_tag_wd = {1'b1, 1'b1, r_tag};
				if (r_wt) ans_now = post_take;            // posted, else -> S_UNC
			end
		end
		else if (k_word) ;                               // a miss -> S_WB or S_FILL
		else if (k_zero) begin
			if (~hit & victim_dirty) ;                   // -> S_WB, then again
			else begin
				l_data_we[wsel] = 1'b1;
				l_data_wd = '0;
				l_dzero = 1'b1;
				l_tag_we[wsel] = 1'b1;
				l_tag_wd = {1'b1, 1'b1, r_tag};
				ans_now = 1'b1;
			end
		end
		else if ((k_flush | k_store) & hit & tag_q[hit_sel].dirty) ;   // -> S_WB
		else if (k_flush | k_inval) begin
			if (hit) begin l_tag_we[hit_sel] = 1'b1; l_tag_wd = '0; end
			ans_now = 1'b1;
		end
		else if (k_store) ans_now = 1'b1;
		else if (k_icbi) inv_req = 1'b1;                 // -> S_ICBI
		else ans_now = 1'b1;
	end

	S_UNC: begin
		mem_req   = 1'b1;
		mem_we    = r_we;
		mem_line  = 1'b0;
		mem_wdata = {224'd0, r_wdata};
		// (answered next cycle, from unc_data: the memory port's data comes
		// across the clock crossing and the machine's map, which is not to be
		// in front of the load's bytes and WB)
	end

	S_UANS: begin
		ans_now  = 1'b1;
		ans_data = unc_data;
	end

	S_WB: if (WRITABLE) begin                        // (never entered by a read-only cache)
		mem_req  = 1'b1;
		mem_we   = 1'b1;
		mem_addr = {wb_tag, r_idx, 3'b000};
		if (mem_ack) begin
			// the line is clean now; gone, if it was flushed, snooped for a
			// write, or is making room for a line-zero
			tag_we[r_way] = 1'b1;
			tag_wd = {~(r_snoop_we | k_flush | k_zero), 1'b0, wb_tag};
			if (~r_after_wb & ~k_zero) begin
				ans_now    = ~r_snoop;
				snoop_ack = r_snoop;
			end
		end
	end

	S_FILL: begin
		mem_req = 1'b1;
		if (mem_ack) begin
			data_we[r_way] = 1'b1;
			tag_we[r_way]  = 1'b1;
		end
	end

	S_ICBI: begin
		inv_req = 1'b1;
		ans_now  = inv_ack;
	end

	S_SNOOP: begin
		if (~enable) snoop_ack = 1'b1;
		else if (hit & tag_q[hit_sel].dirty) ;           // -> S_WB
		else begin
			if (hit & r_snoop_we) begin l_tag_we[hit_sel] = 1'b1; l_tag_wd = '0; end
			snoop_ack = 1'b1;
		end
	end

	default: ;
	endcase

	if (post_drv) begin                                  // the posted write, when the port is free
		mem_req   = 1'b1;
		mem_we    = 1'b1;
		mem_line  = 1'b0;
		mem_addr  = post_addr;
		mem_be    = post_be;
		mem_wdata = {224'd0, post_data};
	end

	if (wr_pend) begin                                   // the write decided in the last cycle
		tag_we   = wr_tag_we;
		data_we  = wr_data_we;
		data_wwe = wr_wwe;
		wr_idx   = wr_idx_q;
		tag_wd   = wr_tag_wd;
		data_wd  = wr_data_wd;
	end
end

always_ff @(posedge clk) begin
	wr_pend    <= ((|l_tag_we) | (|l_data_we)) & ~reset;
	wr_tag_we  <= l_tag_we;
	wr_data_we <= l_data_we;
	wr_wwe     <= l_wwe;
	wr_idx_q   <= r_idx;
	wr_tag_wd  <= l_tag_wd;
	wr_data_wd <= l_data_wd;
	// the words of it that the read made at this edge wants (l_data_wd is
	// the stored word in every position, but a wide store's second word in
	// the next, or all zero), so that a forwarded word is not picked out of
	// the line in the answer's cycle
	pending_st    <= l_dzero ? 32'd0 : st_word;
	pending_wn    <= wdata_next;
	pending_dwide <= l_dwide & ~l_dzero;
	pending_wword <= r_word;
end

/* synthesis translate_off */
always_ff @(posedge clk) begin
	if (~reset & (state == S_LOOK))
		for (int w = 0; w < WAYS; w++) begin
			if (forward_pending & wr_data_we[w] & wr_wwe[word_bit] &
			    (pending_word != wr_data_wd[255 - 32*r_word -: 32]))
				$fatal(1, "forwarded pending word differs");
			if (forward_pending & wr_data_we[w] & wr_wwe[word_bit_next] & r_wide &
			    (pending_word_next != wr_data_wd[255 - 32*r_word_next -: 32]))
				$fatal(1, "forwarded pending next word differs");
			if (landed_data_we[w][word_bit] & (landed_word != landed_data[255 - 32*r_word -: 32]))
				$fatal(1, "forwarded colliding word differs");
		end
end
/* synthesis translate_on */

always_ff @(posedge clk) begin
	if ((state == S_LOOK) | (state == S_SNOOP)) wb_tag <= tag_q[wsel].tag;
	// the line to write back: slot s of both RAMs is read at the end of
	// the cycle with wb_slot s, and taken in the next
	if (state == S_WBREAD) begin
		wb_slot <= wb_slot + 3'd1;
		for (int k = 0; k < 4; k++)
			if (wb_slot == 3'(k + 1)) begin
				wb_data[255 - 64*k -: 32] <= even_q[r_way];
				wb_data[223 - 64*k -: 32] <= odd_q[r_way];
			end
	end
	else wb_slot <= 3'd0;
	if (inval_all) inval_pend <= 1'b1;
	// the store's data, for S_UNC: it is presented in the lookup's cycle
	if (state == S_LOOK) r_wdata <= wdata;

	// The request's payload is taken in every cycle a request could be (the
	// cache idle, or answering a word hit that leaves for S_IDLE or the next
	// request): the late request, behind the MMU's translation, then enables
	// only the state and the few control registers, not these 70-odd. In
	// those cycles nothing still needs the old values.
	// (r_addr's set index is read in a cycle only by the request then being
	// answered, and the pending write's set match is taken at the edge
	// leaving that cycle, so a payload taken at that edge disturbs neither.)
	if (payload_take) begin
		r_addr       <= payload_snoop ? {snoop_addr, 3'b000} : addr;
		r_kind       <= payload_snoop ? CK_WORD : kind;
		r_we         <= ~payload_snoop & we;
		r_snoop      <= payload_snoop;
		r_snoop_we   <= payload_snoop & snoop_we;
		r_after_wb   <= 1'b0;
		r_be         <= be;
		r_wide       <= wide;
		r_ci         <= ci;
		r_wt         <= wt;
	end

	case (state)
	S_SWEEP: begin
		sweep_idx <= sweep_idx + 1'd1;
		if (sweep_idx == IDXW'(SETS-1)) state <= S_IDLE;
	end

	S_IDLE: begin
		if (inval_all | inval_pend) begin
			state      <= S_SWEEP;
			sweep_idx  <= '0;
			inval_pend <= 1'b0;
		end
		else if (snoop_req) begin                  // (a clashing snoop waits, and so does the request: as gnt)
			if (~wr_sclash & ~post_v) begin       // (and after a posted write is out)
				state      <= S_SNOOP;             // (its registers: the payload, above)
			end
		end
		else if (req) begin                       // (as gnt)
			state      <= S_LOOK;
		end
	end

	S_LOOK: begin
		if (post_take) begin
			if (~unc) plru[r_idx] <= touch(tree, hit_sel);
			state <= S_IDLE;
		end
		else if (unc) state <= S_UNC;
		else if (~enable) state <= S_IDLE;
		else if (k_word & hit) begin
			plru[r_idx] <= touch(tree, hit_sel);
			state <= (WRITABLE & r_we & r_wt) ? S_UNC : gnt ? S_LOOK : S_IDLE;
			if (gnt) begin
				// the next request, taken behind this word hit
			end
		end
		else if (k_word) begin
			r_way      <= victim;
			r_after_wb <= 1'b1;
			state      <= victim_dirty ? S_WBREAD : S_FILL;
		end
		else if (k_zero) begin
			if (~hit & victim_dirty) begin
				r_way <= victim;
				state <= S_WBREAD;
			end
			else begin
				plru[r_idx] <= touch(tree, wsel);
				state <= S_IDLE;
			end
		end
		else if ((k_flush | k_store) & hit & tag_q[hit_sel].dirty) begin
			r_way <= hit_sel;
			state <= S_WBREAD;
		end
		else if (k_icbi) state <= S_ICBI;
		else state <= S_IDLE;
	end

	S_UNC: if (mem_ack) begin
		unc_data <= mem_rdata[31:0];
		state    <= S_UANS;
	end
	S_UANS: state <= gnt ? S_LOOK : S_IDLE;
	S_PWAIT: if (~post_v) state <= S_LOOK;
	S_WBREAD: if (wb_slot == 3'd4) state <= S_WB;

	S_WB: if (mem_ack) begin
		if (r_after_wb)  state <= S_FILL;
		else if (k_zero) state <= S_RETRY;
		else             state <= S_IDLE;
	end

	S_FILL: if (mem_ack) begin
		plru[r_idx] <= touch(tree, r_way);
		state <= S_RETRY;
	end

	S_RETRY: state <= S_LOOK;

	S_ICBI: if (inv_ack) state <= S_IDLE;

	S_SNOOP: begin
		if (enable & hit & tag_q[hit_sel].dirty) begin
			r_way <= hit_sel;
			state <= S_WBREAD;
		end
		else state <= S_IDLE;
	end

	default: state <= S_IDLE;
	endcase

	// a lookup that wants the memory port while a posted write is out
	// waits for it, then looks again
	if (look_port & post_v) state <= S_PWAIT;

	if (post_take) begin
		post_v    <= 1'b1;
		post_addr <= r_addr;
		post_be   <= r_be;
		post_data <= wdata;
	end
	if (post_drv & mem_ack) post_v <= 1'b0;

	if (reset) begin
		state      <= S_SWEEP;
		sweep_idx  <= '0;
		inval_pend <= 1'b0;
		post_v     <= 1'b0;
	end
end

endmodule

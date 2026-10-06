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
//  until gnt, which comes in any cycle the cache is idle, or is answering a
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
	parameter bit LATE_ANSWER = 0            // rvalid and rdata from a register, a cycle later
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
	input  logic        ci,                  // cache-inhibited (WIMG I)
	input  logic        wt,                  // write-through (WIMG W)
	output logic        gnt,
	output logic        rvalid,
	output logic [31:0] rdata,

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
localparam int SETS = 128;
localparam int TAGW = 20;                   // address bits 31-12

typedef struct packed {
	logic            valid;
	logic            dirty;
	logic [TAGW-1:0] tag;
} tag_t;

// ---- the RAMs: one per way, so that a whole set is read at once -----------
// (the data in DSPPC604_cache_ram, eight word RAMs, a write enable each;
// word 0 of a line is the lowest address, bits 255-224)
(* ramstyle = "no_rw_check" *) tag_t tag_mem [WAYS][SETS];
tag_t         tag_q  [WAYS];
logic [255:0] data_q [WAYS];
logic [2:0]   plru   [SETS];                // pseudo-LRU tree: [0] ways 01 vs 23, [1] 0 vs 1, [2] 2 vs 3

logic [6:0]   rd_idx;                       // the set read at this edge
logic [WAYS-1:0] tag_we;
logic [WAYS-1:0] data_we;
logic [7:0]   data_wwe;                     // words of the line written (bit j: bits 32j+31 downward)
logic [6:0]   wr_idx;
tag_t         tag_wd;
logic [255:0] data_wd;

always_ff @(posedge clk) begin
	for (int w = 0; w < WAYS; w++) begin
		tag_q[w] <= tag_mem[w][rd_idx];
		if (tag_we[w]) tag_mem[w][wr_idx] <= tag_wd;
	end
end

genvar gw;
generate
	for (gw = 0; gw < WAYS; gw++) begin : way
		DSPPC604_cache_ram data
		(
			.clk   (clk),
			.raddr (rd_idx),
			.q     (data_q[gw]),
			.we    ({8{data_we[gw]}} & data_wwe),
			.waddr (wr_idx),
			.d     (data_wd)
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
	S_SNOOP      // a snoop: the set is out
} state_t;

state_t      state;
logic        r_we;
ck_t         r_kind;
logic [31:2] r_addr;
logic [3:0]  r_be;
logic [31:0] r_wdata;
logic        r_ci;
logic        r_wt;
logic        r_snoop;        // the request in hand is the snoop's
logic        r_snoop_we;
logic [1:0]  r_way;          // the way chosen for a write-back or fill
logic        r_after_wb;     // the write-back is followed by a fill
logic        inval_pend;
logic [6:0]  sweep_idx;

wire [6:0]       r_idx  = r_addr[11:5];
wire [TAGW-1:0]  r_tag  = r_addr[31:12];
wire [2:0]       r_word = r_addr[4:2];

// hit? One bit per way; the answer's way select takes these directly
// (each way's hit gates its own word), the encoded number serves the rest.
logic [WAYS-1:0] hit_w;
logic            hit;
logic [1:0]      hit_sel;
always_comb begin
	hit_sel = 2'd0;
	for (int w = 0; w < WAYS; w++) begin
		hit_w[w] = tag_q[w].valid && tag_q[w].tag == r_tag;
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
always_ff @(posedge clk) begin
	ans_q      <= ans_now & ~reset;
	ans_data_q <= ans_data;
end
assign rvalid = LATE_ANSWER ? ans_q      : ans_now;
assign rdata  = LATE_ANSWER ? ans_data_q : ans_data;

// the word a read delivers: the word is picked within each way first
// (its index is known before the tags are compared), the way last, so that
// only a four-way choice follows the compare
logic [31:0] way_word [WAYS];
always_comb
	for (int w = 0; w < WAYS; w++) way_word[w] = data_q[w][255 - 32*r_word -: 32];
logic [31:0] hit_word;
always_comb begin
	hit_word = '0;
	for (int w = 0; w < WAYS; w++) hit_word |= way_word[w] & {32{hit_w[w]}};
end

// the store's bytes merged into that word, which is then written whole
logic [31:0] st_mask;
always_comb for (int j = 0; j < 4; j++) st_mask[8*j +: 8] = {8{r_be[j]}};
wire [31:0] st_word = (hit_word & ~st_mask) | (r_wdata & st_mask);
wire [7:0]  st_wwe  = 8'd1 << (3'd7 - r_word);

// a read hit being answered: the next request can come in behind it
wire read_hit = (state == S_LOOK) & k_word & hit & ~unc & ~r_we & ~r_snoop;
wire can_take = ((state == S_IDLE) | read_hit) & ~snoop_req & ~inval_all & ~inval_pend;
assign gnt = can_take & req;

always_comb begin
	tag_we    = '0;
	data_we   = '0;
	data_wwe  = '1;
	wr_idx    = r_idx;
	tag_wd    = {1'b1, 1'b0, r_tag};
	data_wd   = mem_rdata;
	rd_idx    = (state == S_IDLE) ? (snoop_req ? snoop_addr[11:5] : addr[11:5]) : gnt ? addr[11:5] : r_idx;
	ans_now    = 1'b0;
	ans_data     = hit_word;
	snoop_ack = 1'b0;
	inv_req   = 1'b0;
	inv_addr  = r_addr[31:5];
	mem_req   = 1'b0;
	mem_we    = 1'b0;
	mem_line  = 1'b1;
	mem_addr  = r_addr;
	mem_be    = r_be;
	mem_wdata = data_q[r_way];

	case (state)
	S_SWEEP: begin
		wr_idx = sweep_idx;
		tag_wd = '0;
		tag_we = '1;
	end

	S_LOOK: begin
		if (unc) ;                                       // -> S_UNC
		else if (~enable) ans_now = 1'b1;                 // a cache instruction with the cache off
		else if (k_word & hit) begin
			ans_now = 1'b1;
			if (WRITABLE & r_we) begin
				data_we[hit_sel] = 1'b1;
				data_wwe = st_wwe;
				data_wd  = {8{st_word}};
				tag_we[hit_sel] = ~r_wt;                 // dirty, unless memory gets it too
				tag_wd = {1'b1, 1'b1, r_tag};
				if (r_wt) ans_now = 1'b0;                 // -> S_UNC
			end
		end
		else if (k_word) ;                               // a miss -> S_WB or S_FILL
		else if (k_zero) begin
			if (~hit & victim_dirty) ;                   // -> S_WB, then again
			else begin
				data_we[wsel] = 1'b1;
				data_wd = '0;
				tag_we[wsel] = 1'b1;
				tag_wd = {1'b1, 1'b1, r_tag};
				ans_now = 1'b1;
			end
		end
		else if ((k_flush | k_store) & hit & tag_q[hit_sel].dirty) ;   // -> S_WB
		else if (k_flush | k_inval) begin
			if (hit) begin tag_we[hit_sel] = 1'b1; tag_wd = '0; end
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
		if (mem_ack) begin
			ans_now = 1'b1;
			ans_data  = mem_rdata[31:0];
		end
	end

	S_WB: begin
		mem_req  = 1'b1;
		mem_we   = 1'b1;
		mem_addr = {tag_q[r_way].tag, r_idx, 3'b000};
		if (mem_ack) begin
			// the line is clean now; gone, if it was flushed, snooped for a
			// write, or is making room for a line-zero
			tag_we[r_way] = 1'b1;
			tag_wd = {~(r_snoop_we | k_flush | k_zero), 1'b0, tag_q[r_way].tag};
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
			if (hit & r_snoop_we) begin tag_we[hit_sel] = 1'b1; tag_wd = '0; end
			snoop_ack = 1'b1;
		end
	end

	default: ;
	endcase
end

always_ff @(posedge clk) begin
	if (inval_all) inval_pend <= 1'b1;

	case (state)
	S_SWEEP: begin
		sweep_idx <= sweep_idx + 7'd1;
		if (sweep_idx == 7'd127) state <= S_IDLE;
	end

	S_IDLE: begin
		if (inval_all | inval_pend) begin
			state      <= S_SWEEP;
			sweep_idx  <= 7'd0;
			inval_pend <= 1'b0;
		end
		else if (snoop_req) begin
			state      <= S_SNOOP;
			r_addr     <= {snoop_addr, 3'b000};
			r_snoop    <= 1'b1;
			r_snoop_we <= snoop_we;
			r_kind     <= CK_WORD;
			r_we       <= 1'b0;
			r_after_wb <= 1'b0;
		end
		else if (req) begin
			state      <= S_LOOK;
			r_we       <= we;
			r_kind     <= kind;
			r_addr     <= addr;
			r_be       <= be;
			r_wdata    <= wdata;
			r_ci       <= ci;
			r_wt       <= wt;
			r_snoop    <= 1'b0;
			r_snoop_we <= 1'b0;
			r_after_wb <= 1'b0;
		end
	end

	S_LOOK: begin
		if (unc) state <= S_UNC;
		else if (~enable) state <= S_IDLE;
		else if (k_word & hit) begin
			plru[r_idx] <= touch(tree, hit_sel);
			state <= (WRITABLE & r_we & r_wt) ? S_UNC : gnt ? S_LOOK : S_IDLE;
			if (gnt) begin
				// the next request, taken behind this read hit
				r_we       <= we;
				r_kind     <= kind;
				r_addr     <= addr;
				r_be       <= be;
				r_wdata    <= wdata;
				r_ci       <= ci;
				r_wt       <= wt;
				r_after_wb <= 1'b0;
			end
		end
		else if (k_word) begin
			r_way      <= victim;
			r_after_wb <= 1'b1;
			state      <= victim_dirty ? S_WB : S_FILL;
		end
		else if (k_zero) begin
			if (~hit & victim_dirty) begin
				r_way <= victim;
				state <= S_WB;
			end
			else begin
				plru[r_idx] <= touch(tree, wsel);
				state <= S_IDLE;
			end
		end
		else if ((k_flush | k_store) & hit & tag_q[hit_sel].dirty) begin
			r_way <= hit_sel;
			state <= S_WB;
		end
		else if (k_icbi) state <= S_ICBI;
		else state <= S_IDLE;
	end

	S_UNC: if (mem_ack) state <= S_IDLE;

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
			state <= S_WB;
		end
		else state <= S_IDLE;
	end

	default: state <= S_IDLE;
	endcase

	if (reset) begin
		state      <= S_SWEEP;
		sweep_idx  <= 7'd0;
		inval_pend <= 1'b0;
	end
end

endmodule

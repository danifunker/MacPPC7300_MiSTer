//============================================================================
//
//  DSPPC604 - PowerPC 604-class CPU core
//  Data memory access unit
//
//  Turns one load or store into one or two word-aligned bus accesses, and
//  converts between register values and bytes in memory (big-endian,
//  byte-reversed, sign-extended, or the left-justified bytes of the string
//  instructions).
//
//    1 to 4 bytes   at any address; two bus accesses if a word boundary is
//                   crossed
//    8 bytes        a double, at a word-aligned address only (the 604 takes
//                   an alignment exception otherwise); one access on a
//                   wide cache hit, otherwise two word accesses
//    kind           other than a load or store (the cache instructions): one
//                   request, which the cache carries out; no data moves
//
//  Handshake: a request is accepted with req_valid and req_ready. Its
//  response is high for one cycle. A store has been written, and a load's
//  rdata is valid, in that cycle. With resp_fault the access was not made
//  (or only its first word was) and the requester takes a DSI. One more
//  request may be accepted while one is under way: it waits (two
//  descriptors, used in turn) and starts when the first has answered.
//  final_q says, from registers, that the access under way has been
//  granted its last bus access: it can no longer fault or be interrupted,
//  so later instructions may complete ahead of its answer.
//
//  Bus: word-aligned address, four byte enables. be[3] and bits 31:24 are the
//  byte at the lowest address. req is held with a stable request until a
//  cycle with gnt; one rvalid follows each granted request, at least one
//  cycle later. rvalid with fault means the word could not be translated.
//
//============================================================================

module DSPPC604_mem_unit
(
	input  logic        clk,
	input  logic        reset,

	input  logic        req_valid,
	input  logic        we,
	input  DSPPC604_pkg::ck_t kind,
	input  logic [31:0] addr,
	input  logic [3:0]  nbytes,      // 1 to 4, or 8
	input  logic        sext,        // load: sign-extend a halfword
	input  logic        brev,        // byte-reversed
	input  logic        ljust,       // string: bytes at the top of the register
	input  logic [63:0] wdata,       // value to store (low word unless 8 bytes)
	input  logic        conv,        // ... a double to store as a single (stfs)
	input  logic [31:0] wconv,       // ... that single (converted by the caller)
	output logic        req_ready,
	output logic        pending_ungranted, // accepted descriptor with no bus side effect
	output logic        final_q,           // the access under way has had its last grant

	output logic        resp_valid,
	output logic        resp_fault,
	output logic [63:0] rdata,       // value loaded (low word unless 8 bytes)
	output logic        rden,        // ... a word that is a denormal single (lfs: an aligned word, the cache's as it is)

	output logic        dbus_req,
	output logic        dbus_we,
	output DSPPC604_pkg::ck_t dbus_kind,
	output logic [29:0] dbus_addr,
	output logic [31:0] dbus_ea,     // original byte address of this bus operation
	output logic        dbus_direct, // dbus_addr is addr itself (this cycle's request, passed through)
	output logic [29:0] dbus_addr_held, // dbus_addr when it is not: from the descriptor's registers only
	output logic [3:0]  dbus_be,
	output logic [31:0] dbus_wdata,  // in the answer's cycle, from the descriptor (the cache reads it then)
	output logic        dbus_wide,
	output logic [31:0] dbus_wdata_next,
	input  logic        dbus_gnt,
	input  logic        dbus_sure,   // while answering (S_RSP0): the access is wide and the cache will answer it wide
	input  logic        dbus_rvalid,
	input  logic        dbus_fault,
	input  logic [31:0] dbus_rdata,
	input  logic        dbus_rwide,
	input  logic [31:0] dbus_rdata_next,
	// the data cache's answer before its way choice (DSPPC604_cache way_*)
	input  logic [3:0][31:0] way_rdata,
	input  logic [3:0][31:0] way_rdata_next,
	input  logic [3:0]  way_hit,
	input  logic        way_look
);

import DSPPC604_pkg::*;

typedef enum logic [2:0] {
	S_REQ0,      // descriptor slot empty; candidate first word may bypass
	S_HOLD0,     // accepted descriptor waiting for its first bus grant
	S_RSP0,
	S_REQ1,      // second word
	S_RSP1
} state_t;

state_t      state;
logic [31:0] word0_q;

// a descriptor, with the load's byte placement decoded when it is accepted
typedef struct packed {
	logic        we, brev, ljust;
	ck_t         kind;
	logic [31:0] addr;
	logic [29:0] next_word;
	logic [3:0]  nbytes;
	logic [3:0][7:0] load_select;
	logic [7:0]  sign_select;
	logic [3:0]  load_sext;
	logic [63:0] wdata;
	logic        conv;
	logic [31:0] wconv;     // stfs: the double, converted as the descriptor is written
	logic        tw;        // two words (two_words_of), made as it is written
} desc_t;

// Two descriptors used in turn: cp names the one under way (or the next
// one, while idle). A request accepted while one is under way waits in the
// other (qv). Accepting writes the descriptor at a registered position, so
// the wide payload's enable does not wait for the cache's answer; only
// cp, qv and the state do.
(* ramstyle = "logic" *) desc_t desc [2];
logic        cp, qv;
desc_t       c;
assign c = desc[cp];

wire       dword     = c.nbytes[3];
// (each descriptor's, cp only selecting: it is in front of MEM's room)
function automatic logic two_words_of(input desc_t d);
	logic [2:0] l;
	l = {1'b0, d.addr[1:0]} + d.nbytes[2:0] - 3'd1;
	two_words_of = (d.kind == CK_WORD) & (d.nbytes[3] | l[2]);
endfunction
wire       two_words0 = desc[0].tw;
wire       two_words1 = desc[1].tw;
wire       two_words = cp ? two_words1 : two_words0;

// Present the candidate first word throughout its response phase, so the
// returning cache hit never selects an address before MMU translation.
// A two-word fallback returns to S_REQ0 before accepting the next access.
wire second = (state == S_REQ1) | (state == S_RSP1);
wire saved = second | (state == S_HOLD0);
wire first_slot = ~qv & ((state == S_REQ0) | ((state == S_RSP0) & resp_valid));
wire [31:0] bus_ea = saved ? c.addr : addr;
wire [3:0] bus_nbytes = saved ? c.nbytes : nbytes;
wire [2:0] bus_n = bus_nbytes[2:0];
wire bus_touch = ((saved ? c.kind : kind) != CK_WORD);

// ---- store: register value to bytes, first byte in bits 31:24 --------------
// From the descriptor under way, for the cache's lookup cycle (S_RSP0 for
// the first word, S_RSP1 for the second): the store's data is not in front
// of the request (the cache takes it a cycle after the grant), and stfs's
// conversion is made here rather than in EX.
// stfs's double is converted in EX, from each forwarding source before the
// choice among them, and written with the descriptor (wconv), so the
// conversion is not in the cache's lookup cycle and the store does not wait
// Each descriptor's window is shaped from its own fields; cp only selects
// the result (it is not in front of the shifts).
function automatic logic [63:0] store_window(input desc_t d);
	logic [31:0] w, sb;
	logic [2:0]  k;
	w = d.conv ? d.wconv : d.wdata[31:0];
	k = d.nbytes[2:0];
	if (d.brev)         sb = (k == 3'd4) ? {w[7:0], w[15:8], w[23:16], w[31:24]}
	                                     : {w[7:0], w[15:8], 16'd0};
	else if (d.ljust)   sb = w;
	else if (k == 3'd1) sb = {w[7:0], 24'd0};
	else if (k == 3'd2) sb = {w[15:0], 16'd0};
	else                sb = w;
	store_window = d.nbytes[3] ? d.wdata : ({sb, 32'd0} >> {d.addr[1:0], 3'b000});
endfunction

// the bytes placed in a two-word window
wire [63:0] wwin0 = store_window(desc[0]);
wire [63:0] wwin1 = store_window(desc[1]);
wire [63:0] wwin  = cp ? wwin1 : wwin0;
wire [7:0]  ones  = ~(8'hFF >> bus_n);
wire [7:0]  bewin = bus_nbytes[3] ? 8'hFF : (ones >> bus_ea[1:0]);

// Admission depends on descriptor capacity, independently of translation
// and cache grants. A bypass hit retains one access per cycle; otherwise
// the accepted operation waits in MEM with its saved descriptor.
assign req_ready  = ~qv;
assign pending_ungranted = (state == S_HOLD0);
assign final_q    = ((state == S_RSP0) & (~two_words | dbus_sure)) | (state == S_RSP1);
assign dbus_req   = ~reset & ((req_valid & first_slot) | (state == S_HOLD0) | (state == S_REQ1));
assign dbus_we    = saved ? c.we : we;
assign dbus_kind  = saved ? c.kind : kind;
assign dbus_addr  = second ? c.next_word : saved ? c.addr[31:2] : addr[31:2];
assign dbus_ea    = bus_ea;
assign dbus_direct = ~second & ~saved;
assign dbus_addr_held = second ? c.next_word : c.addr[31:2];
assign dbus_be    = bus_touch ? 4'b0000 : second ? bewin[3:0] : bewin[7:4];
assign dbus_wdata = (state == S_RSP1) ? wwin[31:0] : wwin[63:32];
// A wide request never crosses a cache line or a translation page. The
// cache declines it for uncached accesses; those retain the word fallback.
// An aligned double asks for two words; so does a load whose bytes cross
// into the next word (the cache's read gives the word and the next anyway),
// so that it takes one access, not two. (A store crossing a word still
// writes each word with its own byte enables.)
wire [2:0] bus_last = {1'b0, bus_ea[1:0]} + bus_n - 3'd1;
wire       bus_we   = saved ? c.we : we;
assign dbus_wide = ~second & ~bus_touch & (bus_ea[4:2] != 3'd7) &
                   (bus_nbytes[3] ? (bus_ea[1:0] == 2'd0) : (~bus_we & bus_last[2]));
assign dbus_wdata_next = wwin[31:0];

// ---- load: bytes to register value ------------------------------------------
wire [63:0] rwin   = (state == S_RSP1) ? {word0_q, dbus_rdata} :
                    {dbus_rdata, dbus_rwide ? dbus_rdata_next : 32'd0};
// Decode byte placement when the descriptor is accepted. The returning
// word then traverses one byte selection, without offset shifting followed
// by size masking, reversal and justification muxes on the load-data path.
function automatic logic [3:0][7:0] load_select(
	input logic [1:0] byte_offset, input logic [2:0] byte_count,
	input logic reverse_bytes, input logic left_justified);
	logic [3:0][7:0] selection;
	int source_byte;
	logic use_byte;
	begin
		selection = '0;
		for (int k = 0; k < 4; k++) begin
			source_byte = int'(byte_offset) + k;
			use_byte = (k < int'(byte_count));
			if (reverse_bytes) begin
				source_byte = int'(byte_offset) + 3 - k;
				use_byte = (byte_count == 3'd4) | ((k >= 2) & (3 - k < int'(byte_count)));
			end
			else if (~left_justified & (byte_count == 3'd1)) begin
				source_byte = int'(byte_offset);
				use_byte = (k == 3);
			end
			else if (~left_justified & (byte_count == 3'd2)) begin
				source_byte = int'(byte_offset) + k - 2;
				use_byte = (k >= 2);
			end
			if (use_byte) selection[k] = 8'd1 << source_byte;
		end
		return selection;
	end
endfunction

function automatic logic [63:0] shaped(input desc_t d, input logic [63:0] win);
	logic sign_bit;
	logic [31:0] lw;
	sign_bit = 1'b0;
	for (int j = 0; j < 8; j++) sign_bit |= d.sign_select[j] & win[63 - 8*j];
	lw = '0;
	for (int k = 0; k < 4; k++) begin
		for (int j = 0; j < 8; j++)
			lw[31 - 8*k -: 8] |= {8{d.load_select[k][j]}} & win[63 - 8*j -: 8];
		lw[31 - 8*k -: 8] |= {8{d.load_sext[k] & sign_bit}};
	end
	shaped = d.nbytes[3] ? win : {32'd0, lw};
endfunction
function automatic logic is_den(input logic [31:0] w);
	is_den = (w[30:23] == 8'd0) & (w[22:0] != 23'd0);
endfunction

// A lookup's answer (way_look: always a hit for a load) is shaped from each
// way's word, beside the tag compare, and the way that hit only chooses
// among them: the byte placement is not behind the way choice (2026-10-13,
// the load's data was the slowest family at 110 MHz). Any other answer
// (an uncached word's) is shaped from the bus's word.
logic [63:0] way_shaped [4];
logic [3:0]  way_den;
always_comb
	for (int w = 0; w < 4; w++) begin
		way_shaped[w] = shaped(c, (state == S_RSP1) ? {word0_q, way_rdata[w]} :
		                          {way_rdata[w], dbus_rwide ? way_rdata_next[w] : 32'd0});
		way_den[w]    = is_den(way_rdata[w]);
	end
logic [63:0] look_rdata;
always_comb begin
	look_rdata = '0;
	for (int w = 0; w < 4; w++) look_rdata |= way_shaped[w] & {64{way_hit[w]}};
end
wire [63:0] bus_rdata_shaped = shaped(c, rwin);
assign rdata      = way_look ? look_rdata : bus_rdata_shaped;
assign rden       = way_look ? |(way_den & way_hit) : is_den(dbus_rdata);
/* synthesis translate_off */
always_ff @(posedge clk)
	if (~reset & resp_valid & ~dbus_fault & way_look & ~c.we & (c.kind == CK_WORD) &
	    ((look_rdata != bus_rdata_shaped) | (rden != is_den(dbus_rdata))))
		$fatal(1, "the load's data shaped by way differs from the bus's");
/* synthesis translate_on */
assign resp_fault = dbus_rvalid & dbus_fault;
assign resp_valid = dbus_rvalid & (dbus_fault | ((state == S_RSP0) & (~two_words | dbus_rwide)) | (state == S_RSP1));

// the request accepted now goes to the descriptor not under way, or to
// cp itself while idle
wire accept = req_valid & ~qv;
wire wi = (state == S_REQ0) ? cp : ~cp;
// the access under way answers for the last time
wire finish = resp_valid;

always_ff @(posedge clk) begin
	if (accept) begin
		desc[wi].we          <= we;
		desc[wi].kind        <= kind;
		desc[wi].addr        <= addr;
		desc[wi].next_word   <= addr[31:2] + 30'd1;
		desc[wi].nbytes      <= nbytes;
		desc[wi].load_select <= load_select(addr[1:0], nbytes[2:0], brev, ljust);
		desc[wi].sign_select <= 8'd1 << addr[1:0];
		desc[wi].load_sext   <= (sext & (nbytes[2:0] == 3'd2) & ~brev & ~ljust) ? 4'b0011 : 4'b0000;
		desc[wi].brev        <= brev;
		desc[wi].ljust       <= ljust;
		desc[wi].wdata       <= wdata;
		desc[wi].conv        <= conv;
		desc[wi].wconv       <= wconv;
		desc[wi].tw          <= (kind == CK_WORD) & (nbytes[3] | 3'({1'b0, addr[1:0]} + nbytes[2:0] - 3'd1) >= 3'd4);
	end
	if (dbus_rvalid & (state == S_RSP0)) word0_q <= dbus_rdata;

	case (state)
		S_REQ0: if (accept) state <= dbus_gnt ? S_RSP0 : S_HOLD0;
		S_HOLD0: if (dbus_gnt) state <= S_RSP0;
		S_RSP0: if (dbus_rvalid & two_words & ~dbus_rwide & ~dbus_fault) state <= S_REQ1;
		S_REQ1: if (dbus_gnt) state <= S_RSP1;
		default: ;
	endcase
	if (finish) begin
		// the next access: the one accepted now (on the bus already if the
		// cache took it), or the one waiting
		if (accept) begin
			cp    <= ~cp;
			state <= (first_slot & dbus_gnt) ? S_RSP0 : S_HOLD0;
		end
		else if (qv) begin
			cp    <= ~cp;
			qv    <= 1'b0;
			state <= S_HOLD0;
		end
		else state <= S_REQ0;
	end
	else if (accept & (state != S_REQ0)) qv <= 1'b1;

	if (reset) begin
		state <= S_REQ0;
		qv    <= 1'b0;
	end
end

/* synthesis translate_off */
always_ff @(posedge clk) begin
	if (~reset) begin
		if ((state == S_RSP0) & dbus_sure & two_words & dbus_rvalid & ~dbus_rwide & ~dbus_fault)
			$fatal(1, "a wide access said to be answered wide was not");
		if (req_valid & qv) $fatal(1, "a third memory access was offered");
		if ((state != S_REQ0) & (c.tw != two_words_of(c)))   // (one under way: written)
			$fatal(1, "a descriptor's two-word flag differs");
	end
end
/* synthesis translate_on */

endmodule

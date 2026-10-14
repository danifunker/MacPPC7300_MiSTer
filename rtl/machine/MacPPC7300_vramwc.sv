//============================================================================
//
//  MacPPC7300 - the machine around the CPU
//  The VRAM's write combiner and read line
//
//  Between the machine's VRAM port and its clock crossing (DSPPC604_memcdc
//  to the DDR3). A store to the frame buffer used to cost the CPU a whole
//  crossing round trip (about fifteen cycles at 100 MHz) before the next
//  could go, a word or a byte at a time; the frame buffer is only ever read
//  by the scan-out and by the CPU through this port, so its stores can be
//  gathered. Here a word or line store is answered the next cycle into one
//  of N 32-byte line entries (a store to a line already held merges into it;
//  the entries are a FIFO, drained whenever the crossing is free, as line
//  writes with a byte mask, so a sequence of stores reaches the DDR3 at up
//  to eight words a transaction and a lone store a few cycles after it was
//  made). A load first waits for every entry to drain, then brings its
//  whole line and keeps it: the following loads of the same line are
//  answered from it until a store touches that line. Order as the CPU sees
//  it is kept: a load sees every earlier store.
//
//============================================================================

module MacPPC7300_vramwc
#(
	parameter int N = 4                       // line entries (a power of two)
)
(
	input  logic         clk,
	input  logic         reset,

	// the machine's side: the CPU port's protocol, VRAM's byte order, a word
	// (bits 31-0, be[3] the lowest address) or a line (word 0 in bits 255-224)
	input  logic         a_req,
	input  logic         a_we,
	input  logic         a_line,
	input  logic [21:2]  a_addr,
	input  logic [3:0]   a_be,
	input  logic [255:0] a_wdata,
	output logic         a_ack,
	output logic [255:0] a_rdata,

	// the crossing's side: line writes with a byte mask (bit j the line's
	// byte in bits 8j+7..8j), line reads
	output logic         b_req,
	output logic         b_we,
	output logic         b_line,
	output logic [21:2]  b_addr,
	output logic [31:0]  b_be,
	output logic [255:0] b_wdata,
	input  logic         b_ack,
	input  logic [255:0] b_rdata,

	// for the trace (kind 15): counts of stores taken, drains done, loads
	// answered, cycles the port waited; then the state
	output logic [159:0] dbg
);

localparam int NB = $clog2(N);

// ---- the request, registered first ----------------------------------------------
// The port's request comes from the machine's registered copy of the CPU's
// port; nothing here compares or writes from it directly. A store is taken
// into this stage and answered the next cycle (it is applied from the
// stage, held there while the entries are full); a load waits in it for
// the entries to drain and is answered from the read line. (The answer
// with the take itself was tried: it made the port's acknowledge
// combinational into the CPU's cache fills, a -6.5 ns family at 100 MHz,
// for a gain within the Color tests' noise.)
logic         s_v, s_we, s_line;
logic [21:2]  s_addr;
logic [3:0]   s_be;
logic [255:0] s_wdata;

// ---- the entries -------------------------------------------------------------
logic [N-1:0]   valid;
logic [21:5]    tag  [N];
logic [31:0]    mask [N];
logic [255:0]   data [N];                   // (Quartus makes registers of so few entries with byte enables)
logic [NB-1:0]  head, tail;                 // drained from the head, allocated at the tail
logic [NB:0]    count;
logic           d_v;                        // the head entry is being drained (no more merging into it)
logic           d_sent;                     // ... and offered to the crossing

// the staged store's place in its line, as a byte mask over the line
wire [2:0]  w_k   = s_addr[4:2];
logic [31:0] w_mask;
always_comb begin
	w_mask = '0;
	if (s_line) w_mask = '1;
	else for (int j = 0; j < 4; j++) w_mask[28 - 4 * w_k + j] = s_be[j];
end
wire [255:0] w_data = s_line ? s_wdata : {8{s_wdata[31:0]}};

// it merges into the entry holding its line, unless that one is draining
logic [N-1:0] match;
logic         hit;
logic [NB-1:0] hit_idx;
always_comb begin
	hit = 1'b0;
	hit_idx = '0;
	for (int i = 0; i < N; i++) begin
		match[i] = valid[i] & (tag[i] == s_addr[21:5]) & ~(d_v & (head == NB'(i)));
		if (match[i]) begin hit = 1'b1; hit_idx = NB'(i); end
	end
end

// ---- the read line -------------------------------------------------------------
logic         rb_v;
logic [21:5]  rb_tag;
logic [255:0] rb;
wire          rb_hit = rb_v & (rb_tag == s_addr[21:5]);
logic         r_wait;                       // a load is out on the crossing
logic         r_done;                       // ... and its line has landed in rb: answer

// ---- the stage and the entries ------------------------------------------------
wire st_apply = s_v & s_we & (hit | (count != (NB+1)'(N)));   // the staged store goes into an entry
wire ld_ready = s_v & ~s_we & (count == '0) & ~d_v & ~r_wait & ~r_done;
wire ld_now   = ld_ready & rb_hit;                               // answered from the read line
wire ld_go    = ld_ready & ~rb_hit;                              // goes out as a line read
wire take     = a_req & ~a_ack & ~s_v;                          // the stage free (not freed now: that would hang its 300 enables on the compares)
wire w_en     = st_apply;
wire [NB-1:0] w_idx = hit ? hit_idx : tail;

always_ff @(posedge clk) begin
	// the data: bytes of the store into its entry
	for (int j = 0; j < 32; j++)
		if (w_en & w_mask[j]) data[w_idx][8 * j +: 8] <= w_data[8 * j +: 8];
end

always_ff @(posedge clk) begin
	a_ack  <= 1'b0;
	r_done <= 1'b0;
	if (take) begin
		s_v     <= 1'b1;
		s_we    <= a_we;
		s_line  <= a_line;
		s_addr  <= a_addr;
		s_be    <= a_be;
		s_wdata <= a_wdata;
		a_ack   <= a_we;                      // a store: taken, answered
	end
	else if (st_apply | ld_now | r_done) s_v <= 1'b0;
	if (st_apply) begin
		if (hit) mask[hit_idx] <= mask[hit_idx] | w_mask;
		else begin
			valid[tail] <= 1'b1;
			tag[tail]   <= s_addr[21:5];
			mask[tail]  <= w_mask;
			tail        <= tail + 1'b1;
		end
		if (rb_hit) rb_v <= 1'b0;             // the read line is stale
	end
	if (ld_now | r_done) a_ack <= 1'b1;
	if (ld_go) begin
		r_wait <= 1'b1;
		b_req  <= 1'b1;
		b_we   <= 1'b0;
		b_line <= 1'b1;
		b_addr <= {s_addr[21:5], 3'b000};
	end
	if (r_wait & b_ack) begin
		r_wait <= 1'b0;
		b_req  <= 1'b0;
		rb     <= b_rdata;
		rb_tag <= b_addr[21:5];
		rb_v   <= 1'b1;
		r_done <= 1'b1;
	end
	// the drain: the head entry, read out and offered until the crossing takes it
	if (~d_v & (count != '0) & ~r_wait & ~ld_go) d_v <= 1'b1;
	if (d_v & ~d_sent) begin                  // offer it (the head entry holds still while it is out)
		d_sent   <= 1'b1;
		b_req    <= 1'b1;
		b_we     <= 1'b1;
		b_line   <= 1'b1;
		b_addr   <= {tag[head], 3'b000};
		b_be     <= mask[head];
	end
	if (d_sent & b_ack) begin
		b_req       <= 1'b0;
		d_v         <= 1'b0;
		d_sent      <= 1'b0;
		valid[head] <= 1'b0;
		head        <= head + 1'b1;
	end
	count <= count + {{NB{1'b0}}, st_apply & ~hit} - {{NB{1'b0}}, d_sent & b_ack};
	if (reset) begin
		valid  <= '0;
		head   <= '0;
		tail   <= '0;
		count  <= '0;
		d_v    <= 1'b0;
		d_sent <= 1'b0;
		r_wait <= 1'b0;
		r_done <= 1'b0;
		rb_v   <= 1'b0;
		b_req  <= 1'b0;
		a_ack  <= 1'b0;
		s_v    <= 1'b0;
	end
end
assign b_wdata = data[head];                  // (the entries are registers: a mux, not a copy)

logic [31:0] n_st, n_dr, n_ld, n_wait;
always_ff @(posedge clk) begin
	if (take & a_we) n_st <= n_st + 32'd1;
	if (d_sent & b_ack) n_dr <= n_dr + 32'd1;
	if (ld_now | r_done) n_ld <= n_ld + 32'd1;
	if (a_req & ~a_ack & ~take) n_wait <= n_wait + 32'd1;
	if (reset) begin n_st <= '0; n_dr <= '0; n_ld <= '0; n_wait <= '0; end
end
assign dbg = {n_st, n_dr, n_ld, n_wait,
              8'(count), 8'(head), 8'(tail),
              d_v, d_sent, r_wait, r_done, s_v, s_we, b_req, a_req};

// what a load gets, from the read line: its word (bits 31-0), or the line
wire [2:0] r_k = s_addr[4:2];
assign a_rdata = s_line ? rb : {224'd0, rb[255 - 32 * r_k -: 32]};

/* synthesis translate_off */
always_ff @(posedge clk)
	if (~reset) begin
		if (d_sent & b_ack & ~valid[head]) $fatal(1, "VRAM combiner drained an empty entry");
		if (st_apply & ~hit & valid[tail]) $fatal(1, "VRAM combiner allocated a held entry");
		if (ld_go & d_v) $fatal(1, "VRAM combiner read while draining");
	end
/* synthesis translate_on */

endmodule

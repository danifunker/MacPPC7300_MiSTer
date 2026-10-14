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
	parameter int N = 8                       // line entries (a power of two)
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
	input  logic [255:0] b_rdata
);

localparam int NB = $clog2(N);

// ---- the entries -------------------------------------------------------------
logic [N-1:0]   valid;
logic [21:5]    tag  [N];
logic [31:0]    mask [N];
(* ramstyle = "MLAB, no_rw_check" *) logic [255:0] data [N];
logic [NB-1:0]  head, tail;                 // drained from the head, allocated at the tail
logic [NB:0]    count;
logic           d_v;                        // the head entry is being drained (no more merging into it)
logic           d_sent;                     // ... and offered to the crossing (its data read)
logic [255:0]   d_data;

// the store's place in its line, as a byte mask over the line
wire [2:0]  w_k   = a_addr[4:2];
logic [31:0] w_mask;
always_comb begin
	w_mask = '0;
	if (a_line) w_mask = '1;
	else for (int j = 0; j < 4; j++) w_mask[28 - 4 * w_k + j] = a_be[j];
end
wire [255:0] w_data = a_line ? a_wdata : {8{a_wdata[31:0]}};

// a store merges into the entry holding its line, unless that one is draining
logic [N-1:0] match;
logic         hit;
logic [NB-1:0] hit_idx;
always_comb begin
	hit = 1'b0;
	hit_idx = '0;
	for (int i = 0; i < N; i++) begin
		match[i] = valid[i] & (tag[i] == a_addr[21:5]) & ~(d_v & (head == NB'(i)));
		if (match[i]) begin hit = 1'b1; hit_idx = NB'(i); end
	end
end

// ---- the read line -------------------------------------------------------------
logic         rb_v;
logic [21:5]  rb_tag;
logic [255:0] rb;
wire          rb_hit = rb_v & (rb_tag == a_addr[21:5]);
logic         r_wait;                       // a load is out on the crossing

// ---- taking the request --------------------------------------------------------
wire take    = a_req & ~a_ack;
wire st_take = take & a_we & (hit | (count != (NB+1)'(N)));
wire ld_now  = take & ~a_we & (count == '0) & ~d_v & rb_hit;          // answered from the read line
wire ld_go   = take & ~a_we & (count == '0) & ~d_v & ~rb_hit & ~r_wait;   // goes out as a line read
wire w_en    = st_take;
wire [NB-1:0] w_idx = hit ? hit_idx : tail;

always_ff @(posedge clk) begin
	// the data: bytes of the store into its entry
	for (int j = 0; j < 32; j++)
		if (w_en & w_mask[j]) data[w_idx][8 * j +: 8] <= w_data[8 * j +: 8];
	d_data <= data[head];
end

always_ff @(posedge clk) begin
	a_ack <= 1'b0;
	if (st_take) begin
		a_ack <= 1'b1;
		if (hit) mask[hit_idx] <= mask[hit_idx] | w_mask;
		else begin
			valid[tail] <= 1'b1;
			tag[tail]   <= a_addr[21:5];
			mask[tail]  <= w_mask;
			tail        <= tail + 1'b1;
		end
		if (rb_hit) rb_v <= 1'b0;             // the read line is stale
	end
	if (ld_now) begin
		a_ack <= 1'b1;
	end
	if (ld_go) begin
		r_wait <= 1'b1;
		b_req  <= 1'b1;
		b_we   <= 1'b0;
		b_line <= 1'b1;
		b_addr <= {a_addr[21:5], 3'b000};
	end
	if (r_wait & b_ack) begin
		r_wait <= 1'b0;
		b_req  <= 1'b0;
		rb     <= b_rdata;
		rb_tag <= b_addr[21:5];
		rb_v   <= 1'b1;
		a_ack  <= 1'b1;
	end
	// the drain: the head entry, read out and offered until the crossing takes it
	if (~d_v & (count != '0) & ~r_wait & ~ld_go) d_v <= 1'b1;
	if (d_v & ~d_sent) begin                  // d_data read at this edge: offer next
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
	count <= count + {{NB{1'b0}}, st_take & ~hit} - {{NB{1'b0}}, d_sent & b_ack};
	if (reset) begin
		valid  <= '0;
		head   <= '0;
		tail   <= '0;
		count  <= '0;
		d_v    <= 1'b0;
		d_sent <= 1'b0;
		r_wait <= 1'b0;
		rb_v   <= 1'b0;
		b_req  <= 1'b0;
		a_ack  <= 1'b0;
	end
end
assign b_wdata = d_data;

// what a load gets: its word of the line (bits 31-0), or the line
wire [255:0] line_now = (r_wait & b_ack) ? b_rdata : rb;
wire [2:0]   r_k      = a_addr[4:2];
assign a_rdata = a_line ? line_now : {224'd0, line_now[255 - 32 * r_k -: 32]};

/* synthesis translate_off */
always_ff @(posedge clk)
	if (~reset) begin
		if (d_sent & b_ack & ~valid[head]) $fatal(1, "VRAM combiner drained an empty entry");
		if (st_take & ~hit & valid[tail]) $fatal(1, "VRAM combiner allocated a held entry");
		if (ld_go & d_v) $fatal(1, "VRAM combiner read while draining");
	end
/* synthesis translate_on */

endmodule

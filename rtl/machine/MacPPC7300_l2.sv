//============================================================================
//
//  MacPPC7300 - the machine around the CPU
//  The L2 cache: a direct-mapped, write-back cache of 32-byte lines on the
//  machine's single memory port, in the CPU's clock, in front of the clock
//  crossing to the SDRAM (the 7300/7600's cache slot holds 256 KB to 1 MB)
//
//  Both ports speak the CPU's memory port protocol (one request, req held
//  until ack, a line or a word with byte enables; the requester ignores the
//  port in the cycle of its own ack). Addresses are SDRAM offsets (128 MB:
//  bits 31-27 are 0), so RAM and the ROM are cached and devices never
//  arrive. Every DMA access comes through this port too (rule 2), so the L2
//  needs no snooping of its own.
//
//  A hit answers two cycles after the request (the set read at the first
//  edge, the tag compared in the next cycle, the answer from a register in
//  the one after). A line write is kept here (dirty); a line read miss
//  writes a dirty victim back first, then fills. A word access (cache
//  inhibited) is served from a line it hits (a write merged with its byte
//  enables) and otherwise goes to memory and allocates nothing.
//
//  The machine's reset (not Cuda's restart) invalidates every line by
//  sweeping the sets: the ROM upload writes the SDRAM behind the cache
//  while the machine is held in reset. With on = 0 (quasi-static, taken
//  under reset) the cache is a wire.
//
//============================================================================

module MacPPC7300_l2
#(
	parameter int unsigned L2_KB = 128          // a power of two
)
(
	input  logic         clk,
	input  logic         reset,
	input  logic         on,

	// the machine's memory port
	input  logic         a_req,
	input  logic         a_we,
	input  logic         a_line,
	input  logic [31:2]  a_addr,
	input  logic [3:0]   a_be,
	input  logic [255:0] a_wdata,
	output logic         a_ack,
	output logic [255:0] a_rdata,

	// to the clock crossing and the SDRAM
	output logic         b_req,
	output logic         b_we,
	output logic         b_line,
	output logic [31:2]  b_addr,
	output logic [3:0]   b_be,
	output logic [255:0] b_wdata,
	input  logic         b_ack,
	input  logic [255:0] b_rdata
);

localparam int SETS = L2_KB * 32;               // lines of 32 bytes
localparam int AW   = $clog2(SETS);
localparam int TAGW = 22 - AW;                  // offset bits 26-5 are index and tag

typedef struct packed {
	logic            valid;
	logic            dirty;
	logic [TAGW-1:0] tag;
} tag_t;

typedef enum logic [2:0] {
	S_SWEEP,     // invalidating every set (after reset)
	S_IDLE,
	S_LOOK,      // the set is out: hit or miss
	S_WB,        // the dirty victim going to memory
	S_FILL,      // the line coming from memory
	S_UNC,       // a word in memory, nothing allocated
	S_ACK        // the answer
} state_t;

state_t       state;
logic         r_we, r_line;
logic [31:2]  r_addr;
logic [3:0]   r_be;
logic [255:0] r_wdata;
logic [255:0] ans;
logic [AW-1:0] sweep_idx;

wire [AW-1:0]   r_idx  = r_addr[AW+4:5];
wire [TAGW-1:0] r_tag  = r_addr[26:AW+5];
wire [2:0]      r_word = r_addr[4:2];

// ---- the RAMs: the tags, and the data as eight word RAMs with a write enable each ----
(* ramstyle = "no_rw_check" *) tag_t tag_mem [SETS];
tag_t          tag_q;
logic          tag_we;
tag_t          tag_wd;
logic [AW-1:0] rd_idx, wr_idx;
logic [255:0]  data_q, data_wd;
logic [7:0]    data_we;

always_ff @(posedge clk) begin
	tag_q <= tag_mem[rd_idx];
	if (tag_we) tag_mem[wr_idx] <= tag_wd;
end

genvar gj;
generate
	for (gj = 0; gj < 8; gj++) begin : word
		(* ramstyle = "no_rw_check" *) logic [31:0] ram [SETS];
		always_ff @(posedge clk) begin
			if (data_we[gj]) ram[wr_idx] <= data_wd[32*gj +: 32];
			data_q[32*gj +: 32] <= ram[rd_idx];
		end
	end
endgenerate

wire hit          = tag_q.valid && tag_q.tag == r_tag;
wire victim_dirty = tag_q.valid & tag_q.dirty;

// a word read from the line, and a word write's bytes merged into it
wire [31:0] rd_word = data_q[255 - 32 * r_word -: 32];
logic [31:0] st_mask;
always_comb for (int j = 0; j < 4; j++) st_mask[8*j +: 8] = {8{r_be[j]}};
wire [31:0] st_word = (rd_word & ~st_mask) | (r_wdata[31:0] & st_mask);

logic         l_req, l_we, l_line;
logic [31:2]  l_addr;
logic [255:0] l_wdata;

always_comb begin
	rd_idx  = (state == S_IDLE) ? a_addr[AW+4:5] : r_idx;
	wr_idx  = r_idx;
	tag_we  = 1'b0;
	tag_wd  = {1'b1, 1'b1, r_tag};
	data_we = '0;
	data_wd = r_wdata;
	l_req   = 1'b0;
	l_we    = 1'b0;
	l_line  = 1'b1;
	l_addr  = r_addr;
	l_wdata = r_wdata;
	case (state)
	S_SWEEP: begin
		wr_idx = sweep_idx;
		tag_wd = '0;
		tag_we = 1'b1;
	end
	S_LOOK: begin
		if (hit) begin
			if (r_we) begin                              // kept here, dirty
				tag_we = 1'b1;
				if (r_line) data_we = '1;
				else begin
					data_we = 8'd1 << (3'd7 - r_word);
					data_wd = {8{st_word}};
				end
			end
		end
		else if (r_line & r_we & ~victim_dirty) begin    // a line into a free or clean slot
			tag_we  = 1'b1;
			data_we = '1;
		end
	end
	S_WB: begin
		l_req   = 1'b1;
		l_we    = 1'b1;
		l_addr  = {5'd0, tag_q.tag, r_idx, 3'b000};
		l_wdata = data_q;
		if (b_ack & r_we) begin                          // the victim gone: the line written takes its place
			tag_we  = 1'b1;
			data_we = '1;
		end
	end
	S_FILL: begin
		l_req = 1'b1;
		if (b_ack) begin
			tag_we  = 1'b1;
			tag_wd  = {1'b1, 1'b0, r_tag};
			data_we = '1;
			data_wd = b_rdata;
		end
	end
	S_UNC: begin
		l_req  = 1'b1;
		l_we   = r_we;
		l_line = 1'b0;
	end
	default: ;
	endcase
end

always_ff @(posedge clk) begin
	case (state)
	S_SWEEP: begin
		sweep_idx <= sweep_idx + 1'b1;
		if (sweep_idx == AW'(SETS - 1)) state <= S_IDLE;
	end
	S_IDLE: if (a_req & on) begin
		r_we    <= a_we;
		r_line  <= a_line;
		r_addr  <= a_addr;
		r_be    <= a_be;
		r_wdata <= a_wdata;
		state   <= S_LOOK;
	end
	S_LOOK: begin
		if (hit) begin
			ans   <= r_line ? data_q : {224'd0, rd_word};
			state <= S_ACK;
		end
		else if (~r_line)      state <= S_UNC;
		else if (victim_dirty) state <= S_WB;
		else if (r_we)         state <= S_ACK;
		else                   state <= S_FILL;
	end
	S_WB:   if (b_ack) state <= r_we ? S_ACK : S_FILL;
	S_FILL: if (b_ack) begin ans <= b_rdata; state <= S_ACK; end
	S_UNC:  if (b_ack) begin ans <= b_rdata; state <= S_ACK; end
	S_ACK:  state <= S_IDLE;
	default: state <= S_IDLE;
	endcase
	if (reset) begin
		state     <= S_SWEEP;
		sweep_idx <= '0;
	end
end

assign b_req   = on ? l_req   : a_req;
assign b_we    = on ? l_we    : a_we;
assign b_line  = on ? l_line  : a_line;
assign b_addr  = on ? l_addr  : a_addr;
assign b_be    = on ? r_be    : a_be;
assign b_wdata = on ? l_wdata : a_wdata;
assign a_ack   = on ? (state == S_ACK) : b_ack;
assign a_rdata = on ? ans : b_rdata;

endmodule

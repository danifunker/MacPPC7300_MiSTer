//============================================================================
//
//  MacPPC7300 - the machine around the CPU
//  AWACS, the sound codec behind Grand Central (Screamer, as dingusppc)
//
//  The registers as dingusppc's devices/sound/awacs.cpp (AwacsScreamer)
//  reads and writes them, and the samples moving as the real chip moves
//  them: 16-bit stereo frames from DMA channel 8 (sound out) to the
//  machine's audio output, and frames of silence to DMA channel 9 (sound
//  in), each at the sample rate the control register sets. dingusppc
//  hands the out channel's bytes to the host's sound card and feeds the in
//  channel 2,048 zero bytes every 10 ms; here both go at the frame rate.
//
//  Registers, 16 bytes apart (Grand Central's 14000 window; offset >> 4),
//  each a word whose bytes may also be written alone (2026-10-09: a byte
//  or halfword write used to be dropped, as dingusppc drops it):
//    0  sound control   stored little-endian (dingusppc byte-swaps the
//                       word); bits 10-8 the sample rate: 44,100, 29,400,
//                       22,050, 17,640, 14,700, 11,025, 8,820, 7,350 Hz
//                       (Screamer's table; awacs.cpp:150)
//    1  codec control   stored as written, the subframe (bits 15-14 of the
//                       word as the CPU writes it) copied to 23-22, as
//                       awacs.cpp:209-226; the codec's registers it selects
//                       (bits 22-20) are kept but change nothing here
//    2  codec status    00314000: available, Crystal, Screamer (awacs.cpp:194)
//    3  clip count      cleared by a read
//    4  byte swap       nonzero written: the samples are little-endian; it
//                       reads 0 when swapping, 1 when not (as dingusppc)
//    5  frame count     stored little-endian; counts the frames played
//                       while the out channel is active (dingusppc's never
//                       counts: decided 2026-10-08, a counter that counts)
//
//  Out: a frame is 4 bytes, left then right, each sample big-endian unless
//  byte swap is set. The channel's bytes fill an 8-byte FIFO (do_ready /
//  do_put, a byte a clock); at each frame a whole frame leaves it for the
//  outputs (left, right), or, if the channel has not delivered one, the
//  outputs keep the last frame (an underrun; a jump to 0 would click).
//  What the FIFO holds when the channel stops is played out, and a part of
//  a frame left after that is dropped, so the next start is frame-aligned.
//
//  In: while the in channel is active, each frame puts 4 zero bytes into
//  a FIFO of 8 that the channel takes (di_valid / di_take); a frame that
//  finds it full is lost (an overrun). Emptied while the channel is not
//  active.
//
//  Time: snd_tick comes at twice 44,100 Hz (88,200 Hz); a frame is 2, 3,
//  4, 5, 6, 8, 10 or 12 ticks.
//
//  Left out (docs/MacPPC7300_stubs.md): the codec's own registers (gain,
//  attenuation and mute change nothing: dingusppc ignores them too), the
//  interrupt (port change, error; Grand Central's source 11), the
//  audio processor on Cuda's I2C (dingusppc's TDA7433 at 45), a real input.
//
//============================================================================

module MacPPC7300_awacs
(
	input  logic        clk,
	input  logic        reset,
	input  logic        snd_tick,        // 88,200 Hz

	// the registers: an access for one clock
	input  logic        sel,
	input  logic        we,
	input  logic [3:0]  rn,              // offset >> 4
	input  logic [31:0] wdata,           // the word as the CPU writes it
	input  logic [3:0]  be,              // its bytes written (be[3]: the register's first)
	output logic [31:0] rq,              // what a read of rn returns now

	// DMA channel 8, sound out: bytes to the FIFO
	input  logic        out_active,
	output logic        do_ready,
	input  logic [7:0]  do_data,
	input  logic        do_put,

	// DMA channel 9, sound in: bytes from the FIFO
	input  logic        in_active,
	output logic        di_valid,
	output logic [7:0]  di_data,
	input  logic        di_take,

	// the samples played, signed, changing at the frame rate
	output logic [15:0] left,
	output logic [15:0] right,
	output logic        frame_tick       // one clock a frame (left and right take the frame's value the clock after)
);

logic [31:0] snd_ctrl, codec_ctrl, clip_count, frame_count;
logic        byte_swap;

// a register kept little-endian reads back as it was written (2026-10-09: it read swapped, so
// Mac OS's read-modify-write of the control register put the chime's 22,050 Hz back after
// setting 44,100: every sound at half speed)
function automatic logic [31:0] bswap(input logic [31:0] v);
	return {v[7:0], v[15:8], v[23:16], v[31:24]};
endfunction
always_comb begin
	case (rn)
		4'd0:    rq = bswap(snd_ctrl);
		4'd1:    rq = codec_ctrl;
		4'd2:    rq = 32'h0031_4000;
		4'd3:    rq = bswap(clip_count);
		4'd4:    rq = {31'h0, ~byte_swap};
		4'd5:    rq = bswap(frame_count);
		default: rq = 32'h0;
	endcase
end

wire [31:0] wle = {wdata[7:0], wdata[15:8], wdata[23:16], wdata[31:24]};
// a byte or halfword write changes only its bytes: in a register kept as written (m_be) or
// little-endian (m_le)
wire [31:0] m_be = {{8{be[3]}}, {8{be[2]}}, {8{be[1]}}, {8{be[0]}}};
wire [31:0] m_le = {m_be[7:0], m_be[15:8], m_be[23:16], m_be[31:24]};
wire [31:0] cw   = wdata | {8'h0, wdata[15:14], 22'h0};

// ---- the frame clock ----------------------------------------------------------------------
// Code 2 plays at 44,100 Hz, not the 22,050 of dingusppc's and Linux's
// tables: the ROM's startup chime (code 2, 51,928 frames) is 1.2 s at the
// right pitch on a real 7300 by the user's ear (2026-10-10, against the data
// rendered at both rates), and Mac OS's Sound Manager mixes everything to
// 44,100 on these machines, so code 0 and code 2 both being 44,100 is what
// it expects (build 40's half-speed sounds were code 2 read as 22,050).
logic [3:0] ftick;                        // snd_ticks into the frame
logic [3:0] fdiv;
always_comb begin
	case (snd_ctrl[10:8])
		3'd0:    fdiv = 4'd2;
		3'd1:    fdiv = 4'd3;
		3'd2:    fdiv = 4'd2;
		3'd3:    fdiv = 4'd5;
		3'd4:    fdiv = 4'd6;
		3'd5:    fdiv = 4'd8;
		3'd6:    fdiv = 4'd10;
		default: fdiv = 4'd12;
	endcase
end
wire frame = snd_tick && ftick + 4'd1 >= fdiv;
assign frame_tick = frame;

// ---- out: an 8-byte FIFO ------------------------------------------------------------------
logic [7:0] ob [8];
logic [2:0] o_rd;                          // the oldest byte
logic [3:0] o_n;                           // bytes held
assign do_ready = o_n < 4'd8 && out_active;
wire   o_pop    = frame && o_n >= 4'd4;    // a whole frame leaves
wire [7:0] b0 = ob[o_rd], b1 = ob[3'(o_rd + 3'd1)], b2 = ob[3'(o_rd + 3'd2)], b3 = ob[3'(o_rd + 3'd3)];

// ---- in: a count of zero bytes ------------------------------------------------------------
logic [3:0] i_n;
assign di_valid = i_n != 4'd0;
assign di_data  = 8'h00;

always_ff @(posedge clk) begin
	if (snd_tick) ftick <= frame ? 4'd0 : ftick + 4'd1;

	// out
	if (do_put) ob[3'(o_rd + o_n[2:0])] <= do_data;
	if (o_pop) begin
		left  <= byte_swap ? {b1, b0} : {b0, b1};
		right <= byte_swap ? {b3, b2} : {b2, b3};
		o_rd  <= o_rd + 3'd4;
	end
	if (!out_active && !o_pop && o_n < 4'd4) o_n <= 4'd0;   // a stopped channel's part frame
	else o_n <= o_n + (do_put ? 4'd1 : 4'd0) - (o_pop ? 4'd4 : 4'd0);
	if (frame && out_active) frame_count <= frame_count + 32'd1;

	// in
	if (!in_active) i_n <= 4'd0;
	else i_n <= i_n - (di_take ? 4'd1 : 4'd0) + ((frame && i_n <= 4'd4) ? 4'd4 : 4'd0);

	// the registers
	if (sel) begin
		case (rn)
			4'd0: if (we) snd_ctrl <= (snd_ctrl & ~m_le) | (wle & m_le);
			4'd1: if (we) codec_ctrl <= (codec_ctrl & ~m_be) | (cw & m_be);
			4'd3: clip_count <= we ? (clip_count & ~m_le) | (wle & m_le) : 32'h0;
			4'd4: if (we) byte_swap <= (wdata & m_be) != 32'h0;
			4'd5: if (we) frame_count <= (frame_count & ~m_le) | (wle & m_le);
			default: ;
		endcase
	end

	if (reset) begin
		snd_ctrl    <= 32'h0;
		codec_ctrl  <= 32'h0;
		clip_count  <= 32'h0;
		frame_count <= 32'h0;
		byte_swap   <= 1'b0;
		ftick       <= 4'd0;
		o_rd        <= 3'd0;
		o_n         <= 4'd0;
		i_n         <= 4'd0;
		left        <= 16'h0;
		right       <= 16'h0;
	end
end

endmodule

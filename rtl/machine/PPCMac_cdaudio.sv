//============================================================================
//
//  PPCMac - the machine around the CPU
//  The CD-ROM drive's audio, as the Quadra 800 core's rtl/cd_audio.sv: the
//  Main's Mac CD layer (support/mac/mac_cdrom*.cpp) keeps the AppleCD
//  playhead, executes the transport commands PPCMac_scsidisk forwards and
//  serves "the next frame at the playhead, volume applied" from its frame
//  window; here, on the CD slot's channel (PPCMac_scsidisk's issuer):
//
//    the TOC blob's header after a mount (7FFF0000: "MCDA", the version,
//    bit 0 of byte 12 = the disc has a data track); the AUDIO STATUS
//    response (7ECC0000, byte 0 = 0 playing, 1 paused, 3 at the end, 5 idle)
//    after each forwarded command; while playing, frames (7C000000, five
//    blocks: 2352 bytes of PCM, then the state, "have" and the flush
//    generation at 2352-2357) into the free half of a two-frame buffer;
//    played at 44,100 Hz, interpolated between samples.
//
//============================================================================

module PPCMac_cdaudio
#(
	parameter int unsigned CLK_HZ = 65_000_000
)
(
	input  logic        clk,
	input  logic        reset,
	input  logic        bus_rst,        // a SCSI bus reset stops playback
	input  logic        mounted,        // a disc in the drive
	input  logic        mount_ev,       // a mount pulse: read the header again
	input  logic        fwd_ev,         // a forwarded command has landed: ask the state
	input  logic        stop_ev,        // a data read or an eject

	// the channel: held until done
	output logic        a_req,
	output logic [31:0] a_lba,
	output logic        a_frame,        // five blocks into the frame buffer's half a_half
	output logic        a_half,
	input  logic        a_done,
	// bytes of the last transfer (steady once done): 0-3, 4, 12, 2352-2357
	input  logic [31:0] cap_hdr,
	input  logic [7:0]  cap_ver,
	input  logic [7:0]  cap_flags,
	input  logic [7:0]  pad_ast,
	input  logic        pad_have,
	input  logic [31:0] pad_gen,
	// the frame buffer (2 x 2352 bytes)
	output logic [12:0] fr_ra,
	input  logic [7:0]  fr_q,

	output logic        toc_ready,
	output logic        disc_audio,     // no data track: data reads must fail
	output logic signed [15:0] snd_l,
	output logic signed [15:0] snd_r
);

localparam logic [31:0] TOC_BLK = 32'h7FFF_0000, FRAME_BLK = 32'h7C00_0000, STAT_BLK = 32'h7ECC_0000;
localparam int unsigned HOLD_CLKS = CLK_HZ / 75;
localparam int unsigned FRAC_INC  = int'(64'd2_890_137_600 / 64'(CLK_HZ)) + 1;   // 65536 x 44100 / CLK_HZ

// the AUDIO STATUS response's byte 0 is the transfer's byte 0
wire [7:0] st_byte = cap_hdr[31:24];

typedef enum logic [1:0] { A_IDLE, A_HDR, A_ST, A_FR } ast_t;
ast_t        as;
logic [7:0]  ast;                       // the Main's state: 0 playing
logic        st_pend;
logic [1:0]  fr_valid;
logic [31:0] gen_r;
logic [23:0] hold;
logic        flush, flush_half;
logic        frame_done, done_half;
wire         playing = ast == 8'd0;
wire         run     = playing || (ast == 8'd3 && |fr_valid);

always_ff @(posedge clk) begin
	flush <= 1'b0;
	if (hold != 0) hold <= hold - 1'd1;
	if (fwd_ev) st_pend <= 1'b1;
	if (frame_done) fr_valid[done_half] <= 1'b0;

	case (as)
		A_IDLE: begin
			if (mounted && (mount_ev || !toc_ready)) begin
				a_req <= 1'b1; a_lba <= TOC_BLK; a_frame <= 1'b0; as <= A_HDR;
			end
			else if (st_pend) begin
				st_pend <= 1'b0;
				if (mounted) begin a_req <= 1'b1; a_lba <= STAT_BLK; a_frame <= 1'b0; as <= A_ST; end
			end
			else if (playing && mounted && toc_ready && !(&fr_valid) && hold == 0) begin
				a_req <= 1'b1; a_lba <= FRAME_BLK; a_frame <= 1'b1; a_half <= fr_valid[0];
				as <= A_FR;
			end
		end
		A_HDR: if (a_done) begin
			a_req      <= 1'b0;
			disc_audio <= cap_hdr == "MCDA" && cap_ver >= 8'd2 && !cap_flags[0];
			toc_ready  <= 1'b1;
			as <= A_IDLE;
		end
		A_ST: if (a_done) begin
			a_req <= 1'b0;
			ast   <= st_byte;
			hold  <= '0;
			if (st_byte != 8'd0) begin fr_valid <= 2'b00; flush <= 1'b1; flush_half <= 1'b0; end
			as <= A_IDLE;
		end
		A_FR: if (a_done) begin
			a_req <= 1'b0;
			ast   <= pad_ast;
			if (pad_have) begin
				if (pad_gen != gen_r) begin       // the playhead moved: only this frame is current
					gen_r      <= pad_gen;
					fr_valid   <= a_half ? 2'b10 : 2'b01;
					flush      <= 1'b1;
					flush_half <= a_half;
				end
				else fr_valid[a_half] <= 1'b1;
			end
			else hold <= 24'(HOLD_CLKS);
			as <= A_IDLE;
		end
		default: as <= A_IDLE;
	endcase
	if (mount_ev) toc_ready <= 1'b0;

	if (stop_ev || bus_rst || !mounted) begin
		if (ast != 8'd5 || |fr_valid) begin
			ast <= 8'd5; fr_valid <= 2'b00; flush <= 1'b1; flush_half <= 1'b0;
		end
	end

	if (reset) begin
		as <= A_IDLE; a_req <= 1'b0; a_frame <= 1'b0; a_half <= 1'b0; a_lba <= '0;
		ast <= 8'd5; st_pend <= 1'b0; fr_valid <= 2'b00; gen_r <= '0; hold <= '0;
		flush <= 1'b0; flush_half <= 1'b0; toc_ready <= 1'b0; disc_audio <= 1'b0;
	end
end

// ---- 44,100 stereo samples a second: a frame is 588, four bytes each (little-endian) --------
logic [31:0] acc;
logic [9:0]  sidx;                      // the sample in the frame
logic [2:0]  sph;
logic        play_half;
logic signed [15:0] l_t, r_t, l_p, r_p; // the samples, and the ones before
logic [7:0]  b_lo;
logic [16:0] frac16;                    // the segment's phase, Q16, saturating
wire  [12:0] fbase = play_half ? 13'd2352 : 13'd0;

always_ff @(posedge clk) begin
	frame_done <= 1'b0;
	if (!frac16[16]) frac16 <= frac16 + 17'(FRAC_INC);
	if (flush) begin
		sidx <= '0; acc <= '0; sph <= '0; play_half <= flush_half;
	end
	else if (run && fr_valid[play_half]) begin
		if (sph == 3'd0) begin
			if (acc >= CLK_HZ - 32'd44_100) begin
				acc   <= acc + 32'd44_100 - CLK_HZ;
				fr_ra <= fbase + {1'b0, sidx, 2'b00};
				sph   <= 3'd1;
			end
			else acc <= acc + 32'd44_100;
		end
		else begin
			sph <= sph + 3'd1;
			case (sph)
				3'd1: fr_ra <= fbase + {1'b0, sidx, 2'b01};
				3'd2: begin fr_ra <= fbase + {1'b0, sidx, 2'b10}; b_lo <= fr_q; end
				3'd3: begin fr_ra <= fbase + {1'b0, sidx, 2'b11}; l_p <= l_t; l_t <= {fr_q, b_lo}; end
				3'd4: b_lo <= fr_q;
				default: begin
					r_p <= r_t; r_t <= {fr_q, b_lo};
					frac16 <= '0;
					sph <= 3'd0;
					if (sidx == 10'd587) begin
						sidx       <= '0;
						play_half  <= ~play_half;
						frame_done <= 1'b1;
						done_half  <= play_half;
					end
					else sidx <= sidx + 10'd1;
				end
			endcase
		end
	end
	else if (!run) begin
		l_t <= '0; r_t <= '0; l_p <= '0; r_p <= '0; acc <= '0;
	end
	if (reset) begin
		acc <= '0; sidx <= '0; sph <= '0; play_half <= 1'b0; frame_done <= 1'b0; done_half <= 1'b0;
		l_t <= '0; r_t <= '0; l_p <= '0; r_p <= '0; frac16 <= '0; fr_ra <= '0;
	end
end

// linear interpolation from the previous sample to the current one, the
// output held 16 clocks at a time (the framework's audio input keeps a value
// it has seen twice)
wire        [15:0] seg_f  = frac16[16] ? 16'hFFFF : frac16[15:0];
wire signed [16:0] seg_dl = {l_t[15], l_t} - {l_p[15], l_p};
wire signed [16:0] seg_dr = {r_t[15], r_t} - {r_p[15], r_p};
wire signed [33:0] seg_ml = seg_dl * $signed({1'b0, seg_f});
wire signed [33:0] seg_mr = seg_dr * $signed({1'b0, seg_f});
wire signed [16:0] sum_l  = {l_p[15], l_p} + $signed(seg_ml[32:16]);
wire signed [16:0] sum_r  = {r_p[15], r_p} + $signed(seg_mr[32:16]);
logic [3:0] odiv;
always_ff @(posedge clk) begin
	odiv <= odiv + 4'd1;
	if (odiv == 4'd0) begin
		snd_l <= sum_l[15:0];
		snd_r <= sum_r[15:0];
	end
	if (reset || !run) begin
		snd_l <= '0; snd_r <= '0; odiv <= '0;
	end
end

endmodule

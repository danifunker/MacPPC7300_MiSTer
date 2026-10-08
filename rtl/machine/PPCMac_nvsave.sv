//============================================================================
//
//  PPCMac - the machine around the CPU
//  The NVRAM kept on the SD card (milestone P): Grand Central's 8 KB NVRAM
//  (Open Firmware's settings, Mac OS's XPRAM at 1300-13FF) in an image on
//  hps_io's block slot 2, the Mac SCSI family's NVRAM slot
//
//  The Quadra 800 core's scheme for its PRAM (MacQuadra800.sv, "PRAM
//  persistence"), for an 8 KB image of 16 blocks:
//    load   when an image of 8 KB or more is mounted (img_mounted, the
//           size): the 16 blocks read, each 512 bytes written into the
//           NVRAM; the machine is held in reset meanwhile (hold), so an
//           image mounted while it runs restarts it on the loaded NVRAM
//    save   when the CPU has written the NVRAM since the last load or save
//           and then left it alone for 2 s, or when the OSD opens: the
//           16 blocks read out of the NVRAM and written to the image (not
//           if it is read-only)
//  With no image mounted nothing happens: the NVRAM starts as it does
//  without this module (zeros, or boot1.rom's image).
//
//  hps_io's side (sd_*) is the block interface the disks use: rd or wr held
//  until sd_ack rises, the block moved while sd_ack is high (sd_buff_wr with
//  the bytes for a read; sd_buff_din one clock after sd_buff_addr for a
//  write), done when sd_ack falls. The NVRAM's side is a byte channel to
//  the CPU's clock (PPCMac.sv): b_req held with b_we, b_addr, b_wdata until
//  b_done, the byte read in b_rdata then. dirty_tog toggles (in any clock)
//  at each write the CPU makes to the NVRAM.
//
//============================================================================

module PPCMac_nvsave
#(
	parameter int unsigned CLK_HZ = 100_000_000
)
(
	input  logic        clk,
	input  logic        reset,

	// hps_io's block slot for the image
	input  logic        img_mounted,
	input  logic [63:0] img_size,
	input  logic        img_readonly,
	output logic [31:0] sd_lba,
	output logic        sd_rd,
	output logic        sd_wr,
	input  logic        sd_ack,
	input  logic [13:0] sd_buff_addr,
	input  logic [7:0]  sd_buff_dout,
	input  logic        sd_buff_wr,
	output logic [7:0]  sd_buff_din,

	input  logic        osd_open,
	input  logic        dirty_tog,
	output logic        hold,              // keep the machine in reset: a load under way

	// the byte channel to the NVRAM
	output logic        b_req,
	output logic        b_we,
	output logic [12:0] b_addr,
	output logic [7:0]  b_wdata,
	input  logic        b_done,
	input  logic [7:0]  b_rdata
);

localparam int unsigned SETTLE = CLK_HZ * 2;          // 2 s

typedef enum logic [2:0] {S_IDLE, S_LD_RD, S_LD_WAIT, S_LD_PUT, S_SV_GET, S_SV_WR, S_SV_WAIT} st_t;
st_t         s;
logic        ok, ro;                  // an image of 8 KB or more; read-only
logic [3:0]  blk;                     // the block in hand
logic [9:0]  idx;                     // the byte in hand (10 bits: 512 ends the block)
logic        acked;                   // hps_io has taken the block request
logic        dirty;
logic [31:0] settle;
logic [2:0]  dt_s;
logic        osd_q;

// the block buffer: one write port, one read port
logic [7:0]  buf_r [0:511];
logic [7:0]  buf_q;
logic [8:0]  buf_qa;                  // the address buf_q was read from
wire         buf_we = (s == S_LD_WAIT && sd_ack && sd_buff_wr) || (s == S_SV_GET && b_done);
wire  [8:0]  buf_wa = (s == S_SV_GET) ? idx[8:0] : sd_buff_addr[8:0];
wire  [7:0]  buf_wd = (s == S_SV_GET) ? b_rdata : sd_buff_dout;
wire  [8:0]  buf_ra = (s == S_LD_PUT) ? idx[8:0] : sd_buff_addr[8:0];
always_ff @(posedge clk) begin
	if (buf_we) buf_r[buf_wa] <= buf_wd;
	buf_q  <= buf_r[buf_ra];
	buf_qa <= buf_ra;
end
assign sd_buff_din = buf_q;
assign sd_lba      = {28'h0, blk};
assign hold        = s == S_LD_RD || s == S_LD_WAIT || s == S_LD_PUT;

wire dirty_ev = dt_s[2] != dt_s[1];

always_ff @(posedge clk) begin
	dt_s  <= {dt_s[1:0], dirty_tog};
	osd_q <= osd_open;

	if (dirty_ev) begin
		dirty  <= 1'b1;
		settle <= SETTLE;
	end
	else if (settle != 32'd0) settle <= settle - 32'd1;

	case (s)
		S_IDLE: begin
			if (img_mounted) begin
				ok <= img_size >= 64'd8192;
				ro <= img_readonly;
				if (img_size >= 64'd8192) begin
					blk <= 4'd0;
					s   <= S_LD_RD;
				end
			end
			else if (ok && !ro && dirty && !dirty_ev && (settle == 32'd0 || (osd_open && !osd_q))) begin
				dirty <= 1'b0;                   // writes from now on make it dirty again
				blk   <= 4'd0;
				idx   <= 10'd0;
				s     <= S_SV_GET;
			end
		end

		// ---- load: a block from the image, then its bytes into the NVRAM ----
		S_LD_RD: begin
			sd_rd <= 1'b1;
			acked <= 1'b0;
			s     <= S_LD_WAIT;
		end
		S_LD_WAIT: begin
			if (sd_ack) begin
				sd_rd <= 1'b0;
				acked <= 1'b1;
			end
			else if (acked) begin                // the block is in the buffer
				idx <= 10'd0;
				s   <= S_LD_PUT;
			end
		end
		S_LD_PUT: begin                          // buf_q is the byte at idx a clock after
			if (!b_req) begin
				if (idx == 10'd512) begin
					blk <= blk + 4'd1;
					if (blk == 4'd15) begin
						dirty <= 1'b0;
						s     <= S_IDLE;
					end
					else s <= S_LD_RD;
				end
				else if (!b_done && buf_qa == idx[8:0]) begin
					b_req   <= 1'b1;
					b_we    <= 1'b1;
					b_addr  <= {blk, idx[8:0]};
					b_wdata <= buf_q;
				end
			end
			else if (b_done) begin
				b_req <= 1'b0;
				idx   <= idx + 10'd1;
			end
		end

		// ---- save: a block's bytes out of the NVRAM, then the block to the image ----
		S_SV_GET: begin
			if (!b_req) begin
				if (idx == 10'd512) begin
					sd_wr <= 1'b1;
					acked <= 1'b0;
					s     <= S_SV_WR;
				end
				else if (!b_done) begin
					b_req  <= 1'b1;
					b_we   <= 1'b0;
					b_addr <= {blk, idx[8:0]};
				end
			end
			else if (b_done) begin               // buf_we takes the byte in this clock
				b_req <= 1'b0;
				idx   <= idx + 10'd1;
			end
		end
		S_SV_WR: begin
			if (sd_ack) begin
				sd_wr <= 1'b0;
				acked <= 1'b1;
			end
			else if (acked) s <= S_SV_WAIT;
		end
		S_SV_WAIT: begin
			blk <= blk + 4'd1;
			idx <= 10'd0;
			s   <= (blk == 4'd15) ? S_IDLE : S_SV_GET;
		end
		default: s <= S_IDLE;
	endcase

	if (reset) begin
		s      <= S_IDLE;
		ok     <= 1'b0;
		ro     <= 1'b1;
		blk    <= 4'd0;
		idx    <= 10'd0;
		acked  <= 1'b0;
		dirty  <= 1'b0;
		settle <= 32'd0;
		sd_rd  <= 1'b0;
		sd_wr  <= 1'b0;
		b_req  <= 1'b0;
		b_we   <= 1'b0;
	end
end

endmodule

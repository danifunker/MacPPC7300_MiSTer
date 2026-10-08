//============================================================================
//
//  PPCMac - the machine around the CPU
//  The internal SCSI bus's targets: two hard disks (IDs 0 and 1) and a
//  CD-ROM drive (ID 3), on the MiSTer's block devices in the Mac SCSI
//  family's layout: slots 0 and 1 the disks, 3 the BlueSCSI Toolbox, 4 the
//  CD-ROM, 5 the CD changer (2 is the NVRAM's, PPCMac_nvsave)
//
//  A SCSI-2 target at the bus's signal level, behind MESH (PPCMac_mesh):
//  selection, then MESSAGE OUT while ATN is up (SDTR is answered with an
//  SDTR of offset 0, asynchronous; WDTR with 8 bits; another extended
//  message with MESSAGE REJECT), COMMAND (6, 10, 12 or 16 bytes by the
//  opcode's group; C0-DF, Apple's and the Toolbox's, 10), the data, STATUS,
//  MESSAGE IN (COMMAND COMPLETE), bus free. ATN up when a message in's byte
//  ends is MESSAGE OUT (after which ABORT, BUS DEVICE RESET, ABORT TAG and
//  CLEAR QUEUE free the bus, anything else carries on). Every byte is a REQ/ACK
//  handshake: the target sets the phase (MSG C/D I/O) a clock before REQ; in
//  the in-phases it puts the byte on the data lines, in the out-phases it
//  takes it when ACK comes; then it lets REQ go and waits for ACK to go. RST
//  lets go of everything. A new phase's first REQ comes PHASE_US
//  microseconds after the phase lines change, as a disk takes time to change
//  phase: the 7300's SCSI Manager (its native SIM, FFEB8D98) waits after the
//  status byte until REQ is down before it asks MESH for the message, and a
//  target that asks at once is never seen to stop asking.
//
//  The disks' commands, as dingusppc's scsihd.cpp, scsiblockcmds.cpp and
//  scsicommoncmds.cpp answer them (the Mac Quadra 800 core's target for the
//  ones Apple's tools use): TEST UNIT READY, REZERO UNIT, REQUEST SENSE,
//  FORMAT UNIT, READ(6), WRITE(6), SEEK(6), INQUIRY, MODE SELECT(6),
//  RESERVE, RELEASE, MODE SENSE(6) (pages 1, 3, 4 and Apple's 30, or all),
//  START STOP UNIT, SEND DIAGNOSTIC, PREVENT ALLOW MEDIUM REMOVAL, READ
//  CAPACITY(10), READ(10), WRITE(10), SEEK(10), VERIFY(10), SYNCHRONIZE
//  CACHE(10), WRITE BUFFER and READ BUFFER (the data taken or 4 bytes of
//  header). Anything else is CHECK CONDITION, ILLEGAL REQUEST (5/20); a
//  block beyond the image, ILLEGAL REQUEST (5/21); a write to a read-only
//  image, DATA PROTECT (7/27). The sense is kept per target until REQUEST
//  SENSE or the next command takes it. The answer to INQUIRY: a fixed,
//  non-removable direct-access device, SCSI-2, "QUANTUM " "MiSTer PPCMac HD"
//  "1.0 " (dingusppc's vendor; no synchronous transfers).
//
//  The CD-ROM drive (2026-10-08), as the Quadra 800 core's target speaks to
//  the Main's Mac CD layer (support/mac/mac_cdrom*.cpp, the "optimized"
//  contract): INQUIRY, MODE SENSE, both READ TOCs, READ SUB-CHANNEL, READ Q
//  SUBCODE and AUDIO STATUS are the Main's answers, read from its response
//  window (block 7E000000 + opcode << 16 + two CDB bytes); the transport
//  (Apple's C8-CB and CD, PLAY, PAUSE, STOP, SEEK, REZERO), an eject and an
//  accepted MODE SELECT are written to its command window (7D000000 +
//  opcode << 16: the parameter list from byte 0, the CDB at 496), the
//  status held until the write is done; housekeeping writes FF after a
//  reset and FE after a bus reset. Data: 2048-byte blocks (a MODE SELECT
//  asking for any other length is refused, 5/26, as the Quadra's), four of
//  the slot's; an audio-only disc refuses data reads (5/64); no disc is NOT
//  READY (2/B0, AppleCD's); an eject lasts until a bus reset or a mount.
//  The drive answers selection only once the Main has answered the INQUIRY
//  window with the drive's identity (read after a reset and a mount): with
//  a Main that does not speak the contract there is no drive at all, and
//  nothing is ever written to the CD's slot. The audio: PPCMac_cdaudio.
//
//  The BlueSCSI Toolbox (2026-10-08), the Mac LC core's transport
//  (docs/BLUESCSI_CORE_HPS_CONTRACT.md there): on ID 0, file sharing (D0
//  LIST, D1 GET, D2 COUNT, D3-D5 SEND) on slot 3; on ID 3, the CD changer
//  (D7 LIST, D8 SET NEXT, DA COUNT) on slot 5. A command is a write of
//  block 0 (the CDB, byte 10 the direction, a SEND's payload from byte 16,
//  the rest of it first as blocks 1, 2, ...), a read of block 0 (the
//  status, B5, the length), then the data from block 1 on. Locally: D9
//  DEVICE INFO, D6 TOGGLE DEBUG and MODE SENSE page 31 ("BlueSCSI is the
//  BEST"). Each answers only once the Main has announced the slot.
//
//  The blocks (512 bytes): one channel to the memory clock's side (a
//  toggle, the slot, the LBA, which half of the two-block buffer) shared by
//  the target and the CD's audio, the target first; that side asks hps_io
//  (sd_rd or sd_wr until sd_ack, done when sd_ack falls). Two buffers, each
//  of two blocks, each written in one clock and read in the other: the read
//  buffer (hps_io writes, the target reads) and the write buffer (the other
//  way); and the audio's two frames. A read asks for its next block as soon
//  as it starts sending one; a write sends each block to the card as soon
//  as it has it, while the next comes over the bus.
//
//  The images: hps_io's img_mounted pulses (the slot's bit, the size and
//  read-only flag valid with it) are kept in the memory clock, in registers
//  the machine's reset does not touch (the Mac Quadra 800 core's lesson:
//  the mount at the core's start comes during the reset, and a reset must
//  not forget it), and handed to the CPU's clock by a toggle.
//
//============================================================================

module PPCMac_scsidisk
#(
	parameter int unsigned CLK_HZ   = 65_000_000,   // the CPU's clock
	parameter int unsigned PHASE_US = 10            // a phase change's delay before REQ
)
(
	input  logic        clk,            // the CPU's clock
	input  logic        reset,

	// the SCSI bus: what the targets drive, and the lines (1 = asserted)
	output logic        t_bsy, t_req, t_msg, t_cd, t_io,
	output logic [7:0]  t_db,           // 0 where no target drives
	input  logic        b_rst, b_bsy, b_sel, b_atn, b_ack,
	input  logic [7:0]  b_db,

	// hps_io's block devices, in the memory clock (slot 2 is not driven here)
	input  logic        clk_h,
	input  logic [5:0]  img_mounted,
	input  logic [63:0] img_size,
	input  logic        img_readonly,
	output logic [31:0] sd_lba,
	output logic [5:0]  sd_rd,
	output logic [5:0]  sd_wr,
	output logic [5:0]  sd_blk_cnt,
	input  logic [5:0]  sd_ack,
	input  logic [13:0] sd_buff_addr,
	input  logic [7:0]  sd_buff_dout,
	output logic [7:0]  sd_buff_din,
	input  logic        sd_buff_wr,

	output logic        busy,           // a block is moving to or from the card (the disk light)
	output logic signed [15:0] cd_left, // the CD's audio, in this clock
	output logic signed [15:0] cd_right,

	// a record for PPCMac_trace: each command's end, a bus reset, a CD mount
	output logic        tr_ev,
	output logic [255:0] tr_rec
);

localparam logic [31:0] WIN_RESP = 32'h7E00_0000, WIN_CMD = 32'h7D00_0000;

// =========================================================================================
//  The memory clock's side
// =========================================================================================

// ---- the images: kept across the machine's resets -----------------------------------------
logic [2:0]  h_valid = 3'b000, h_ro = 3'b000;      // disk 0, disk 1, the CD
logic [31:0] h_blocks [3];
logic        h_tb = 1'b0, h_cdc = 1'b0;            // the Toolbox slots announced
logic        h_mtog = 1'b0, h_cdtog = 1'b0;
always_ff @(posedge clk_h) begin
	for (int i = 0; i < 2; i++)
		if (img_mounted[i]) begin
			h_valid[i]  <= img_size != 64'd0;
			h_ro[i]     <= img_readonly;
			h_blocks[i] <= (img_size[63:41] != 23'd0) ? 32'hFFFF_FFFF : img_size[40:9];
		end
	if (img_mounted[4]) begin
		h_valid[2]  <= img_size != 64'd0;
		h_ro[2]     <= 1'b1;
		h_blocks[2] <= (img_size[63:41] != 23'd0) ? 32'hFFFF_FFFF : img_size[40:9];
		h_cdtog     <= ~h_cdtog;
	end
	if (img_mounted[3]) h_tb  <= 1'b1;
	if (img_mounted[5]) h_cdc <= 1'b1;
	if ((img_mounted & 6'b111011) != 6'd0) h_mtog <= ~h_mtog;
end

// ---- the block transfers --------------------------------------------------------------------
logic        c_btog;                    // the CPU's side: a request (a toggle)
logic        c_bwe, c_bhalf, c_baud, c_bfr;
logic [2:0]  c_bslot;
logic [31:0] c_blba;
logic [2:0]  h_btog_s;
logic        h_bseen = 1'b0, h_bdone = 1'b0, h_acked;
logic        h_half, h_aud, h_fr;
logic [2:0]  h_slot;
always_ff @(posedge clk_h) begin
	h_btog_s <= {h_btog_s[1:0], c_btog};
	if (h_btog_s[2] != h_bseen && sd_rd == 6'd0 && sd_wr == 6'd0 && !h_acked) begin
		// the request's fields have stood still since the toggle
		h_bseen    <= h_btog_s[2];
		h_slot     <= c_bslot;
		h_half     <= c_bhalf;
		h_aud      <= c_baud;
		h_fr       <= c_bfr;
		sd_lba     <= c_blba;
		sd_blk_cnt <= c_bfr ? 6'd4 : 6'd0;
		sd_rd      <= c_bwe ? 6'd0 : 6'd1 << c_bslot;
		sd_wr      <= c_bwe ? 6'd1 << c_bslot : 6'd0;
	end
	if (((sd_rd | sd_wr) & sd_ack) != 6'd0) begin   // taken: the request down
		sd_rd   <= 6'd0;
		sd_wr   <= 6'd0;
		h_acked <= 1'b1;
	end
	if (h_acked && !sd_ack[h_slot]) begin           // done
		h_acked <= 1'b0;
		h_bdone <= h_bseen;
	end
end

// ---- the buffers --------------------------------------------------------------------------------
logic [7:0]  rbuf [1024];               // the card's blocks for the target
logic [7:0]  wbuf [1024];               // the target's blocks for the card
logic [7:0]  frb  [4704];               // the CD's two audio frames
wire         h_mine = sd_ack[h_slot];
wire  [12:0] h_fa   = (h_half ? 13'd2352 : 13'd0) + {1'b0, sd_buff_addr[11:0]};
logic [31:0] h_cap_hdr;                 // the audio's transfers: bytes 0-3, 4, 12, 2352-2357
logic [7:0]  h_cap_ver, h_cap_flags, h_pad_ast;
logic        h_pad_have;
logic [31:0] h_pad_gen;
always_ff @(posedge clk_h) begin
	if (sd_buff_wr & h_mine & ~h_aud) rbuf[{h_half, sd_buff_addr[8:0]}] <= sd_buff_dout;
	if (sd_buff_wr & h_mine & h_aud & h_fr & (sd_buff_addr < 14'd2352)) frb[h_fa] <= sd_buff_dout;
	sd_buff_din <= wbuf[{h_half, sd_buff_addr[8:0]}];
	if (sd_buff_wr & h_mine & h_aud) begin
		case (sd_buff_addr)
			14'd0:    h_cap_hdr[31:24] <= sd_buff_dout;
			14'd1:    h_cap_hdr[23:16] <= sd_buff_dout;
			14'd2:    h_cap_hdr[15:8]  <= sd_buff_dout;
			14'd3:    h_cap_hdr[7:0]   <= sd_buff_dout;
			14'd4:    h_cap_ver        <= sd_buff_dout;
			14'd12:   h_cap_flags      <= sd_buff_dout;
			14'd2352: h_pad_ast        <= sd_buff_dout;
			14'd2353: h_pad_have       <= sd_buff_dout[0];
			14'd2354: h_pad_gen[7:0]   <= sd_buff_dout;
			14'd2355: h_pad_gen[15:8]  <= sd_buff_dout;
			14'd2356: h_pad_gen[23:16] <= sd_buff_dout;
			14'd2357: h_pad_gen[31:24] <= sd_buff_dout;
			default: ;
		endcase
	end
end

// =========================================================================================
//  The CPU's clock's side
// =========================================================================================

// ---- the images, handed over ------------------------------------------------------------------
logic [2:0]  c_mtog_s, c_cdtog_s;
logic        c_mseen = 1'b0, c_cdseen = 1'b0;
logic [2:0]  m_valid = 3'b000, m_ro = 3'b000;
logic [31:0] m_blocks [3];
logic        m_tb = 1'b0, m_cdc = 1'b0;
logic        cd_mev;                    // a mount pulse on the CD's slot, one clock
always_ff @(posedge clk) begin
	c_mtog_s  <= {c_mtog_s[1:0], h_mtog};
	c_cdtog_s <= {c_cdtog_s[1:0], h_cdtog};
	cd_mev    <= 1'b0;
	if (c_mtog_s[2] != c_mseen || c_cdtog_s[2] != c_cdseen) begin
		c_mseen  <= c_mtog_s[2];
		c_cdseen <= c_cdtog_s[2];
		cd_mev   <= c_cdtog_s[2] != c_cdseen;
		m_valid  <= h_valid;
		m_ro     <= h_ro;
		m_tb     <= h_tb;
		m_cdc    <= h_cdc;
		for (int i = 0; i < 3; i++) m_blocks[i] <= h_blocks[i];
	end
end

// ---- the channel: the target's requests first, then the audio's ---------------------------------
logic [2:0] c_bdone_s;
always_ff @(posedge clk) c_bdone_s <= {c_bdone_s[1:0], h_bdone};
wire blk_idle = c_bdone_s[2] == c_btog;  // no block in flight
assign busy = ~blk_idle;

logic        t_rq;                      // the target's block, until done
logic        t_we, t_half;
logic [2:0]  t_slot;
logic [31:0] t_lba;
logic        ch_busy, ch_aud;
logic        a_req, a_frame, a_half, a_done;
logic [31:0] a_lba;

// ---- the buffers, the CPU's ports -----------------------------------------------------------------
logic [9:0]  rb_a;
logic [7:0]  rb_q;
logic        wb_we;
logic [9:0]  wb_a;
logic [7:0]  wb_d;
logic [12:0] fr_ra;
logic [7:0]  fr_q;
always_ff @(posedge clk) begin
	rb_q <= rbuf[rb_a];
	fr_q <= frb[fr_ra];
	if (wb_we) wbuf[wb_a] <= wb_d;
end

// ---- the target -----------------------------------------------------------------------------------
typedef enum logic [5:0] {
	T_IDLE, T_SELECTED, T_PHASE, T_REQ, T_ACK, T_UNACK,
	T_MSGOUT_DONE, T_CMD_DONE, T_EXEC, T_RD_START, T_RD_WAIT, T_RD_BYTE, T_RD_NEXT,
	T_WR_BYTE, T_WR_BLOCK, T_WR_FLUSH, T_DATA_IN, T_DATA_OUT, T_DOUT_BYTE, T_MSEL,
	T_FWD_CP, T_FWD_W, T_TBO, T_TBO_B, T_TBO_W, T_TB_CP, T_TB_W, T_TB_DEC,
	T_PEEKW, T_PEEK, T_PROBE, T_PROBE_D, T_STATUS, T_MSGIN, T_MSGX, T_MSGX_N, T_FREE
} t_t;
t_t ts, t_after, pk_ret, fwd_ret;       // the state; where a byte's handshake, a peek, a forward return to

logic [1:0]  cur;                       // the target selected: 0, 1 the disks, 2 the CD
logic [2:0]  ph;                        // the phase being driven: MSG C/D I/O
logic [7:0]  ob;                        // the byte going out (in-phases)
logic [7:0]  ib;                        // the byte that came in (out-phases)
logic [7:0]  cdb [16];
logic [4:0]  cdb_n, cdb_len;            // bytes of the command so far, and its length
logic        ext_msg;                   // an extended message came
logic [7:0]  mo [5];                    // a message out's bytes (after IDENTIFY)
logic [7:0]  mi [5];                    // a message in's bytes, mi_len of them
logic [2:0]  mi_n, mi_len;
logic        mo_late;                   // the message out came after a message in
logic        cmd_seen;                  // the command came: after the messages, bus free
logic [3:0]  sense_key [3];
logic [7:0]  sense_asc [3];
logic [7:0]  status;
logic [31:0] lba;                       // the next block
logic [31:0] blocks_left;               // blocks still to move
logic [9:0]  rd_last;                   // bytes of a read's last block (1-512)
logic [2:0]  rd_slot;
logic [8:0]  bidx;                      // the byte within the block
logic        half;                      // the buffer half in use
logic [1:0]  wr_out;                    // write: blocks handed to the card and not yet done (0-2)
logic [9:0]  rlen;                      // a response's length
logic [9:0]  ridx;                      // ... its next byte
logic [3:0]  rkind;                     // which response
logic [15:0] dout_len;                  // data out still to come
logic [9:0]  didx;                      // ... where the next byte goes (a kept list)
logic        dout_keep;                 // ... kept in the write buffer (a CD MODE SELECT)
logic [7:0]  ms_b3, ms_b10, ms_b11;     // ... the bytes a CD MODE SELECT is judged on
logic [7:0]  fwd_op;                    // a forward's opcode
logic        fwd_poke;                  // ... tell the audio when it has landed
logic [3:0]  cp;                        // a copy's byte
logic [2:0]  pk_i;                      // a peek's step
logic [7:0]  pk [5];                    // bytes 0-4 of the read buffer
logic [16:0] tbo_p, tbo_left;           // a Toolbox SEND: its payload's next byte, bytes still to come
logic [23:0] tb_pos;                    // ... the upload's next 512-byte block (the client's chunked D4 counts chunks)
logic [1:0]  tb_dir;                    // 0 data in, 1 data out, 2 none
logic [2:0]  tb_slot;
logic        tb_dbg;                    // TOGGLE DEBUG's flag
logic        cd_ok;                     // the Main speaks the CD contract (its INQUIRY window answered)
logic        cd_ejected, cd_prevent;
logic        probe_pend, hk_ff, hk_fe;  // housekeeping owed
logic        hk_on;                     // ... under way (off the bus)
logic        a_fwd_ev, a_stop_ev;       // to the audio
localparam int unsigned PD_CLKS = CLK_HZ / 1_000_000 * PHASE_US;
logic [2:0]  ph_q;                      // the phase of the last REQ
logic [15:0] pd_cnt;                    // clocks before a new phase's first REQ

wire is_cd   = cur == 2'd2;
wire cd_disc = m_valid[2] && !cd_ejected;
logic cd_audio_only;

assign t_bsy = ts != T_IDLE && !hk_on;
assign {t_msg, t_cd, t_io} = t_bsy && ts != T_SELECTED ? ph : 3'b000;
assign t_req = (ts == T_REQ);
assign t_db  = (ts == T_REQ || ts == T_ACK) && ph[0] ? ob : 8'h00;

// the opcode's command length (SCSI-2's groups; C0-DF, Apple's and the Toolbox's, 10)
function automatic logic [4:0] grp_len(input logic [7:0] op);
	case (op[7:5])
		3'd0:             grp_len = 5'd6;
		3'd1, 3'd2, 3'd6: grp_len = 5'd10;
		3'd4:             grp_len = 5'd16;
		3'd5:             grp_len = 5'd12;
		default:          grp_len = 5'd6;
	endcase
endfunction

// ---- the fixed responses ------------------------------------------------------------------------------
localparam logic [3:0] R_INQ = 4'd0, R_SENSE = 4'd1, R_CAP = 4'd2, R_MODE = 4'd3, R_BUF = 4'd4,
                       R_HDR = 4'd5, R_P31 = 4'd6, R_DEV = 4'd7, R_DBG = 4'd8;
localparam logic [8*36-1:0] INQ = {8'h00, 8'h00, 8'h02, 8'h02, 8'd31, 8'h00, 8'h00, 8'h00,
                                   "QUANTUM ", "MiSTer PPCMac HD", "1.0 "};
localparam logic [8*22-1:0] APPLE = {"APPLE COMPUTER, INC", 24'h202020};
localparam logic [8*41-1:0] BEST  = "BlueSCSI is the BEST STOLEN FROM BLUESCSI";

wire [31:0] last_lba = is_cd ? {2'b00, m_blocks[2][31:2]} - 32'd1 : m_blocks[cur] - 32'd1;
wire [5:0]  pg       = cdb[2][5:0];
// MODE SENSE(6): the header and block descriptor, then the pages asked for
// (1: 12 bytes, 3 and 4: 24, 30: 24; 3F: all four)
wire        pg_all   = pg == 6'h3F;
wire [9:0]  mode_len = 10'd12 + ((pg_all || pg == 6'h01) ? 10'd12 : 10'd0) + ((pg_all || pg == 6'h03) ? 10'd24 : 10'd0) +
                       ((pg_all || pg == 6'h04) ? 10'd24 : 10'd0) + ((pg_all || pg == 6'h30) ? 10'd24 : 10'd0);
wire [9:0]  o3       = 10'd12 + ((pg_all || pg == 6'h01) ? 10'd12 : 10'd0);   // where page 3 starts
wire [9:0]  o4       = o3 + ((pg_all || pg == 6'h03) ? 10'd24 : 10'd0);
wire [9:0]  o30      = o4 + ((pg_all || pg == 6'h04) ? 10'd24 : 10'd0);
wire [23:0] cyls     = m_blocks[cur][31:8];                   // 64 sectors, 4 heads, as scsihd.cpp

function automatic logic [7:0] mode_byte(input logic [9:0] i);
	logic [9:0] k;
	mode_byte = 8'h00;
	if (i < 10'd12) begin
		case (i[3:0])
			4'd0:  mode_byte = 8'(mode_len - 10'd1);
			4'd2:  mode_byte = m_ro[cur] ? 8'h80 : 8'h00;
			4'd3:  mode_byte = 8'd8;
			4'd5:  mode_byte = m_blocks[cur][23:16];
			4'd6:  mode_byte = m_blocks[cur][15:8];
			4'd7:  mode_byte = m_blocks[cur][7:0];
			4'd10: mode_byte = 8'h02;
			default: ;
		endcase
	end
	else if ((pg_all || pg == 6'h01) && i < o3) begin      // read-write error recovery
		k = i - 10'd12;
		if (k == 10'd0) mode_byte = 8'h01;
		if (k == 10'd1) mode_byte = 8'h0A;
	end
	else if ((pg_all || pg == 6'h03) && i >= o3 && i < o4) begin   // format: scsihd.cpp's values
		k = i - o3;
		case (k[4:0])
			5'd0:  mode_byte = 8'h03;
			5'd1:  mode_byte = 8'h16;
			5'd3:  mode_byte = 8'd6;
			5'd5:  mode_byte = 8'd1;
			5'd11: mode_byte = 8'd64;
			5'd12: mode_byte = 8'h02;
			5'd15: mode_byte = 8'd1;
			5'd17: mode_byte = 8'd19;
			5'd19: mode_byte = 8'd25;
			5'd20: mode_byte = 8'h80;
			default: ;
		endcase
	end
	else if ((pg_all || pg == 6'h04) && i >= o4 && i < o30) begin  // rigid geometry
		k = i - o4;
		case (k[4:0])
			5'd0: mode_byte = 8'h04;
			5'd1: mode_byte = 8'h16;
			5'd2: mode_byte = cyls[23:16];
			5'd3: mode_byte = cyls[15:8];
			5'd4: mode_byte = cyls[7:0];
			5'd5: mode_byte = 8'd4;
			default: ;
		endcase
	end
	else if ((pg_all || pg == 6'h30) && i >= o30) begin             // Apple's: the vendor text
		k = i - o30;
		if (k == 10'd0) mode_byte = 8'h30;
		else if (k == 10'd1) mode_byte = 8'h16;
		else if (k < 10'd24) mode_byte = APPLE[8 * (23 - k[4:0]) +: 8];
	end
endfunction

function automatic logic [7:0] resp_byte(input logic [3:0] kind, input logic [9:0] i);
	resp_byte = 8'h00;
	case (kind)
		R_INQ:   if (i < 10'd36) resp_byte = INQ[8 * (35 - i[5:0]) +: 8];
		R_SENSE: case (i[4:0])
			5'd0:  resp_byte = 8'h70;
			5'd2:  resp_byte = {4'h0, sense_key[cur]};
			5'd7:  resp_byte = 8'h0A;
			5'd12: resp_byte = sense_asc[cur];
			default: ;
		endcase
		R_CAP:   case (i[2:0])
			3'd0: resp_byte = last_lba[31:24];
			3'd1: resp_byte = last_lba[23:16];
			3'd2: resp_byte = last_lba[15:8];
			3'd3: resp_byte = last_lba[7:0];
			3'd6: resp_byte = is_cd ? 8'h08 : 8'h02;
			default: ;
		endcase
		R_MODE:  resp_byte = mode_byte(i);
		R_BUF:   if (i == 10'd1) resp_byte = 8'h01;      // READ BUFFER: a 64 KB buffer, as scsihd.cpp
		R_HDR:   case (i[3:0])                           // READ HEADER: the data mode, the address
			4'd0: resp_byte = cd_audio_only ? 8'h00 : 8'h01;
			4'd4: resp_byte = cdb[2];
			4'd5: resp_byte = cdb[3];
			4'd6: resp_byte = cdb[4];
			4'd7: resp_byte = cdb[5];
			default: ;
		endcase
		R_P31:   case (i)                                // the Toolbox's page 31: 56 bytes
			10'd0:  resp_byte = 8'd55;
			10'd3:  resp_byte = 8'd8;
			10'd10: resp_byte = 8'h02;
			10'd12: resp_byte = 8'h31;
			10'd13: resp_byte = 8'h2A;
			default: if (i >= 10'd14 && i < 10'd55) resp_byte = BEST[8 * (54 - i[5:0]) +: 8];
		endcase
		R_DEV:   if (cdb[1] == 8'h01) resp_byte = (i == 10'd1) ? 8'h82 : 8'h00;   // capabilities
		         else resp_byte = (i == 10'd0) ? 8'h00 : 8'hFF;                   // the devices: ID 0
		R_DBG:   resp_byte = {7'd0, tb_dbg};
		default: ;
	endcase
endfunction

// the command's fields
wire [7:0]  op      = cdb[0];
wire [31:0] lba6    = {11'd0, cdb[1][4:0], cdb[2], cdb[3]};
wire [31:0] lba10   = {cdb[2], cdb[3], cdb[4], cdb[5]};
wire [31:0] cnt6    = (cdb[4] == 8'd0) ? 32'd256 : {24'd0, cdb[4]};
wire [31:0] cnt10   = {16'd0, cdb[7], cdb[8]};
wire [31:0] cnt12   = {cdb[6], cdb[7], cdb[8], cdb[9]};
wire [15:0] alloc6  = {8'd0, cdb[4]};
wire [15:0] alloc10 = {cdb[7], cdb[8]};
// a read's blocks: the CD's are four of the slot's
wire [31:0] rd_l    = (op == 8'h08) ? lba6 : lba10;
wire [31:0] rd_n    = (op == 8'h08) ? cnt6 : (op == 8'hA8) ? cnt12 : cnt10;
wire [31:0] rd_l4   = is_cd ? {rd_l[29:0], 2'b00} : rd_l;
wire [31:0] rd_n4   = is_cd ? {rd_n[29:0], 2'b00} : rd_n;
// the Toolbox: on ID 0 file sharing (slot 3), on ID 3 the CD changer (slot 5)
wire        tb_fs   = cur == 2'd0 && m_tb && op >= 8'hD0 && op <= 8'hD5;
wire        tb_cdc  = is_cd && m_cdc && (op == 8'hD7 || op == 8'hD8 || op == 8'hDA);
wire [16:0] tb_send = (op == 8'hD3) ? 17'd33 : (cdb[6] == 8'd0) ? 17'd512 : {cdb[6], 9'd0};
wire [8:0]  tbo_t   = 9'(tbo_p - 17'd496);                   // a SEND's byte in its tail block
// the Toolbox's status block: {status, B5, the length's 15-0, its bit 16}
wire [16:0] tb_len  = {pk[4][0], pk[2], pk[3]};
wire [16:0] tb_len9 = tb_len + 17'd511;
wire [9:0]  tb_last = (tb_len[8:0] == 9'd0) ? 10'd512 : {1'b0, tb_len[8:0]};

// the commands that need a disc in the drive
function automatic logic cd_needs_media(input logic [7:0] o);
	case (o)
		8'h00, 8'h08, 8'h28, 8'hA8, 8'h25, 8'h43, 8'hC1, 8'hC2, 8'hCC, 8'hCE,
		8'h42, 8'h44, 8'hC8, 8'hC9, 8'hCA, 8'hCB, 8'hCD, 8'h45, 8'h47, 8'h48,
		8'h4B, 8'h4E, 8'hA5, 8'h01, 8'h0B, 8'h2B: cd_needs_media = 1'b1;
		default: cd_needs_media = 1'b0;
	endcase
endfunction

function automatic logic [9:0] clamp(input logic [9:0] n, input logic [15:0] alloc);
	clamp = (alloc < {6'd0, n}) ? alloc[9:0] : n;
endfunction

// a block move starting: is it inside the image?
function automatic logic in_range(input logic [31:0] first, input logic [31:0] n, input logic [31:0] size);
	in_range = (first < size) && (n <= size - first);
endfunction

task automatic check(input logic [3:0] key, input logic [7:0] asc);
	status         <= 8'h02;
	sense_key[cur] <= key;
	sense_asc[cur] <= asc;
	ts             <= T_STATUS;
endtask

// a fixed response
task automatic respond(input logic [3:0] kind, input logic [9:0] n);
	rkind <= kind;
	rlen  <= n;
	ridx  <= 10'd0;
	ts    <= T_DATA_IN;
endtask

// blocks from a slot, the last one perhaps short
task automatic read_blocks(input logic [2:0] slot, input logic [31:0] first, input logic [31:0] n,
                           input logic [9:0] last);
	rd_slot     <= slot;
	lba         <= first;
	blocks_left <= n;
	rd_last     <= last;
	ts          <= T_RD_START;
endtask

// the Main's answer from the CD's response window: one block, n bytes of it
task automatic fetch(input logic [31:0] win, input logic [9:0] n);
	if (n == 10'd0) ts <= T_STATUS;
	else read_blocks(3'd4, win, 32'd1, n);
endtask

// a CDB to the CD's command window, the status held until it is written
task automatic forward(input logic [7:0] o, input logic poke, input t_t ret);
	fwd_op   <= o;
	fwd_poke <= poke;
	fwd_ret  <= ret;
	cp       <= 4'd0;
	ts       <= T_FWD_CP;
endtask

// data out to take: kept (a CD MODE SELECT's list) or dropped
task automatic data_out(input logic [15:0] n, input logic keep);
	dout_len  <= n;
	didx      <= 10'd0;
	dout_keep <= keep;
	ts        <= T_DATA_OUT;
endtask

always_ff @(posedge clk) begin
	wb_we     <= 1'b0;
	a_done    <= 1'b0;
	a_fwd_ev  <= 1'b0;
	a_stop_ev <= 1'b0;

	// ---- the channel ----
	if (ch_busy) begin
		if (blk_idle) begin
			ch_busy <= 1'b0;
			if (ch_aud) a_done <= 1'b1;
			else t_rq <= 1'b0;
		end
	end
	else if (blk_idle) begin
		if (t_rq) begin
			c_bwe   <= t_we;   c_bslot <= t_slot; c_bhalf <= t_half; c_blba <= t_lba;
			c_baud  <= 1'b0;   c_bfr   <= 1'b0;
			c_btog  <= ~c_btog;
			ch_aud  <= 1'b0;   ch_busy <= 1'b1;
		end
		else if (a_req && !a_done) begin
			c_bwe   <= 1'b0;   c_bslot <= 3'd4;   c_bhalf <= a_half; c_blba <= a_lba;
			c_baud  <= 1'b1;   c_bfr   <= a_frame;
			c_btog  <= ~c_btog;
			ch_aud  <= 1'b1;   ch_busy <= 1'b1;
		end
	end

	// ---- the CD: a mount puts the disc back; a mount of the same disc is not a change ----
	if (cd_mev) begin
		cd_ejected <= 1'b0;
		probe_pend <= 1'b1;
	end

	case (ts)
		T_IDLE: begin
			// selected: SEL up, BSY down, our bit on the data lines, the image there
			if (b_sel && !b_bsy && !b_rst &&
			    ((b_db[0] && m_valid[0]) || (b_db[1] && m_valid[1]) || (b_db[3] && cd_ok))) begin
				cur <= (b_db[0] && m_valid[0]) ? 2'd0 : (b_db[1] && m_valid[1]) ? 2'd1 : 2'd2;
				ts  <= T_SELECTED;
			end
			else if (!b_sel && !b_rst) begin
				if (probe_pend) begin
					probe_pend <= 1'b0;
					hk_on <= 1'b1;
					ts <= T_PROBE;
				end
				else if (cd_ok && hk_ff) begin hk_ff <= 1'b0; hk_on <= 1'b1; forward(8'hFF, 1'b0, T_IDLE); end
				else if (cd_ok && hk_fe) begin hk_fe <= 1'b0; hk_on <= 1'b1; forward(8'hFE, 1'b0, T_IDLE); end
			end
		end
		T_SELECTED: if (!b_sel) begin       // BSY is up (t_bsy); the initiator let SEL go
			ext_msg  <= 1'b0;
			mo_late  <= 1'b0;
			cmd_seen <= 1'b0;
			cdb_n    <= 5'd0;
			if (b_atn) begin ph <= 3'b110; t_after <= T_MSGOUT_DONE; end
			else       begin ph <= 3'b010; t_after <= T_CMD_DONE; end
			ts <= T_PHASE;
		end

		// ---- one byte's handshake: the phase a clock before REQ (a new phase:
		// PHASE_US before), then REQ until ACK, then the byte taken
		// (out-phases), REQ down, and ACK let go
		T_PHASE: begin
			if (ph != ph_q) begin
				ph_q   <= ph;
				pd_cnt <= 16'(PD_CLKS);
			end
			else if (pd_cnt != 0) pd_cnt <= pd_cnt - 1'd1;
			else ts <= T_REQ;
		end
		T_REQ:   if (b_ack) begin ib <= b_db; ts <= T_ACK; end
		T_ACK:   ts <= T_UNACK;
		T_UNACK: if (!b_ack) ts <= t_after;

		// ---- MESSAGE OUT: bytes while ATN is up. SDTR is answered with offset 0 (asynchronous),
		// WDTR with 8 bits (Mac OS 8.5's driver asks for both), another extended message with
		// MESSAGE REJECT; after a message in, ABORT and its kind end the connection
		T_MSGOUT_DONE: begin
			logic [7:0] m0;
			m0 = (cdb_n == 5'd0) ? ib : mo[0];
			if (cdb_n == 5'd0 && ib == 8'h01) ext_msg <= 1'b1;   // an extended message's first byte
			if (!(cdb_n == 5'd0 && ib[7])) begin
				case (cdb_n)
					5'd0:    mo[0] <= ib;
					5'd1:    mo[1] <= ib;
					5'd2:    mo[2] <= ib;
					5'd3:    mo[3] <= ib;
					5'd4:    mo[4] <= ib;
					default: ;
				endcase
			end
			cdb_n <= (cdb_n == 5'd0 && ib[7]) ? 5'd0 : cdb_n + 5'd1;   // IDENTIFY ends a message
			if (b_atn) ts <= T_PHASE;                            // more
			else if (ext_msg || (cdb_n == 5'd0 && ib == 8'h01)) begin
				if (mo[1] == 8'h03 && mo[2] == 8'h01) begin
					mi[0] <= 8'h01; mi[1] <= 8'h03; mi[2] <= 8'h01; mi[3] <= mo[3]; mi[4] <= 8'h00;
					mi_len <= 3'd5;
				end
				else if (mo[1] == 8'h02 && mo[2] == 8'h03) begin
					mi[0] <= 8'h01; mi[1] <= 8'h02; mi[2] <= 8'h03; mi[3] <= 8'h00;
					mi_len <= 3'd4;
				end
				else begin
					mi[0]  <= 8'h07;                             // MESSAGE REJECT
					mi_len <= 3'd1;
				end
				mi_n    <= 3'd0;
				ext_msg <= 1'b0;
				cdb_n   <= 5'd0;
				ts <= T_MSGX;
			end
			else if (mo_late && (m0 == 8'h06 || m0 == 8'h0C || m0 == 8'h0D || m0 == 8'h0E))
				ts <= T_FREE;
			else begin
				cdb_n <= 5'd0;
				if (cmd_seen) ts <= T_FREE;
				else begin
					ph      <= 3'b010;
					t_after <= T_CMD_DONE;
					ts <= T_PHASE;
				end
			end
		end

		// ---- COMMAND ------------------------------------------------------------------------
		T_CMD_DONE: begin
			cdb[cdb_n[3:0]] <= ib;
			if (cdb_n == 5'd0) cdb_len <= grp_len(ib);
			cdb_n <= cdb_n + 5'd1;
			if (cdb_n != 5'd0 && cdb_n + 5'd1 == cdb_len) ts <= T_EXEC;
			else if (cdb_n == 5'd0 && grp_len(ib) == 5'd1) ts <= T_EXEC;
			else ts <= T_PHASE;
		end
		T_EXEC: begin
			status <= 8'h00;
			if (op != 8'h03) begin              // the sense is the previous command's
				sense_key[cur] <= 4'h0;
				sense_asc[cur] <= 8'h00;
			end
			ts <= T_STATUS;                     // unless a data phase comes first
			if (tb_fs || tb_cdc) begin          // the Toolbox: a round trip through the Main
				tb_slot <= tb_cdc ? 3'd5 : 3'd3;
				tbo_p   <= '0;
				if (op == 8'hD3 || op == 8'hD4) begin tb_dir <= 2'd1; tbo_left <= tb_send; ts <= T_TBO; end
				else begin
					tb_dir <= (op == 8'hD5 || op == 8'hD8) ? 2'd2 : 2'd0;
					cp <= 4'd0;
					ts <= T_TB_CP;
				end
			end
			else if (cur == 2'd0 && m_tb && op == 8'hD9)
				respond(R_DEV, (cdb[8] == 8'd0 || cdb[8] > 8'd8) ? 10'd8 : {2'b00, cdb[8]});
			else if (cur == 2'd0 && m_tb && op == 8'hD6) begin
				if (cdb[1] != 8'd0) respond(R_DBG, 10'd1);
				else tb_dbg <= cdb[2] != 8'd0;
			end
			else if (op == 8'h1A && pg == 6'h31 && ((cur == 2'd0 && m_tb) || (is_cd && m_cdc)))
				respond(R_P31, clamp(10'd56, alloc6));
			else if (is_cd) begin
				if (!cd_disc && cd_needs_media(op)) check(4'h2, 8'hB0);   // AppleCD's no-disc answer
				else if (cd_audio_only && (op == 8'h08 || op == 8'h28 || op == 8'hA8)) check(4'h5, 8'h64);
				else case (op)
					8'h00, 8'h2B, 8'hBB: ;              // TEST UNIT READY, SEEK, SET CD SPEED: GOOD
					8'h03: respond(R_SENSE, clamp(10'd18, alloc6));
					8'h12: fetch(WIN_RESP | 32'h0012_0000, clamp(10'd54, alloc6));
					8'h1A: fetch(WIN_RESP | 32'h001A_0000 | {16'd0, cdb[2], 8'd0},
					             clamp((pg == 6'h30) ? 10'd36 : (pg == 6'h0E) ? 10'd28 : (pg == 6'h2A) ? 10'd38 : 10'd12, alloc6));
					8'h15: if (cdb[4] != 8'd0) data_out(alloc6, cdb[4] >= 8'd4);   // MODE SELECT: judged below
					8'h25: respond(R_CAP, 10'd8);
					8'h08, 8'h28, 8'hA8: begin
						if (!in_range(rd_l4, rd_n4, m_blocks[2])) check(4'h5, 8'h21);
						else if (rd_n4 != 32'd0) begin
							a_stop_ev <= 1'b1;                                  // a data read stops the audio
							read_blocks(3'd4, rd_l4, rd_n4, 10'd512);
						end
					end
					8'h1B, 8'hC0: begin                 // START STOP UNIT (LoEj, not Start), Apple's EJECT
						if (op == 8'hC0 || (cdb[4][1] && !cdb[4][0])) begin
							if (cd_prevent) check(4'h5, 8'h80);
							else begin
								cd_ejected     <= 1'b1;
								sense_key[cur] <= 4'h2;      // what a later REQUEST SENSE sees
								sense_asc[cur] <= 8'h3A;
								a_stop_ev      <= 1'b1;
								forward(op, 1'b0, T_STATUS);
							end
						end
					end
					8'h1E: cd_prevent <= cdb[4][0];
					8'h43: fetch(WIN_RESP | 32'h0043_0000 | {16'd0, cdb[9], cdb[6]}, clamp(10'd512, alloc10));
					8'hC1: fetch(WIN_RESP | 32'h00C1_0000 | {16'd0, cdb[9], cdb[5]},
					             cdb[9][7] ? clamp(10'd400, {alloc10[15:2], 2'b00}) : clamp(10'd4, alloc10));
					8'hC2: fetch(WIN_RESP | 32'h00C2_0000, 10'd9);
					8'hCC: fetch(WIN_RESP | 32'h00CC_0000 | {16'd0, cdb[3], 8'd0}, 10'd6);
					8'h42: fetch(WIN_RESP | 32'h0042_0000 | {16'd0, cdb[3], cdb[6]}, clamp(10'd64, alloc10));
					8'h44: if (cdb[1][1]) check(4'h5, 8'h24); else respond(R_HDR, clamp(10'd16, alloc10));
					8'hCE: if (cdb[8] != 8'd0) data_out({8'd0, cdb[8]}, 1'b0);   // AUDIO CONTROL: dropped
					8'hC8, 8'hC9, 8'hCA, 8'hCB, 8'hCD, 8'h45, 8'h47, 8'h48, 8'h4B, 8'h4E, 8'hA5, 8'h01, 8'h0B:
						forward(op, 1'b1, T_STATUS);    // the transport: the Main's playhead
					default: check(4'h5, 8'h20);
				endcase
			end
			else begin
				ridx <= 10'd0;
				case (op)
					8'h00, 8'h01, 8'h0B, 8'h16, 8'h17, 8'h1B, 8'h1E, 8'h2B, 8'h2F, 8'h35: ;   // GOOD
					8'h04: if (cdb[1][4]) data_out(16'd4, 1'b0);
					8'h1D: if ({cdb[3], cdb[4]} != 16'd0) data_out({cdb[3], cdb[4]}, 1'b0);
					8'h15: if (cdb[4] != 8'd0) data_out(alloc6, 1'b0);
					8'h3B: if ({cdb[6], cdb[7], cdb[8]} != 24'd0)
						data_out((cdb[6] != 8'd0) ? 16'hFFFF : {cdb[7], cdb[8]}, 1'b0);
					8'h03: respond(R_SENSE, clamp(10'd18, alloc6));
					8'h12: respond(R_INQ,   clamp(10'd36, alloc6));
					8'h1A: respond(R_MODE,  clamp(mode_len, alloc6));
					8'h25: respond(R_CAP,   10'd8);
					8'h3C: respond(R_BUF,   clamp(10'd4, {cdb[7], cdb[8]}));
					8'h08, 8'h28: begin
						if (!in_range(rd_l, rd_n, m_blocks[cur])) check(4'h5, 8'h21);
						else if (rd_n != 32'd0) read_blocks({1'b0, cur}, rd_l, rd_n, 10'd512);
					end
					8'h0A, 8'h2A: begin
						lba         <= (op == 8'h0A) ? lba6 : lba10;
						blocks_left <= (op == 8'h0A) ? cnt6 : cnt10;
						if (m_ro[cur]) check(4'h7, 8'h27);
						else if (!in_range((op == 8'h0A) ? lba6 : lba10, (op == 8'h0A) ? cnt6 : cnt10, m_blocks[cur]))
							check(4'h5, 8'h21);
						else if (((op == 8'h0A) ? cnt6 : cnt10) != 32'd0) begin
							half   <= 1'b0;
							bidx   <= 9'd0;
							wr_out <= 2'd0;
							ph     <= 3'b000;
							t_after <= T_WR_BYTE;
							ts <= T_PHASE;
						end
					end
					default: check(4'h5, 8'h20);
				endcase
			end
		end

		// ---- a fixed response, DATA IN ------------------------------------------------------
		T_DATA_IN: begin
			if (ridx == rlen) ts <= T_STATUS;
			else begin
				ob   <= resp_byte(rkind, ridx);
				ridx <= ridx + 10'd1;
				ph   <= 3'b001;
				t_after <= T_DATA_IN;
				ts <= T_PHASE;
			end
		end
		// ---- DATA OUT: taken, kept or dropped -----------------------------------------------
		T_DATA_OUT: begin
			if (dout_len == 16'd0) ts <= dout_keep ? T_MSEL : T_STATUS;
			else begin
				ph <= 3'b000;
				t_after <= T_DOUT_BYTE;
				ts <= T_PHASE;
			end
		end
		T_DOUT_BYTE: begin
			if (dout_keep) begin
				wb_we <= 1'b1;
				wb_a  <= didx;
				wb_d  <= ib;
				case (didx)
					10'd3:  ms_b3  <= ib;
					10'd10: ms_b10 <= ib;
					10'd11: ms_b11 <= ib;
					default: ;
				endcase
			end
			didx     <= didx + 10'd1;
			dout_len <= dout_len - 16'd1;
			ts <= T_DATA_OUT;
		end
		// a CD MODE SELECT's list: a block descriptor the list holds, asking for 2048-byte blocks
		T_MSEL: begin
			if (ms_b3 != 8'd0 && {8'd0, ms_b3} + 16'd4 > alloc6) check(4'h5, 8'h26);
			else if (ms_b3 != 8'd0 && {ms_b10, ms_b11} != 16'h0800) check(4'h5, 8'h26);
			else forward(8'h15, 1'b0, T_STATUS);
		end

		// ---- a forward: the CDB at 496, the block to the command window ------------------------
		T_FWD_CP: begin
			wb_we <= 1'b1;
			wb_a  <= 10'd496 + {6'd0, cp};
			wb_d  <= cdb[cp];
			cp    <= cp + 4'd1;
			if (cp == 4'd11) begin
				t_rq <= 1'b1; t_we <= 1'b1; t_slot <= 3'd4; t_half <= 1'b0;
				t_lba <= WIN_CMD | {8'd0, fwd_op, 16'd0};
				ts <= T_FWD_W;
			end
		end
		T_FWD_W: if (!t_rq) begin
			if (fwd_poke) a_fwd_ev <= 1'b1;
			hk_on <= 1'b0;
			ts <= fwd_ret;
		end

		// ---- READ: blocks from the card, two halves --------------------------------------------
		T_RD_START: if (!t_rq) begin        // the first block into half 0
			t_rq <= 1'b1; t_we <= 1'b0; t_slot <= rd_slot; t_half <= 1'b0; t_lba <= lba;
			half <= 1'b0;
			ts   <= T_RD_WAIT;
		end
		T_RD_WAIT: if (!t_rq) begin         // the block is in: send it, fetch the next
			lba         <= lba + 32'd1;
			blocks_left <= blocks_left - 32'd1;
			bidx        <= 9'd0;
			rb_a        <= {half, 9'd0};
			if (blocks_left != 32'd1) begin
				t_rq <= 1'b1; t_half <= ~half; t_lba <= lba + 32'd1;
			end
			ts <= T_RD_NEXT;
		end
		T_RD_NEXT: ts <= T_RD_BYTE;         // the buffer's read takes a clock
		T_RD_BYTE: begin
			ob   <= rb_q;
			ph   <= 3'b001;
			bidx <= bidx + 9'd1;
			rb_a <= {half, bidx + 9'd1};
			t_after <= T_RD_NEXT;
			if (bidx == 9'd511 || (blocks_left == 32'd0 && {1'b0, bidx} == rd_last - 10'd1)) begin
				half    <= ~half;
				t_after <= (blocks_left == 32'd0) ? T_STATUS : T_RD_WAIT;
			end
			ts <= T_PHASE;
		end

		// ---- WRITE: blocks to the card, two halves -----------------------------------------------
		T_WR_BYTE: begin                    // a byte came: into the write buffer
			wb_we <= 1'b1;
			wb_a  <= {half, bidx};
			wb_d  <= ib;
			bidx  <= bidx + 9'd1;
			if (bidx == 9'd511) ts <= T_WR_BLOCK;
			else ts <= T_PHASE;
		end
		T_WR_BLOCK: if (!t_rq) begin        // the block to the card (the other half's is done)
			t_rq <= 1'b1; t_we <= 1'b1; t_slot <= {1'b0, cur}; t_half <= half; t_lba <= lba;
			lba         <= lba + 32'd1;
			blocks_left <= blocks_left - 32'd1;
			half <= ~half;
			bidx <= 9'd0;
			if (blocks_left == 32'd1) ts <= T_WR_FLUSH;
			else ts <= T_PHASE;             // the next block's bytes while this one is written
		end
		T_WR_FLUSH: if (!t_rq) ts <= T_STATUS;

		// ---- the Toolbox: a SEND's payload (the first 496 bytes under the CDB in block 0,
		// the rest as blocks 1, 2, ... from half 1), the request, its status, the data in ----
		T_TBO: begin
			if (tbo_left == 17'd0) begin
				if (tbo_p > 17'd496 && tbo_t != 9'd0) begin  // a part-filled tail block
					t_rq <= 1'b1; t_we <= 1'b1; t_slot <= tb_slot; t_half <= 1'b1;
					t_lba <= {15'd0, 17'd1 + ((tbo_p - 17'd496) >> 9)};
				end
				cp <= 4'd0;
				ts <= T_TB_CP;
			end
			else begin
				ph <= 3'b000;
				t_after <= T_TBO_B;
				ts <= T_PHASE;
			end
		end
		T_TBO_B: begin
			wb_we    <= 1'b1;
			wb_a     <= (tbo_p < 17'd496) ? 10'(tbo_p + 17'd16) : {1'b1, tbo_t};
			wb_d     <= ib;
			tbo_p    <= tbo_p + 17'd1;
			tbo_left <= tbo_left - 17'd1;
			if (tbo_p >= 17'd496 && tbo_t == 9'd511) begin  // a tail block full
				t_rq <= 1'b1; t_we <= 1'b1; t_slot <= tb_slot; t_half <= 1'b1;
				t_lba <= {15'd0, 17'd1 + ((tbo_p - 17'd496) >> 9)};
				ts <= T_TBO_W;
			end
			else ts <= T_TBO;
		end
		T_TBO_W: if (!t_rq) ts <= T_TBO;
		T_TB_CP: if (!t_rq) begin           // block 0: the CDB, the direction, the payload's length
			wb_we <= 1'b1;
			wb_a  <= {6'd0, cp};
			wb_d  <= (op == 8'hD4 && cdb[6] > 8'd1 && cp == 4'd3) ? tb_pos[23:16] :
			         (op == 8'hD4 && cdb[6] > 8'd1 && cp == 4'd4) ? tb_pos[15:8] :
			         (op == 8'hD4 && cdb[6] > 8'd1 && cp == 4'd5) ? tb_pos[7:0] :
			         (cp < 4'd10) ? cdb[cp] : (cp == 4'd10) ? {6'd0, tb_dir} :
			         (cp == 4'd11) ? tb_send[15:8] : tb_send[7:0];
			cp    <= cp + 4'd1;
			if (cp == 4'd12) begin
				if (op == 8'hD3) tb_pos <= 24'd0;
				else if (op == 8'hD4) tb_pos <= tb_pos + ((cdb[6] == 8'd0) ? 24'd1 : {16'd0, cdb[6]});
				t_rq <= 1'b1; t_we <= 1'b1; t_slot <= tb_slot; t_half <= 1'b0; t_lba <= 32'd0;
				ts <= T_TB_W;
			end
		end
		T_TB_W: if (!t_rq) begin            // the status block
			t_rq <= 1'b1; t_we <= 1'b0; t_slot <= tb_slot; t_half <= 1'b0; t_lba <= 32'd0;
			pk_ret <= T_TB_DEC;
			ts <= T_PEEKW;
		end
		T_TB_DEC: begin
			if (pk[1] != 8'hB5) check(4'h5, 8'h20);
			else begin
				status <= pk[0];
				if (pk[0] != 8'h00) begin sense_key[cur] <= 4'h5; sense_asc[cur] <= 8'h20; end
				if (tb_dir == 2'd0 && tb_len != 17'd0)
					read_blocks(tb_slot, 32'd1, {24'd0, tb_len9[16:9]}, tb_last);
				else ts <= T_STATUS;
			end
		end

		// ---- once the block is in, bytes 0-4 of the read buffer's half 0 into pk -----------------
		T_PEEKW: if (!t_rq) begin
			pk_i <= 3'd0;
			ts   <= T_PEEK;
		end
		T_PEEK: begin
			rb_a <= {7'd0, pk_i};
			if (pk_i >= 3'd2) pk[pk_i - 3'd2] <= rb_q;
			pk_i <= pk_i + 3'd1;
			if (pk_i == 3'd6) ts <= pk_ret;
		end

		// ---- the probe: does the Main answer the CD's INQUIRY window? -----------------------------
		T_PROBE: if (!t_rq) begin
			t_rq <= 1'b1; t_we <= 1'b0; t_slot <= 3'd4; t_half <= 1'b0; t_lba <= WIN_RESP | 32'h0012_0000;
			pk_ret <= T_PROBE_D;
			ts     <= T_PEEKW;
		end
		T_PROBE_D: begin
			cd_ok <= pk[0] == 8'h05 && pk[1] == 8'h80 && pk[2] == 8'h02 && pk[3] == 8'h02;
			hk_on <= 1'b0;
			ts <= T_IDLE;
		end

		// ---- STATUS, MESSAGE IN, bus free -----------------------------------------------------------
		T_STATUS: begin
			ob <= status;
			ph <= 3'b011;
			t_after <= T_MSGIN;
			ts <= T_PHASE;
		end
		T_MSGIN: begin
			mi[0]    <= 8'h00;              // COMMAND COMPLETE
			mi_len   <= 3'd1;
			mi_n     <= 3'd0;
			cmd_seen <= 1'b1;
			ts <= T_MSGX;
		end
		T_MSGX: begin                       // the message in's bytes
			ob <= mi[mi_n];
			ph <= 3'b111;
			t_after <= T_MSGX_N;
			ts <= T_PHASE;
		end
		T_MSGX_N: begin                     // ACK down: with ATN up the initiator has a message
			if (b_atn) begin
				mo_late <= 1'b1;
				ext_msg <= 1'b0;
				cdb_n   <= 5'd0;
				ph      <= 3'b110;
				t_after <= T_MSGOUT_DONE;
				ts <= T_PHASE;
			end
			else if (mi_n + 3'd1 != mi_len) begin
				mi_n <= mi_n + 3'd1;
				ts <= T_MSGX;
			end
			else if (cmd_seen) ts <= T_FREE;
			else begin
				cdb_n   <= 5'd0;
				ph      <= 3'b010;
				t_after <= T_CMD_DONE;
				ts <= T_PHASE;
			end
		end
		T_FREE: begin                       // ACK is down (T_UNACK): BSY let go
			ph_q <= 3'b100;                 // (a reserved phase: the next connection's first REQ waits)
			ts   <= T_IDLE;
		end

		default: ts <= T_IDLE;
	endcase

	// the bus reset: everything let go (a block in flight finishes first); the
	// CD comes back and the Main's playhead stops
	if (b_rst) begin
		if (!hk_on) ts <= T_IDLE;
		ph_q       <= 3'b100;
		cd_ejected <= 1'b0;
		if (cd_ok) hk_fe <= 1'b1;
	end

	if (reset) begin
		ts      <= T_IDLE;
		ph_q    <= 3'b100;
		pd_cnt  <= 16'd0;
		t_after <= T_IDLE;
		ph      <= 3'b000;
		ob      <= 8'h00;
		cur     <= 2'd0;
		half    <= 1'b0;
		ext_msg <= 1'b0;
		mo_late <= 1'b0;
		cmd_seen <= 1'b0;
		mi_n    <= 3'd0;
		mi_len  <= 3'd1;
		wb_we   <= 1'b0;
		dout_keep  <= 1'b0;
		tb_dbg     <= 1'b0;
		tb_pos     <= 24'd0;
		cd_ejected <= 1'b0;
		cd_prevent <= 1'b0;
		probe_pend <= 1'b1;
		hk_ff      <= 1'b1;
		hk_fe      <= 1'b0;
		hk_on      <= 1'b0;
		for (int i = 0; i < 3; i++) begin
			sense_key[i] <= 4'h0;
			sense_asc[i] <= 8'h00;
		end
	end
end

// ---- the trace: kind 1 a command's status, 2 a bus reset, 3 a mount on the CD's slot ----
logic [31:0] tr_us = 32'd0;
logic [15:0] tr_div = 16'd0;
logic [31:0] tr_bytes;                  // data bytes the command moved
logic        tr_rst_q = 1'b0;
t_t          tr_ts_q;
wire  [7:0]  tr_id   = is_cd ? 8'd3 : {6'd0, cur};
wire  [7:0]  tr_flag = {cd_ok, cd_ejected, cd_prevent, m_valid[2], m_tb, m_cdc, m_valid[1:0] != 2'b00, hk_on};
always_ff @(posedge clk) begin
	tr_ev    <= 1'b0;
	tr_ts_q  <= ts;
	tr_rst_q <= b_rst;
	if (tr_div == 16'(CLK_HZ / 1_000_000 - 1)) begin
		tr_div <= 16'd0;
		tr_us  <= tr_us + 32'd1;
	end
	else tr_div <= tr_div + 16'd1;
	if (ts == T_EXEC) tr_bytes <= 32'd0;
	else if (ts == T_ACK && ph[2:1] == 2'b00) tr_bytes <= tr_bytes + 32'd1;
	if (ts == T_STATUS && tr_ts_q != T_STATUS) begin
		tr_ev  <= 1'b1;
		tr_rec <= {8'd0, 8'(cdb_len), 3'd0, tb_dir, tb_slot, pk[4], pk[3], pk[2], pk[1], pk[0],
		           tr_bytes, tr_flag, sense_asc[cur], cdb[9], cdb[8],
		           cdb[7], cdb[6], cdb[5], cdb[4], cdb[3], cdb[2], cdb[1], cdb[0],
		           tr_us, 4'd0, sense_key[cur], status, tr_id, 8'd1};
	end
	else if (ts == T_EXEC) begin                // kind 7: a command starts
		tr_ev  <= 1'b1;
		tr_rec <= {64'd0, 32'd0, tr_flag, 8'd0, cdb[9], cdb[8],
		           cdb[7], cdb[6], cdb[5], cdb[4], cdb[3], cdb[2], cdb[1], cdb[0],
		           tr_us, 16'd0, tr_id, 8'd7};
	end
	else if (b_rst && !tr_rst_q) begin
		tr_ev  <= 1'b1;
		tr_rec <= {96'd0, tr_flag, 88'd0, tr_us, 24'd0, 8'd2};
	end
	else if (cd_mev) begin
		tr_ev  <= 1'b1;
		tr_rec <= {96'd0, tr_flag, 88'd0, tr_us, 24'd0, 8'd3};
	end
end

// the channel's state and the requests' fields are not reset: a block in
// flight across the machine's reset finishes on the memory clock's side, and
// the toggles stay in step
initial begin
	c_btog  = 1'b0;
	c_bwe   = 1'b0;
	c_bslot = 3'd0;
	c_bhalf = 1'b0;
	c_baud  = 1'b0;
	c_bfr   = 1'b0;
	c_blba  = 32'd0;
	t_rq    = 1'b0;
	ch_busy = 1'b0;
	ch_aud  = 1'b0;
	cd_ok   = 1'b0;
end

// ---- the CD's audio ------------------------------------------------------------------------------
PPCMac_cdaudio #(.CLK_HZ(CLK_HZ)) cdaudio (
	.clk, .reset, .bus_rst(b_rst),
	.mounted(cd_disc && cd_ok), .mount_ev(cd_mev), .fwd_ev(a_fwd_ev), .stop_ev(a_stop_ev),
	.a_req, .a_lba, .a_frame, .a_half, .a_done,
	.cap_hdr(h_cap_hdr), .cap_ver(h_cap_ver), .cap_flags(h_cap_flags),
	.pad_ast(h_pad_ast), .pad_have(h_pad_have), .pad_gen(h_pad_gen),
	.fr_ra, .fr_q,
	/* verilator lint_off PINCONNECTEMPTY */
	.toc_ready(),
	/* verilator lint_on PINCONNECTEMPTY */
	.disc_audio(cd_audio_only),
	.snd_l(cd_left), .snd_r(cd_right)
);

endmodule

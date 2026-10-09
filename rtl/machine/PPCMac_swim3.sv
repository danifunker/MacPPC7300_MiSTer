//============================================================================
//
//  PPCMac - the machine around the CPU
//  The SWIM3, Grand Central's floppy controller, with an internal
//  Superdrive and a disk image in it (read only)
//
//  The registers as dingusppc's devices/floppy/swim3.cpp has them (its
//  read and write), the drive's command and status lines as its
//  superdrive.cpp answers them, and the disk at the level of its sectors,
//  as swim3.cpp reads one: an address field passes under the head, its
//  track, side, sector and format go into registers A, B and C and raise
//  ID_READ; the sector sought (first sector, then each next one) goes to
//  DMA channel 1 (the dev side of a PPCMac_dbdma): an MFM sector's 512
//  bytes, a GCR sector's 704 six-bit values as the chip leaves them for the
//  driver to decode (A_GCR; dingusppc sends 512 bytes, which Apple's driver
//  rejects); after "sectors to transfer" of them, SECT_DONE. The ROM's probe of the chip
//  (interrupt mask <- 0, mode set 01, mode clear 18, phase <- 5 and read
//  back: 5) finds it and the 68k .Sony driver (DRVR 4) installs; Mac OS
//  7.6.1's System needs that (the "bus error" at the welcome screen of
//  2026-10-07: SonyVars left at -1).
//
//  Registers, by (offset >> 4) & F (grandcentral.cpp maps them so):
//    0 data             reads 0: the data go by DMA
//    1 timer            written: counts down a microsecond at a time, the
//                       timer-done flag when it reaches 0; read: what is left
//    2 error            reads 0
//    3 parameter data   stored
//    4 phase            the four phase lines, read back; written with CA3
//                       (bit 3) high it strobes a command to the drive: the
//                       address from HEADSEL and bits 1-0, the value bit 2
//    5 setup            stored, read back
//    6 status / mode 0  read: the mode register; written: ones clear mode
//                       bits (GO cleared stops a disk access)
//    7 handshake / mode 1  read: the selected drive's status line for the
//                       address from HEADSEL and bits 2-0, in bits 2 and 3
//                       (RDDATA and SENSE, wired together); 0C with no drive
//                       selected; written: ones set mode bits, GO_STEP
//                       starting the steps, GO a disk access (not in write
//                       mode: writing is left out)
//    8 interrupt flags  read, and cleared by the read
//    9 step count       the steps to make: the first at once, then one every
//                       80 us, step-done at the last
//    A current track    the last address field's: side in bit 7, track
//    B current sector   ... bit 7 its CRC good, the sector number
//    C format           ... its format byte (GCR 02 or 22, MFM 02)
//    D first sector, E sectors to transfer, F interrupt mask   stored
//  The interrupt: INT_ENA (mode bit 0) and a flag that is unmasked
//  (swim3.cpp update_irq), Grand Central's source 13.
//
//  The drive (superdrive.cpp): commands 0 step direction (1 = back),
//  1 step (on 0; the track kept within 0-79), 2 motor (0 = on; ready
//  follows the disk), 3 eject (the disk out, the latch set, the drive back
//  to its reset state), 4 reset the latch, 5 drive mode (0 = MFM; ready
//  set). Status, in the drive's own inverted sense as dingusppc returns it:
//  1 step 1, 2 motor off, 3 eject latch, 4 head 0 (0; selects head 0),
//  5 MFM 1, 6 double sided 1, 7 drive exists 0, 8 no disk, 9 not write
//  protected (0 with a disk: they all are), A not track zero, C head 1 (1;
//  selects head 1), D drive mode, E not ready, F not high density.
//
//  The disk (PPCMac_fdblk gives its kind; a new image is a disk put in, an
//  emptied slot one taken out; the drive's mode follows the disk then, as
//  dingusppc's does): MFM 720K (9 sectors a track, numbered from 1) or
//  1440K (18), GCR 400K (one side) or 800K, 12 sectors on tracks 0-15 down
//  to 8 on 64-79, numbered from 0. Address fields come only while the motor
//  turns with a disk in and the drive's mode is the disk's (and not from
//  side 1 of a one-sided disk). The timing is
//  dingusppc's (an MFM track for all): an index gap of 2,336 us, then each
//  sector's 10,800 us (10,528 at double density), its address field 352 us
//  in and its data done 8,576 us in.
//
//  Left out (docs/PPCMac_stubs.md): writing and formatting, the second
//  drive, the error register's conditions, the sense interrupt.
//
//============================================================================

module PPCMac_swim3
(
	input  logic        clk,
	input  logic        reset,
	input  logic        us_tick,        // one clock a microsecond
	input  logic        sel,            // an access, for one cycle
	input  logic        we,
	input  logic [3:0]  rn,             // the register, (offset >> 4) & F
	input  logic [7:0]  wdata,
	output logic [7:0]  rq,             // what a read of rn returns now (the caller registers it)
	output logic        irq,

	// DMA channel 1's device side: a sector's bytes
	output logic        di_valid,
	output logic [7:0]  di_data,
	input  logic        di_take,
	output logic        di_flush,

	// the image (PPCMac_fdblk): the disk's kind, a sector read
	input  logic        m_t,
	input  logic        m_ok,
	input  logic [1:0]  m_fmt,
	input  logic        m_dc42,
	output logic        rq_t,
	output logic [11:0] rq_lba,
	input  logic        dn_t,
	output logic [9:0]  b_ra,
	input  logic [7:0]  b_q
);

localparam logic [7:0] I_TIMER = 8'h01;
localparam logic [7:0] I_STEP  = 8'h02;
localparam logic [7:0] I_ID    = 8'h04;
localparam logic [7:0] I_SECT  = 8'h08;

localparam int T_INDEX = 2336, T_AM = 352, T_DATA = 8576, T_SEC_HD = 10800, T_SEC_DD = 10528;

logic [7:0] setup_r, mode_r, int_flags, int_mask, step_count, xfer_cnt, first_sec, pram, timer_val;
logic [3:0] phase;
// the drive
logic       motor_on, eject_latch, drive_mfm, ready, step_back, head;
logic [6:0] track;
// stepping under way: the microseconds to the next step
logic       stepping;
logic [6:0] step_wait;
// the disk
logic       has_disk, d_dc42;
logic [1:0] d_fmt;
logic [2:0] m_s;
logic       m_h;
wire        d_mfm = d_fmt[1];
wire        d_hd  = d_fmt == 2'd3;
wire        d_ds  = d_fmt != 2'd0;

// the command address of a phase write (the lines as written), the status
// address of a handshake read (the lines as they are)
wire [3:0] cmd_addr  = {1'b0, mode_r[5], wdata[1:0]};
wire [3:0] stat_addr = {mode_r[5], phase[2:0]};
wire [6:0] stepped   = step_back ? (track == 7'd0 ? 7'd0 : track - 7'd1) : (track == 7'd79 ? 7'd79 : track + 7'd1);

logic stat;
always_comb begin
	case (stat_addr)
		4'h1:    stat = 1'b1;
		4'h2:    stat = ~motor_on;
		4'h3:    stat = eject_latch;
		4'h4:    stat = 1'b0;
		4'h5:    stat = 1'b1;
		4'h6:    stat = 1'b1;
		4'h7:    stat = 1'b0;           // the drive is there
		4'h8:    stat = ~has_disk;
		4'h9:    stat = ~has_disk;      // a disk is write-protected
		4'hA:    stat = track != 7'd0;
		4'hC:    stat = 1'b1;
		4'hD:    stat = drive_mfm;
		4'hE:    stat = ~ready;
		4'hF:    stat = has_disk & ~d_hd;
		default: stat = 1'b0;
	endcase
end

// ---- the disk turning: a slot of the track (a sector, or the index gap at
// rot_sec >= spt) and the microseconds into it
logic [4:0]  rot_sec;
logic [13:0] rot_us;
wire  [2:0]  zone  = track[6:4];
wire  [3:0]  spt_g = 4'd12 - {1'b0, zone};
wire  [4:0]  spt   = d_mfm ? (d_hd ? 5'd18 : 5'd9) : {1'b0, spt_g};
wire         gap   = rot_sec >= spt;
wire  [13:0] slot_end = gap ? 14'(T_INDEX - 1) : (d_mfm & ~d_hd) ? 14'(T_SEC_DD - 1) : 14'(T_SEC_HD - 1);
wire         turning = motor_on & has_disk;
wire         am_ev   = us_tick & turning & ~gap & rot_us == 14'(T_AM) & drive_mfm == d_mfm & (d_ds | ~head);
wire         data_ev = us_tick & turning & ~gap & rot_us == 14'(T_DATA);
wire  [6:0]  sec_id  = {2'b00, rot_sec} + {6'd0, d_mfm};
wire  [4:0]  sec_nx  = (rot_sec + 5'd1 >= spt) ? 5'd0 : rot_sec + 5'd1;
wire  [7:0]  fmt_b   = d_mfm ? 8'h02 : d_ds ? 8'h22 : 8'h02;

// the image's sector under the head: MFM ((track * 2 + head) * spt), GCR the
// zone's first, then the track's within it, then the side's
wire  [7:0]  th     = {track, head};
wire  [11:0] mfm_t  = d_hd ? ({th, 4'd0} + {3'd0, th, 1'b0}) : ({1'b0, th, 3'd0} + {4'd0, th});
logic [10:0] zb;
always_comb begin
	case (zone)
		3'd0:    zb = 11'd0;
		3'd1:    zb = 11'd384;
		3'd2:    zb = 11'd736;
		3'd3:    zb = 11'd1056;
		default: zb = 11'd1344;
	endcase
end
wire  [10:0] zbase  = d_ds ? zb : {1'b0, zb[10:1]};
wire  [7:0]  tps    = {4'd0, track[3:0]} * {4'd0, spt_g};
wire  [8:0]  tps2   = d_ds ? {tps, 1'b0} : {1'b0, tps};
wire  [11:0] gcr_a  = {1'b0, zbase} + {3'd0, tps2};
wire  [11:0] gcr_t  = gcr_a + (head ? {8'd0, spt_g} : 12'd0);
wire  [11:0] trk_b  = d_mfm ? mfm_t : gcr_t;
wire  [11:0] lba    = trk_b + {7'd0, rot_sec};

// ---- a disk access
typedef enum logic [2:0] { A_IDLE, A_SEARCH, A_FETCH, A_PUSH, A_GCR } a_t;
a_t         acc;
logic [7:0] cur_trk, cur_sec, fmt_r, target;
logic [4:0] dsec;                       // the slot of the sector being read
logic       blk_ok, dat_ok, q_ok;
logic       pend;                       // a block asked for and not yet read
logic [8:0] idx;                        // its byte going out (GCR: being read)
logic [2:0] dn_s;
logic       dn_h;

// A GCR sector goes out as the chip gives it: its number, then 175 groups of three bytes
// (12 tag bytes, zeros here, then the 512; the last group two) as 6-bit values with
// three running checksums, then the checksums: 704 bytes (SonySWIM3.a's DeNibbleize)
typedef enum logic [2:0] { G_SEC, G_LD, G_ENC, G_NIB, G_CK } g_t;
g_t         gs;
logic [9:0] src;                        // the group's byte being read, of the 524
logic [1:0] gk, gw;
logic [7:0] grp, g_a, g_b, g_c, ck_a, ck_b, ck_c, e_a, e_b, e_c;
logic       g_ok;
wire        g_last = grp == 8'd174;
wire  [7:0] ck_cr  = {ck_c[6:0], ck_c[7]};
wire  [8:0] sum_a  = {1'b0, ck_a} + {1'b0, g_a} + {8'd0, ck_c[7]};
wire  [8:0] sum_b  = {1'b0, ck_b} + {1'b0, g_b} + {8'd0, sum_a[8]};
wire  [8:0] sum_c  = {1'b0, ck_cr} + {1'b0, g_c} + {8'd0, sum_b[8]};
wire        g_out  = gs == G_SEC || gs == G_NIB || gs == G_CK;
logic [7:0] g_q;
always_comb begin
	case (gs)
		G_SEC:   g_q = {3'd0, dsec};
		G_NIB:   case (gk)
			2'd0:    g_q = {2'b00, e_a[7:6], e_b[7:6], e_c[7:6]};
			2'd1:    g_q = {2'b00, e_a[5:0]};
			2'd2:    g_q = {2'b00, e_b[5:0]};
			default: g_q = {2'b00, e_c[5:0]};
		endcase
		default: case (gk)
			2'd0:    g_q = {2'b00, ck_a[7:6], ck_b[7:6], ck_c[7:6]};
			2'd1:    g_q = {2'b00, ck_a[5:0]};
			2'd2:    g_q = {2'b00, ck_b[5:0]};
			default: g_q = {2'b00, ck_c[5:0]};
		endcase
	endcase
end

assign b_ra     = (d_dc42 ? 10'd84 : 10'd0) + {1'b0, idx};
assign di_valid = ((acc == A_PUSH) & q_ok) | ((acc == A_GCR) & g_out & g_ok);
assign di_data  = (acc == A_GCR) ? g_q : b_q;
assign di_flush = (acc != A_PUSH) & (acc != A_GCR);

task automatic sector_done;
	xfer_cnt <= xfer_cnt - 8'd1;
	if (xfer_cnt == 8'd1) begin
		int_flags <= int_flags | I_SECT;
		acc <= A_IDLE;
	end
	else begin
		target <= {1'b0, 2'b00, sec_nx} + {7'd0, d_mfm};
		acc    <= A_SEARCH;
	end
endtask

always_comb begin
	case (rn)
		4'h1:    rq = timer_val;
		4'h4:    rq = {4'h0, phase};
		4'h5:    rq = setup_r;
		4'h6:    rq = mode_r;
		4'h7:    rq = mode_r[1] ? {4'h0, stat, stat, 2'b00} : 8'h0C;
		4'h8:    rq = int_flags;
		4'h9:    rq = step_count;
		4'hA:    rq = cur_trk;
		4'hB:    rq = cur_sec;
		4'hC:    rq = fmt_r;
		4'hD:    rq = first_sec;
		4'hE:    rq = xfer_cnt;
		4'hF:    rq = int_mask;
		default: rq = 8'h00;            // 0 data, 2 error, 3 parameter data
	endcase
end

assign irq = mode_r[0] & |(int_flags & int_mask);

always_ff @(posedge clk) begin
	m_s  <= {m_s[1:0], m_t};
	dn_s <= {dn_s[1:0], dn_t};

	if (us_tick) begin
		if (timer_val != 8'd0) begin
			timer_val <= timer_val - 8'd1;
			if (timer_val == 8'd1) int_flags <= int_flags | I_TIMER;
		end
		if (stepping) begin
			if (step_wait != 7'd0) step_wait <= step_wait - 7'd1;
			else begin
				track      <= stepped;
				step_count <= step_count - 8'd1;
				step_wait  <= 7'd79;
				if (step_count == 8'd1) begin
					stepping  <= 1'b0;
					int_flags <= int_flags | I_STEP;
				end
			end
		end
		if (turning) begin
			if (rot_us == slot_end) begin
				rot_us  <= 14'd0;
				rot_sec <= gap ? 5'd0 : rot_sec + 5'd1;
			end
			else rot_us <= rot_us + 14'd1;
		end
	end

	// ---- the access: an address field, the sector's block, its data, out by DMA
	if (dn_s[2] != dn_h) begin
		dn_h   <= dn_s[2];
		pend   <= 1'b0;
		blk_ok <= 1'b1;
	end
	case (acc)
		A_SEARCH: if (am_ev) begin
			cur_trk   <= {head, track};
			cur_sec   <= {1'b1, sec_id};
			fmt_r     <= fmt_b;
			int_flags <= int_flags | I_ID;
			if ({1'b0, sec_id} == target && !pend) begin
				rq_lba <= lba;
				rq_t   <= ~rq_t;
				pend   <= 1'b1;
				dsec   <= rot_sec;
				blk_ok <= 1'b0;
				dat_ok <= 1'b0;
				acc    <= A_FETCH;
			end
		end
		A_FETCH: begin
			if (data_ev && rot_sec == dsec) dat_ok <= 1'b1;
			if (blk_ok && dat_ok) begin
				idx  <= 9'd0;
				q_ok <= 1'b0;
				g_ok <= 1'b0;
				gs   <= G_SEC;
				{ck_a, ck_b, ck_c} <= 24'd0;
				grp  <= 8'd0;
				src  <= 10'd0;
				gk   <= 2'd0;
				gw   <= 2'd0;
				acc  <= d_mfm ? A_PUSH : A_GCR;
			end
		end
		A_PUSH: begin
			if (di_take) begin
				q_ok <= 1'b0;
				idx  <= idx + 9'd1;
				if (idx == 9'd511) sector_done();
			end
			else q_ok <= 1'b1;
		end
		A_GCR: case (gs)
			G_LD: if (gw != 2'd2) gw <= gw + 2'd1;
			else begin
				gw <= 2'd0;
				case (gk)
					2'd0:    g_a <= src < 10'd12 ? 8'd0 : b_q;
					2'd1:    g_b <= src < 10'd12 ? 8'd0 : b_q;
					default: g_c <= src < 10'd12 ? 8'd0 : b_q;
				endcase
				src <= src + 10'd1;
				idx <= 9'(src + 10'd1 - 10'd12);
				if (gk == 2'd2 || src == 10'd523) begin
					gk <= 2'd0;
					gs <= G_ENC;
				end
				else gk <= gk + 2'd1;
			end
			G_ENC: begin
				e_a  <= g_a ^ ck_cr;
				e_b  <= g_b ^ sum_a[7:0];
				e_c  <= g_last ? 8'd0 : g_c ^ sum_b[7:0];
				ck_a <= sum_a[7:0];
				ck_b <= sum_b[7:0];
				ck_c <= g_last ? ck_cr : sum_c[7:0];
				gs   <= G_NIB;
			end
			default: if (di_take) begin
				g_ok <= 1'b0;
				if (gs == G_SEC) gs <= G_LD;
				else if (gs == G_NIB) begin
					if (gk == (g_last ? 2'd2 : 2'd3)) begin
						gk  <= 2'd0;
						grp <= grp + 8'd1;
						gs  <= g_last ? G_CK : G_LD;
					end
					else gk <= gk + 2'd1;
				end
				else if (gk == 2'd3) sector_done();
				else gk <= gk + 2'd1;
			end
			else g_ok <= 1'b1;
		endcase
		default: ;
	endcase

	if (sel & ~we & rn == 4'h8) int_flags <= 8'h0;
	// a status read of head 0 or 1 selects that head (superdrive.cpp status)
	if (sel & ~we & rn == 4'h7 & mode_r[1]) begin
		if (stat_addr == 4'h4) head <= 1'b0;
		if (stat_addr == 4'hC) head <= 1'b1;
	end

	if (sel & we) begin
		case (rn)
			4'h1: timer_val <= wdata;
			4'h3: pram <= wdata;
			4'h4: begin
				phase <= wdata[3:0];
				if (wdata[3] & mode_r[1]) begin
					case (cmd_addr)
						4'h0: step_back <= wdata[2];
						4'h1: if (~wdata[2]) track <= stepped;
						4'h2: if (motor_on != ~wdata[2]) begin
							motor_on <= ~wdata[2];
							if (~wdata[2]) begin
								ready   <= has_disk;
								rot_sec <= 5'd31;          // from the index gap
								rot_us  <= 14'd0;
							end
						end
						4'h3: if (wdata[2]) begin
							has_disk    <= 1'b0;
							eject_latch <= 1'b1;
							motor_on    <= 1'b0;
							track       <= 7'd0;
							ready       <= 1'b0;
							drive_mfm   <= 1'b1;
						end
						4'h4: if (wdata[2]) eject_latch <= 1'b0;
						4'h5: if (drive_mfm != ~wdata[2]) begin
							drive_mfm <= ~wdata[2];
							ready     <= 1'b1;
						end
						default: ;
					endcase
				end
				else if (wdata[3:0] == 4'h4 & mode_r[1]) head <= mode_r[5];   // swim3.cpp's rd_line read
			end
			4'h5: setup_r <= wdata;
			4'h6: begin
				mode_r <= mode_r & ~wdata;
				if (wdata[7]) begin stepping <= 1'b0; step_count <= 8'd0; end
				if (wdata[3] & mode_r[3]) acc <= A_IDLE;
			end
			4'h7: begin
				mode_r <= mode_r | wdata;
				// the steps start when GO_STEP is set with the step command on
				// the phase lines: the first step at once (swim3.cpp start_stepping)
				if (wdata[7] & ~mode_r[7] & ~stepping & (step_count != 8'd0) & ({1'b0, mode_r[5], phase[1:0]} == 4'h1)) begin
					track      <= stepped;
					step_count <= step_count - 8'd1;
					if (step_count == 8'd1) int_flags <= int_flags | I_STEP;
					else begin stepping <= 1'b1; step_wait <= 7'd79; end
				end
				// GO: a disk access for "first sector", not while stepping or writing
				else if (wdata[3] & ~mode_r[3] & ~wdata[7] & ~(mode_r[4] | wdata[4]) & ~stepping) begin
					target <= first_sec;
					acc    <= A_SEARCH;
				end
			end
			4'h9: step_count <= wdata;
			4'hD: first_sec <= wdata;
			4'hE: xfer_cnt <= wdata;
			4'hF: int_mask <= wdata;
			default: ;
		endcase
	end

	// a disk put in (the drive's mode becomes the disk's, as dingusppc's
	// insert_disk sets it), or the image taken out
	if (m_s[2] != m_h) begin
		m_h <= m_s[2];
		has_disk <= m_ok;
		if (m_ok) begin
			d_fmt     <= m_fmt;
			d_dc42    <= m_dc42;
			drive_mfm <= m_fmt[1];
		end
	end

	if (reset) begin
		setup_r     <= 8'h0;
		mode_r      <= 8'h0;
		int_flags   <= 8'h0;
		int_mask    <= 8'h0;
		step_count  <= 8'h0;
		xfer_cnt    <= 8'h0;
		first_sec   <= 8'hFF;
		pram        <= 8'h0;
		timer_val   <= 8'h0;
		phase       <= 4'h0;
		motor_on    <= 1'b0;
		eject_latch <= 1'b0;
		ready       <= 1'b0;
		step_back   <= 1'b0;
		head        <= 1'b0;
		track       <= 7'd0;
		stepping    <= 1'b0;
		step_wait   <= 7'd0;
		acc         <= A_IDLE;
		cur_trk     <= 8'hFF;
		cur_sec     <= 8'h7F;
		fmt_r       <= 8'h00;
		target      <= 8'hFF;
	end
end

// the disk stays in the drive across a reset
initial begin
	has_disk  = 1'b0;
	d_fmt     = 2'd3;
	d_dc42    = 1'b0;
	drive_mfm = 1'b1;
	m_s       = 3'd0;
	m_h       = 1'b0;
	dn_s      = 3'd0;
	dn_h      = 1'b0;
	pend      = 1'b0;
	blk_ok    = 1'b0;
	rq_t      = 1'b0;
	rq_lba    = 12'd0;
	rot_sec   = 5'd31;
	rot_us    = 14'd0;
end

endmodule

//============================================================================
//
//  PPCMac - the machine around the CPU
//  The internal SCSI bus's hard disks: two targets (IDs 0 and 1) on the
//  MiSTer's disk images (hps_io's block devices, slots 0 and 1)
//
//  A SCSI-2 direct-access target at the bus's signal level, behind MESH
//  (PPCMac_mesh): selection, then MESSAGE OUT while ATN is up (an extended
//  message is answered with MESSAGE REJECT), COMMAND (6, 10, 12 or 16 bytes
//  by the opcode's group), the data, STATUS, MESSAGE IN (COMMAND COMPLETE),
//  bus free. Every byte is a REQ/ACK handshake: the target sets the phase
//  (MSG C/D I/O) a clock before REQ; in the in-phases it puts the byte on
//  the data lines, in the out-phases it takes it when ACK comes; then it
//  lets REQ go and waits for ACK to go. RST lets go of everything. A new
//  phase's first REQ comes PHASE_US microseconds after the phase lines
//  change, as a disk takes time to change phase: the 7300's SCSI Manager
//  (its native SIM, FFEB8D98) waits after the status byte until REQ is down
//  before it asks MESH for the message, and a target that asks at once is
//  never seen to stop asking.
//
//  The commands, as dingusppc's scsihd.cpp, scsiblockcmds.cpp and
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
//  The blocks (512 bytes): the target asks the memory clock's side for one
//  block at a time (a toggle, the slot, the LBA and which half of the
//  two-block buffer), and that side asks hps_io (sd_rd or sd_wr until
//  sd_ack, done when sd_ack falls). Two buffers, each of two blocks, each
//  written in one clock and read in the other: the read buffer (hps_io
//  writes, the target reads) and the write buffer (the other way). A read
//  asks for its next block as soon as it starts sending one; a write sends
//  each block to the card as soon as it has it, while the next comes over
//  the bus.
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

	// hps_io's block devices, slots 0 and 1, in the memory clock
	input  logic        clk_h,
	input  logic [1:0]  img_mounted,
	input  logic [63:0] img_size,
	input  logic        img_readonly,
	output logic [31:0] sd_lba,
	output logic [1:0]  sd_rd,
	output logic [1:0]  sd_wr,
	input  logic [1:0]  sd_ack,
	input  logic [13:0] sd_buff_addr,
	input  logic [7:0]  sd_buff_dout,
	output logic [7:0]  sd_buff_din,
	input  logic        sd_buff_wr,

	output logic        busy            // a block is moving to or from the card (the disk light)
);

// =========================================================================================
//  The memory clock's side
// =========================================================================================

// ---- the images: kept across the machine's resets -----------------------------------------
logic [1:0]  h_valid = 2'b00, h_ro = 2'b00;
logic [31:0] h_blocks [2];
logic        h_mtog = 1'b0;
always_ff @(posedge clk_h) begin
	for (int i = 0; i < 2; i++)
		if (img_mounted[i]) begin
			h_valid[i]  <= img_size != 64'd0;
			h_ro[i]     <= img_readonly;
			h_blocks[i] <= (img_size[63:41] != 23'd0) ? 32'hFFFF_FFFF : img_size[40:9];
		end
	if (img_mounted != 2'b00) h_mtog <= ~h_mtog;
end

// ---- the block transfers --------------------------------------------------------------------
logic        c_btog;                    // the CPU's side: a request (a toggle)
logic        c_bwe, c_bslot, c_bhalf;
logic [31:0] c_blba;
logic [2:0]  h_btog_s;
logic        h_bseen = 1'b0, h_bdone = 1'b0, h_acked;
logic        h_half, h_slot;
always_ff @(posedge clk_h) begin
	h_btog_s <= {h_btog_s[1:0], c_btog};
	if (h_btog_s[2] != h_bseen && sd_rd == 2'b00 && sd_wr == 2'b00 && !h_acked) begin
		// the request's fields have stood still since the toggle
		h_bseen <= h_btog_s[2];
		h_slot  <= c_bslot;
		h_half  <= c_bhalf;
		sd_lba  <= c_blba;
		sd_rd   <= c_bwe ? 2'b00 : (c_bslot ? 2'b10 : 2'b01);
		sd_wr   <= c_bwe ? (c_bslot ? 2'b10 : 2'b01) : 2'b00;
	end
	if (((sd_rd | sd_wr) & sd_ack) != 2'b00) begin   // taken: the request down
		sd_rd   <= 2'b00;
		sd_wr   <= 2'b00;
		h_acked <= 1'b1;
	end
	if (h_acked && sd_ack == 2'b00) begin   // done
		h_acked <= 1'b0;
		h_bdone <= h_bseen;
	end
end

// ---- the buffers: two blocks each --------------------------------------------------------------
logic [7:0] rbuf [1024];                // the card's blocks for the target
logic [7:0] wbuf [1024];                // the target's blocks for the card
wire        h_mine = sd_ack[h_slot];
always_ff @(posedge clk_h) begin
	if (sd_buff_wr & h_mine) rbuf[{h_half, sd_buff_addr[8:0]}] <= sd_buff_dout;
	sd_buff_din <= wbuf[{h_half, sd_buff_addr[8:0]}];
end

// =========================================================================================
//  The CPU's clock's side
// =========================================================================================

// ---- the images, handed over ------------------------------------------------------------------
logic [2:0]  c_mtog_s;
logic        c_mseen = 1'b0;
logic [1:0]  m_valid = 2'b00, m_ro = 2'b00;
logic [31:0] m_blocks [2];
always_ff @(posedge clk) begin
	c_mtog_s <= {c_mtog_s[1:0], h_mtog};
	if (c_mtog_s[2] != c_mseen) begin
		c_mseen     <= c_mtog_s[2];
		m_valid     <= h_valid;
		m_ro        <= h_ro;
		m_blocks[0] <= h_blocks[0];
		m_blocks[1] <= h_blocks[1];
	end
end

// ---- the block requests' completion -------------------------------------------------------------
logic [2:0] c_bdone_s;
always_ff @(posedge clk) c_bdone_s <= {c_bdone_s[1:0], h_bdone};
wire blk_idle = c_bdone_s[2] == c_btog;  // no block in flight
assign busy = ~blk_idle;

// ---- the buffers, the CPU's ports -----------------------------------------------------------------
logic [9:0] rb_a;
logic [7:0] rb_q;
logic       wb_we;
logic [9:0] wb_a;
logic [7:0] wb_d;
always_ff @(posedge clk) begin
	rb_q <= rbuf[rb_a];
	if (wb_we) wbuf[wb_a] <= wb_d;
end

// ---- the target -----------------------------------------------------------------------------------
typedef enum logic [4:0] {
	T_IDLE, T_SELECTED, T_PHASE, T_REQ, T_ACK, T_UNACK,
	T_MSGOUT_DONE, T_CMD_DONE, T_EXEC, T_RD_START, T_RD_WAIT, T_RD_BYTE, T_RD_NEXT,
	T_WR_BYTE, T_WR_BLOCK, T_WR_FLUSH, T_DATA_IN, T_DATA_OUT, T_STATUS, T_MSGIN, T_FREE
} t_t;
t_t ts, t_after;                        // the state; where a byte's handshake returns to

logic        cur;                       // the target selected (0 or 1)
logic [2:0]  ph;                        // the phase being driven: MSG C/D I/O
logic [7:0]  ob;                        // the byte going out (in-phases)
logic [7:0]  ib;                        // the byte that came in (out-phases)
logic [7:0]  cdb [16];
logic [4:0]  cdb_n, cdb_len;            // bytes of the command so far, and its length
logic        ext_msg, reject;           // an extended message came: answer MESSAGE REJECT
logic [3:0]  sense_key [2];
logic [7:0]  sense_asc [2];
logic [7:0]  status;
logic [31:0] lba;                       // the next block
logic [31:0] blocks_left;               // blocks still to move
logic [8:0]  bidx;                      // the byte within the block
logic        half;                      // the buffer half in use
logic        pf_ok;                     // the other half already holds the next block (a read)
logic        pf_on;                     // ... it is being fetched
logic [1:0]  wr_out;                    // write: blocks handed to the card and not yet done (0-2)
logic [9:0]  rlen;                      // a response's length
logic [9:0]  ridx;                      // ... its next byte
logic [3:0]  rkind;                     // which response
logic [15:0] dout_len;                  // data out to take and drop (MODE SELECT and the like)
localparam int unsigned PD_CLKS = CLK_HZ / 1_000_000 * PHASE_US;
logic [2:0]  ph_q;                      // the phase of the last REQ
logic [15:0] pd_cnt;                    // clocks before a new phase's first REQ

assign t_bsy = (ts != T_IDLE);
assign {t_msg, t_cd, t_io} = (ts == T_IDLE || ts == T_SELECTED) ? 3'b000 : ph;
assign t_req = (ts == T_REQ);
assign t_db  = (ts == T_REQ || ts == T_ACK) && ph[0] ? ob : 8'h00;

// the opcode's command length (SCSI-2's groups)
function automatic logic [4:0] grp_len(input logic [7:0] op);
	case (op[7:5])
		3'd0:       grp_len = 5'd6;
		3'd1, 3'd2: grp_len = 5'd10;
		3'd4:       grp_len = 5'd16;
		3'd5:       grp_len = 5'd12;
		default:    grp_len = 5'd6;
	endcase
endfunction

// ---- the fixed responses ------------------------------------------------------------------------------
localparam logic [3:0] R_INQ = 4'd0, R_SENSE = 4'd1, R_CAP = 4'd2, R_MODE = 4'd3, R_BUF = 4'd4;
localparam logic [8*36-1:0] INQ = {8'h00, 8'h00, 8'h02, 8'h02, 8'd31, 8'h00, 8'h00, 8'h00,
                                   "QUANTUM ", "MiSTer PPCMac HD", "1.0 "};
localparam logic [8*22-1:0] APPLE = {"APPLE COMPUTER, INC", 24'h202020};

wire [31:0] last_lba = m_blocks[cur] - 32'd1;
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
			3'd6: resp_byte = 8'h02;
			default: ;
		endcase
		R_MODE:  resp_byte = mode_byte(i);
		R_BUF:   if (i == 10'd1) resp_byte = 8'h01;      // READ BUFFER: a 64 KB buffer, as scsihd.cpp
		default: ;
	endcase
endfunction

// the command's fields
wire [7:0]  op      = cdb[0];
wire [31:0] lba6    = {11'd0, cdb[1][4:0], cdb[2], cdb[3]};
wire [31:0] lba10   = {cdb[2], cdb[3], cdb[4], cdb[5]};
wire [31:0] cnt6    = (cdb[4] == 8'd0) ? 32'd256 : {24'd0, cdb[4]};
wire [31:0] cnt10   = {16'd0, cdb[7], cdb[8]};
wire [15:0] alloc6  = {8'd0, cdb[4]};
wire [15:0] alloc10 = {cdb[7], cdb[8]};

function automatic logic [9:0] clamp(input logic [9:0] n, input logic [15:0] alloc);
	clamp = (alloc < {6'd0, n}) ? alloc[9:0] : n;
endfunction

// a block move starting: is it inside the image?
function automatic logic in_range(input logic [31:0] first, input logic [31:0] n, input logic [31:0] size);
	in_range = (first < size) && (n <= size - first);
endfunction

always_ff @(posedge clk) begin
	wb_we <= 1'b0;

	case (ts)
		T_IDLE: begin
			// selected: SEL up, BSY down, our bit on the data lines, the image there
			if (b_sel && !b_bsy && !b_rst && ((b_db[0] && m_valid[0]) || (b_db[1] && m_valid[1]))) begin
				cur <= ~(b_db[0] && m_valid[0]);
				ts  <= T_SELECTED;
			end
		end
		T_SELECTED: if (!b_sel) begin       // BSY is up (t_bsy); the initiator let SEL go
			ext_msg <= 1'b0;
			reject  <= 1'b0;
			cdb_n   <= 5'd0;
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

		// ---- MESSAGE OUT: bytes while ATN is up -----------------------------------------
		T_MSGOUT_DONE: begin
			if (cdb_n == 5'd0 && ib == 8'h01) ext_msg <= 1'b1;   // an extended message's first byte
			cdb_n <= (cdb_n == 5'd0 && ib[7]) ? 5'd0 : cdb_n + 5'd1;   // IDENTIFY ends a message
			if (b_atn) ts <= T_PHASE;                            // more
			else if (ext_msg || (cdb_n == 5'd0 && ib == 8'h01)) begin
				ob <= 8'h07;                                     // MESSAGE REJECT
				ph <= 3'b111;
				reject  <= 1'b1;
				t_after <= T_MSGIN;
				ts <= T_PHASE;
			end
			else begin
				cdb_n   <= 5'd0;
				ph      <= 3'b010;
				t_after <= T_CMD_DONE;
				ts <= T_PHASE;
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
			ridx <= 10'd0;
			ts   <= T_STATUS;                   // unless a data phase comes first
			case (op)
				8'h00, 8'h01, 8'h0B, 8'h16, 8'h17, 8'h1B, 8'h1E, 8'h2B, 8'h2F, 8'h35: ;   // GOOD
				8'h04: if (cdb[1][4]) begin dout_len <= 16'd4; ts <= T_DATA_OUT; end
				8'h1D: if ({cdb[3], cdb[4]} != 16'd0) begin dout_len <= {cdb[3], cdb[4]}; ts <= T_DATA_OUT; end
				8'h15: if (cdb[4] != 8'd0) begin dout_len <= alloc6; ts <= T_DATA_OUT; end
				8'h3B: if ({cdb[6], cdb[7], cdb[8]} != 24'd0) begin
					dout_len <= (cdb[6] != 8'd0) ? 16'hFFFF : {cdb[7], cdb[8]};
					ts <= T_DATA_OUT;
				end
				8'h03: begin rkind <= R_SENSE; rlen <= clamp(10'd18, alloc6); ts <= T_DATA_IN; end
				8'h12: begin rkind <= R_INQ;   rlen <= clamp(10'd36, alloc6); ts <= T_DATA_IN; end
				8'h1A: begin rkind <= R_MODE;  rlen <= clamp(mode_len, alloc6); ts <= T_DATA_IN; end
				8'h25: begin rkind <= R_CAP;   rlen <= 10'd8; ts <= T_DATA_IN; end
				8'h3C: begin rkind <= R_BUF;   rlen <= clamp(10'd4, {cdb[7], cdb[8]}); ts <= T_DATA_IN; end
				8'h08, 8'h28: begin
					lba         <= (op == 8'h08) ? lba6 : lba10;
					blocks_left <= (op == 8'h08) ? cnt6 : cnt10;
					if (!in_range((op == 8'h08) ? lba6 : lba10, (op == 8'h08) ? cnt6 : cnt10, m_blocks[cur])) begin
						status <= 8'h02;
						sense_key[cur] <= 4'h5;
						sense_asc[cur] <= 8'h21;
					end
					else if (((op == 8'h08) ? cnt6 : cnt10) != 32'd0) ts <= T_RD_START;
				end
				8'h0A, 8'h2A: begin
					lba         <= (op == 8'h0A) ? lba6 : lba10;
					blocks_left <= (op == 8'h0A) ? cnt6 : cnt10;
					if (m_ro[cur]) begin
						status <= 8'h02;
						sense_key[cur] <= 4'h7;
						sense_asc[cur] <= 8'h27;
					end
					else if (!in_range((op == 8'h0A) ? lba6 : lba10, (op == 8'h0A) ? cnt6 : cnt10, m_blocks[cur])) begin
						status <= 8'h02;
						sense_key[cur] <= 4'h5;
						sense_asc[cur] <= 8'h21;
					end
					else if (((op == 8'h0A) ? cnt6 : cnt10) != 32'd0) begin
						half   <= 1'b0;
						bidx   <= 9'd0;
						wr_out <= 2'd0;
						ph     <= 3'b000;
						t_after <= T_WR_BYTE;
						ts <= T_PHASE;
					end
				end
				default: begin
					status <= 8'h02;
					sense_key[cur] <= 4'h5;
					sense_asc[cur] <= 8'h20;
				end
			endcase
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
		// ---- data taken and dropped, DATA OUT -----------------------------------------------
		T_DATA_OUT: begin
			if (dout_len == 16'd0) ts <= T_STATUS;
			else begin
				dout_len <= dout_len - 16'd1;
				ph <= 3'b000;
				t_after <= T_DATA_OUT;
				ts <= T_PHASE;
			end
		end

		// ---- READ: blocks from the card, two halves --------------------------------------------
		T_RD_START: if (blk_idle) begin     // the first block into half 0
			c_bwe   <= 1'b0;
			c_bslot <= cur;
			c_bhalf <= 1'b0;
			c_blba  <= lba;
			c_btog  <= ~c_btog;
			half    <= 1'b0;
			pf_on   <= 1'b0;
			pf_ok   <= 1'b0;
			ts      <= T_RD_WAIT;
		end
		T_RD_WAIT: if (blk_idle) begin      // the block is in: send it, fetch the next
			lba         <= lba + 32'd1;
			blocks_left <= blocks_left - 32'd1;
			bidx        <= 9'd0;
			rb_a        <= {half, 9'd0};
			if (blocks_left != 32'd1) begin
				c_bhalf <= ~half;
				c_blba  <= lba + 32'd1;
				c_btog  <= ~c_btog;
				pf_on   <= 1'b1;
			end
			ts <= T_RD_NEXT;
		end
		T_RD_NEXT: ts <= T_RD_BYTE;         // the buffer's read takes a clock
		T_RD_BYTE: begin
			ob   <= rb_q;
			ph   <= 3'b001;
			bidx <= bidx + 9'd1;
			rb_a <= {half, bidx + 9'd1};
			t_after <= (bidx == 9'd511) ? T_RD_WAIT : T_RD_NEXT;
			if (bidx == 9'd511) begin
				half <= ~half;
				if (blocks_left == 32'd0) t_after <= T_STATUS;
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
		T_WR_BLOCK: if (blk_idle) begin     // the block to the card (the other half's is done)
			c_bwe   <= 1'b1;
			c_bslot <= cur;
			c_bhalf <= half;
			c_blba  <= lba;
			c_btog  <= ~c_btog;
			lba         <= lba + 32'd1;
			blocks_left <= blocks_left - 32'd1;
			half <= ~half;
			bidx <= 9'd0;
			if (blocks_left == 32'd1) ts <= T_WR_FLUSH;
			else ts <= T_PHASE;             // the next block's bytes while this one is written
		end
		T_WR_FLUSH: if (blk_idle) ts <= T_STATUS;

		// ---- STATUS, MESSAGE IN, bus free -----------------------------------------------------------
		T_STATUS: begin
			ob <= status;
			ph <= 3'b011;
			reject  <= 1'b0;
			t_after <= T_MSGIN;
			ts <= T_PHASE;
		end
		T_MSGIN: begin
			if (reject) begin               // the MESSAGE REJECT went: on to COMMAND
				reject  <= 1'b0;
				ext_msg <= 1'b0;
				cdb_n   <= 5'd0;
				ph      <= 3'b010;
				t_after <= T_CMD_DONE;
				ts <= T_PHASE;
			end
			else begin
				ob <= 8'h00;                // COMMAND COMPLETE
				ph <= 3'b111;
				t_after <= T_FREE;
				ts <= T_PHASE;
			end
		end
		T_FREE: begin                       // ACK is down (T_UNACK): BSY let go
			ph_q <= 3'b100;                 // (a reserved phase: the next connection's first REQ waits)
			ts   <= T_IDLE;
		end

		default: ts <= T_IDLE;
	endcase

	// the bus reset: everything let go
	if (b_rst) begin
		ts   <= T_IDLE;
		ph_q <= 3'b100;
	end

	if (reset) begin
		ts      <= T_IDLE;
		ph_q    <= 3'b100;
		pd_cnt  <= 16'd0;
		t_after <= T_IDLE;
		ph      <= 3'b000;
		ob      <= 8'h00;
		cur     <= 1'b0;
		half    <= 1'b0;
		pf_on   <= 1'b0;
		pf_ok   <= 1'b0;
		reject  <= 1'b0;
		ext_msg <= 1'b0;
		wb_we   <= 1'b0;
		for (int i = 0; i < 2; i++) begin
			sense_key[i] <= 4'h0;
			sense_asc[i] <= 8'h00;
		end
	end
end

// the block requests' toggle and fields are not reset: a block in flight
// across the machine's reset finishes on the memory clock's side, and the
// toggles stay in step
initial begin
	c_btog  = 1'b0;
	c_bwe   = 1'b0;
	c_bslot = 1'b0;
	c_bhalf = 1'b0;
	c_blba  = 32'd0;
end

endmodule

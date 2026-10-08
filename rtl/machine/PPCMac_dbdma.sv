//============================================================================
//
//  PPCMac - the machine around the CPU
//  A DBDMA channel: Apple's descriptor-based DMA, as Grand Central has it
//
//  One channel of the engine dingusppc's devices/common/dbdma.cpp models,
//  after Apple's DBDMA specification (the register numbers, bits and the
//  command format below are the spec's, the behaviour dbdma.cpp's unless
//  said otherwise). Grand Central has one per device; this is a module per
//  channel, so the sound channels (milestone A) are the same module.
//
//  Registers (little-endian values; Grand Central swaps the CPU's words),
//  by offset / 4:
//    0  ChannelControl  write only: bits 31-16 a mask, 15-0 the value, for
//                       the status bits below (reads 0)
//    1  ChannelStatus   RUN 15, PAUSE 14, FLUSH 13, WAKE 12, DEAD 11,
//                       ACTIVE 10, BT 8, s7-s0 (software's) in 7-0
//    2  CommandPtrHi    reads 0, writes ignored
//    3  CommandPtrLo    the next command; written only while not ACTIVE
//    4  InterruptSelect mask in 23-16, value in 7-0, compared with s7-s0
//    5  BranchSelect    the same
//    6  WaitSelect      the same
//
//  A command (16 bytes in memory, little-endian): reqCount (16 bits),
//  cmd.bits (byte 2: w in 1-0, b in 3-2, i in 5-4), cmd.key (byte 3: the
//  key in 2-0, the command in 7-4), address, cmdDep, resCount, xferStatus.
//  The commands:
//    0, 1  OUTPUT_MORE, OUTPUT_LAST   reqCount bytes from memory at address
//                                     to the device
//    2, 3  INPUT_MORE, INPUT_LAST     reqCount bytes from the device to
//                                     memory
//    4     STORE_QUAD                 cmdDep (1, 2 or 4 bytes: reqCount's low
//                                     bits) to memory at address
//    5     LOAD_QUAD                  1, 2 or 4 bytes at address into cmdDep
//    6     NOP
//    7     STOP                       the channel stops (ACTIVE clears; the
//                                     pointer stays on the STOP, so WAKE
//                                     fetches it again)
//  Then, for all but STOP: the wait condition holds the channel while it is
//  true (w: 0 never, 1 if the select test is true, 2 if false, 3 always);
//  BT clears and the branch condition (b, BranchSelect) takes the pointer to
//  cmdDep and sets BT; resCount and xferStatus (the status with ACTIVE) are
//  written back into the command (xferStatus alone for NOP); the pointer
//  moves on 16 bytes unless the branch went; the interrupt condition (i,
//  InterruptSelect) raises the channel's interrupt (irq, one clock: Grand
//  Central keeps it as a level until software clears it). Then the next
//  command.
//
//  Control writes: s7-s0 as masked; FLUSH (with an INPUT running) writes the
//  bytes held and the command's resCount and xferStatus; RUN set (not ACTIVE)
//  starts the channel at CommandPtrLo, clearing PAUSE if the mask has it;
//  RUN clear stops it (with the stopped command's interrupt condition, as
//  dbdma.cpp) and clears RUN, ACTIVE and DEAD; PAUSE holds the channel where
//  it is (ACTIVE clear) until PAUSE is cleared; WAKE restarts a channel that
//  is not ACTIVE at CommandPtrLo. An unknown command, or a key other than 0
//  for the data commands, makes the channel DEAD.
//
//  The memory port (dm_*) is the CPU's port's protocol: a line or a word
//  with byte enables, the request held until acknowledged (a stop waits for
//  the access in flight); PPCMac_machine takes it through the CPU's snoop
//  port to memory (rule 2). A command is read as the line that holds it.
//  Data out is read a line at a time; data in is gathered into a line and
//  written as a line when all 32 bytes are there, else as the words that
//  have bytes (with byte enables), when the line is done, the command's
//  count is used up, the device says no more bytes are coming (di_flush), or
//  FLUSH asks.
//
//  The device side moves a byte a clock: di_valid / di_data / di_take from
//  the device to memory, do_ready / do_data / do_put the other way (do_last
//  marks an OUTPUT_LAST's last byte: Grand Central's end of frame for
//  MACE); xfer_in
//  and xfer_out say a data command is running and can move a byte now;
//  drained says no input byte is held here; active is ChannelStatus's
//  ACTIVE (a device that streams, as AWACS, runs while it is set).
//
//  Left out (docs/PPCMac_stubs.md): STORE_QUAD and LOAD_QUAD to device
//  registers (only memory is reached), the keys other than 0 (KEY_STREAM0),
//  and the device's own status bits in s7-s0 but one: with S6_EOF, s6 reads
//  1 while an INPUT_LAST that the device ended finishes. An INPUT_LAST ends
//  before its count when the device marks a byte as a frame's last (di_last:
//  MACE's receive, 2026-10-08), resCount telling what was left.
//
//============================================================================

module PPCMac_dbdma
#(
	// s6 reads 1 while an INPUT_LAST the device ended is finishing (Grand Central's
	// Ethernet receive channel: Mac OS's interrupt select and NetBSD's if_mc test it)
	parameter bit S6_EOF = 1'b0
)
(
	input  logic         clk,
	input  logic         reset,

	// the registers: an access for one clock, the value little-endian
	input  logic         sel,
	input  logic         we,
	input  logic [2:0]   rn,              // offset / 4
	input  logic [31:0]  wle,
	output logic [31:0]  rle,             // what a read of rn returns now

	// memory
	output logic         dm_req,
	output logic         dm_we,
	output logic         dm_line,
	output logic [31:2]  dm_addr,
	output logic [3:0]   dm_be,
	output logic [255:0] dm_wdata,
	input  logic         dm_ack,
	input  logic [255:0] dm_rdata,

	// the device
	input  logic         di_valid,        // a byte for memory
	input  logic [7:0]   di_data,
	output logic         di_take,         // ... taken in this clock
	input  logic         di_flush,        // no more bytes are coming for now
	input  logic         di_last,         // the byte taken ends a frame: an INPUT_LAST ends with it
	input  logic         do_ready,        // the device takes a byte
	output logic [7:0]   do_data,
	output logic         do_put,          // ... put in this clock
	output logic         do_last,         // ... and it is an OUTPUT_LAST's last byte (a frame's end)
	output logic         xfer_in,
	output logic         xfer_out,
	output logic         drained,
	output logic         active,          // ChannelStatus's ACTIVE

	output logic         irq,             // the interrupt condition met: one clock

	// for PPCMac_trace, one clock: fin_dec 0 a command finished, and what it was; 1 fetched,
	// fin_info then {pointer, command word, address, cmdDep}; 2 RUN cleared, and the state
	output logic         fin,
	output logic [1:0]   fin_dec,
	output logic [127:0] fin_info
);

// status bits
localparam int RUN = 15, PAUSE = 14, FLUSH = 13, WAKE = 12, DEAD = 11, ACTIVE = 10, BT = 8;

logic [15:0] stat;
logic [31:0] cmd_ptr, int_sel, br_sel, wait_sel;
logic        in_end;                    // the device ended the INPUT_LAST's frame
assign active = stat[ACTIVE];
wire  [15:0] st_d = stat | ((S6_EOF && in_end) ? 16'h0040 : 16'h0000);   // with the device's bits

always_comb begin
	case (rn)
		3'd1:    rle = {16'h0, st_d};
		3'd3:    rle = cmd_ptr;
		3'd4:    rle = int_sel;
		3'd5:    rle = br_sel;
		3'd6:    rle = wait_sel;
		default: rle = 32'h0;
	endcase
end

// the command in hand
logic [15:0] req_count, res_count;
logic [7:0]  cmd_bits;
logic [3:0]  cmd;
logic [2:0]  key;
logic [31:0] addr, cmd_arg;

// a select register's test of s7-s0, and a command's condition bits
function automatic logic sel_true(input logic [31:0] sr, input logic [15:0] st);
	sel_true = ((st[7:0] ^ sr[7:0]) & sr[23:16]) == 8'h00;
endfunction
function automatic logic cond(input logic [1:0] b, input logic [31:0] sr, input logic [15:0] st);
	case (b)
		2'd0:    cond = 1'b0;
		2'd1:    cond = sel_true(sr, st);
		2'd2:    cond = ~sel_true(sr, st);
		default: cond = 1'b1;
	endcase
endfunction

// a 32-byte line: byte k in bits 255-8k
logic [255:0] lb;
logic [31:0]  lv;                       // which of its bytes are held (data in), bit 31 byte 0
logic         lb_ok;                    // it holds the line at addr (data out)
logic [26:0]  lline;                    // the line the bytes held belong to (data in)

typedef enum logic [3:0] {
	S_IDLE, S_FETCH, S_DECODE, S_IN, S_INW, S_OUT, S_OUTR, S_QUAD, S_QREAD, S_WAIT, S_WB, S_FINISH
} st_t;
st_t s;

logic stop_req;                         // RUN cleared: stop once no access is in flight
logic irq_pend;                         // ... with the stopped command's interrupt condition
logic flush_req;                        // FLUSH asked with an INPUT running
logic flushing;                         // the write-back in hand is a flush's
logic pausing;                          // PAUSE: hold where we are

wire  is_in  = (cmd == 4'd2) || (cmd == 4'd3);
wire  go     = stat[ACTIVE] & ~pausing & ~stop_req;       // may start something new
assign xfer_in  = (s == S_IN) & go & (res_count != 16'd0);
assign xfer_out = (s == S_OUT) & go & lb_ok & (res_count != 16'd0);
assign drained  = (lv == 32'h0);

assign di_take = xfer_in & di_valid;
assign do_put  = xfer_out & do_ready;
assign do_last = do_put & (cmd == 4'd1) & (res_count == 16'd1);
assign do_data = lb[8 * (31 - addr[4:0]) +: 8];

// the quad commands' size: 4 if bit 2, else 2 if bit 1, else 1
wire [2:0] q_size = req_count[2] ? 3'd4 : req_count[1] ? 3'd2 : 3'd1;
wire [3:0] q_be   = (q_size == 3'd4) ? 4'b1111 :
                    (q_size == 3'd2) ? (addr[1] ? 4'b0011 : 4'b1100) :
                    (4'b1000 >> addr[1:0]);
// cmdDep as stored little-endian at address, in its lanes
wire [31:0] q_wd  = (q_size == 3'd4) ? {cmd_arg[7:0], cmd_arg[15:8], cmd_arg[23:16], cmd_arg[31:24]} :
                    (q_size == 3'd2) ? {2{cmd_arg[7:0], cmd_arg[15:8]}} : {4{cmd_arg[7:0]}};

// the first word of the line held that still has bytes to write
logic [2:0] wfirst;
logic       wany;
always_comb begin
	wfirst = 3'd0;
	wany   = 1'b0;
	for (int j = 7; j >= 0; j--)
		if (lv[31 - 4 * j -: 4] != 4'h0) begin wfirst = 3'(j); wany = 1'b1; end
end

// xferStatus as written back: the status with ACTIVE
wire [15:0] xstat = st_d | 16'h0400;

// the control register's write
wire [15:0] c_mask = wle[31:16];
wire [15:0] c_data = wle[15:0];
wire        c_wr   = sel & we & (rn == 3'd0);

always_ff @(posedge clk) begin
	irq <= 1'b0;
	fin <= 1'b0;
	if (dm_ack) dm_req <= 1'b0;

	// ---- the registers ------------------------------------------------------------------
	if (sel & we) begin
		case (rn)
			3'd3: if (!stat[ACTIVE]) cmd_ptr <= wle;
			3'd4: int_sel  <= wle & 32'h00FF_00FF;
			3'd5: br_sel   <= wle & 32'h00FF_00FF;
			3'd6: wait_sel <= wle & 32'h00FF_00FF;
			default: ;
		endcase
	end
	if (c_wr) begin
		stat[7:0] <= (stat[7:0] & ~c_mask[7:0]) | (c_data[7:0] & c_mask[7:0]);
		if (c_mask[FLUSH] & c_data[FLUSH] & stat[ACTIVE] & is_in & (s == S_IN || s == S_INW))
			flush_req <= 1'b1;
		if (c_mask[RUN]) begin
			if (c_data[RUN]) begin
				if (c_mask[PAUSE]) begin stat[PAUSE] <= 1'b0; pausing <= 1'b0; end
				if (!stat[ACTIVE] && s == S_IDLE) begin
					stat[ACTIVE] <= 1'b1;
					stat[RUN]    <= 1'b1;
					s <= S_FETCH;
				end
			end
			else begin
				if (s != S_IDLE) begin
					stop_req <= 1'b1;
					irq_pend <= stat[ACTIVE] && cmd < 4'd7 && cond(cmd_bits[5:4], int_sel, st_d);
				end
				fin      <= 1'b1;               // the trace: where it was stopped
				fin_dec  <= 2'd2;
				fin_info <= {cmd_ptr, cmd, 1'b0, key, cmd_bits, req_count, res_count, st_d,
				             4'(s), 25'd0, cond(cmd_bits[1:0], wait_sel, st_d), cond(cmd_bits[3:2], br_sel, st_d),
				             cond(cmd_bits[5:4], int_sel, st_d)};
				stat[RUN]    <= 1'b0;
				stat[ACTIVE] <= 1'b0;
				stat[DEAD]   <= 1'b0;
			end
		end
		else if (c_mask[PAUSE]) begin
			if (c_data[PAUSE]) begin
				stat[PAUSE]  <= 1'b1;
				stat[ACTIVE] <= 1'b0;
				pausing      <= 1'b1;
			end
			else begin
				stat[PAUSE] <= 1'b0;
				if (pausing) begin
					pausing      <= 1'b0;
					stat[ACTIVE] <= 1'b1;
				end
			end
		end
		else if (c_mask[WAKE] & c_data[WAKE] & ~stat[ACTIVE] & (s == S_IDLE)) begin
			stat[ACTIVE] <= 1'b1;
			s <= S_FETCH;
		end
	end

	// ---- the engine: each state's memory access is issued once and waited for ------------
	case (s)
		S_IDLE: ;

		S_FETCH: begin                      // the line holding the command
			if (!dm_req && go) begin
				dm_req  <= 1'b1;
				dm_we   <= 1'b0;
				dm_line <= 1'b1;
				dm_addr <= {cmd_ptr[31:5], 3'd0};
			end
			if (dm_req & dm_ack) begin
				logic [127:0] c;
				c = cmd_ptr[4] ? dm_rdata[127:0] : dm_rdata[255:128];
				req_count  <= {c[119:112], c[127:120]};
				cmd_bits   <= c[111:104];
				cmd        <= c[103:100];
				key        <= c[98:96];
				addr       <= {c[71:64], c[79:72], c[87:80], c[95:88]};
				cmd_arg    <= {c[39:32], c[47:40], c[55:48], c[63:56]};
				stat[WAKE] <= 1'b0;
				s <= S_DECODE;
			end
		end

		S_DECODE: begin
			fin       <= 1'b1;
			fin_dec   <= 2'd1;
			fin_info  <= {cmd_ptr, cmd, 1'b0, key, cmd_bits, req_count, addr, cmd_arg};
			res_count <= req_count;
			lv        <= 32'h0;
			lb_ok     <= 1'b0;
			in_end    <= 1'b0;
			case (cmd)
				4'd0, 4'd1, 4'd2, 4'd3: begin
					if (key != 3'd0) begin
						stat[DEAD]   <= 1'b1;
						stat[ACTIVE] <= 1'b0;
						s <= S_IDLE;
					end
					else if (req_count == 16'd0) s <= S_WAIT;
					else s <= is_in ? S_IN : S_OUT;
				end
				4'd4: s <= S_QUAD;
				4'd5: s <= S_QREAD;
				4'd6: s <= S_WAIT;
				4'd7: begin                     // STOP: no write-back, the pointer stays
					stat[ACTIVE] <= 1'b0;
					s <= S_IDLE;
				end
				default: begin
					stat[DEAD]   <= 1'b1;
					stat[ACTIVE] <= 1'b0;
					s <= S_IDLE;
				end
			endcase
		end

		// ---- data in: bytes gathered into lb, written out by S_INW ---------------------------
		S_IN: begin
			if (di_take) begin
				lb[8 * (31 - addr[4:0]) +: 8] <= di_data;
				lv[31 - addr[4:0]] <= 1'b1;
				lline     <= addr[31:5];
				addr      <= addr + 32'd1;
				res_count <= res_count - 16'd1;
				if (di_last && cmd == 4'd3) in_end <= 1'b1;
				if (addr[4:0] == 5'd31 || res_count == 16'd1 || (di_last && cmd == 4'd3)) s <= S_INW;
			end
			else if (stop_req || flush_req || (di_flush && lv != 32'h0) || res_count == 16'd0)
				s <= S_INW;
		end
		S_INW: begin                        // the line held written: whole, or word by word
			if (dm_req) begin
				if (dm_ack) begin
					if (dm_line) lv <= 32'h0;
					else lv[31 - 4 * dm_addr[4:2] -: 4] <= 4'h0;
				end
			end
			else if (lv == 32'hFFFF_FFFF) begin
				dm_req   <= 1'b1;
				dm_we    <= 1'b1;
				dm_line  <= 1'b1;
				dm_addr  <= {lline, 3'd0};
				dm_wdata <= lb;
			end
			else if (wany) begin
				dm_req   <= 1'b1;
				dm_we    <= 1'b1;
				dm_line  <= 1'b0;
				dm_addr  <= {lline, wfirst};
				dm_be    <= lv[31 - 4 * wfirst -: 4];
				dm_wdata <= {224'h0, lb[255 - 32 * wfirst -: 32]};
			end
			else if (stop_req) s <= S_IDLE;
			else if (flush_req) begin       // a flush: the counts written, then on
				flush_req <= 1'b0;
				flushing  <= 1'b1;
				s <= S_WB;
			end
			else s <= (res_count == 16'd0 || in_end) ? S_WAIT : S_IN;
		end

		// ---- data out: a line read, then its bytes put ---------------------------------------
		S_OUT: begin
			if (stop_req) s <= S_IDLE;
			else if (res_count == 16'd0) s <= S_WAIT;
			else if (!lb_ok) s <= S_OUTR;
			else if (do_put) begin
				addr      <= addr + 32'd1;
				res_count <= res_count - 16'd1;
				if (addr[4:0] == 5'd31) lb_ok <= 1'b0;
			end
		end
		S_OUTR: begin
			if (!dm_req) begin
				if (stop_req) s <= S_IDLE;
				else if (go) begin
					dm_req  <= 1'b1;
					dm_we   <= 1'b0;
					dm_line <= 1'b1;
					dm_addr <= {addr[31:5], 3'd0};
				end
			end
			else if (dm_ack) begin
				lb    <= dm_rdata;
				lb_ok <= 1'b1;
				s     <= S_OUT;
			end
		end

		// ---- STORE_QUAD, LOAD_QUAD -------------------------------------------------------------
		S_QUAD: begin
			if (!dm_req) begin
				if (stop_req) s <= S_IDLE;
				else if (go) begin
					dm_req   <= 1'b1;
					dm_we    <= 1'b1;
					dm_line  <= 1'b0;
					dm_addr  <= addr[31:2];
					dm_be    <= q_be;
					dm_wdata <= {224'h0, q_wd};
				end
			end
			else if (dm_ack) s <= S_WAIT;
		end
		S_QREAD: begin
			if (!dm_req) begin
				if (stop_req) s <= S_IDLE;
				else if (go) begin
					dm_req  <= 1'b1;
					dm_we   <= 1'b0;
					dm_line <= 1'b0;
					dm_addr <= addr[31:2];
				end
			end
			else if (dm_ack) begin
				logic [31:0] w;
				w = dm_rdata[31:0];
				case (q_size)
					3'd4:    cmd_arg <= {w[7:0], w[15:8], w[23:16], w[31:24]};
					3'd2:    cmd_arg <= addr[1] ? {16'h0, w[7:0], w[15:8]} : {16'h0, w[23:16], w[31:24]};
					default: cmd_arg <= {24'h0, w[31 - 8 * addr[1:0] -: 8]};
				endcase
				s <= S_WAIT;
			end
		end

		// ---- the end of a command --------------------------------------------------------------
		S_WAIT: begin                       // the wait condition holds; then the branch
			if (stop_req) s <= S_IDLE;
			else if (go && !cond(cmd_bits[1:0], wait_sel, st_d)) begin
				stat[BT] <= cond(cmd_bits[3:2], br_sel, st_d);
				s <= S_WB;
			end
		end
		S_WB: begin                         // resCount and xferStatus into the command
			if (!dm_req) begin
				if (stop_req && !flushing) s <= S_IDLE;
				else begin
					dm_req   <= 1'b1;
					dm_we    <= 1'b1;
					dm_line  <= 1'b0;
					dm_addr  <= cmd_ptr[31:2] + 30'd3;
					dm_be    <= (cmd == 4'd6) ? 4'b0011 : 4'b1111;
					// (a flush's write-back has FLUSH in xferStatus, as dbdma.cpp's)
					dm_wdata <= {224'h0, res_count[7:0], res_count[15:8], xstat[7:0],
					             xstat[15:8] | (flushing ? 8'h20 : 8'h00)};
				end
			end
			else if (dm_ack) begin
				if (flushing) begin
					flushing <= 1'b0;
					s <= stop_req ? S_IDLE : S_IN;
				end
				else s <= S_FINISH;
			end
		end
		S_FINISH: begin
			stat[BT] <= 1'b0;
			cmd_ptr  <= stat[BT] ? cmd_arg : cmd_ptr + 32'd16;
			if (cond(cmd_bits[5:4], int_sel, st_d)) irq <= 1'b1;
			fin      <= 1'b1;
			fin_dec  <= 2'd0;
			fin_info <= {cmd_ptr, cmd, 1'b0, key, cmd_bits, req_count, res_count, st_d,
			             int_sel[23:16], int_sel[7:0], 15'd0, cond(cmd_bits[5:4], int_sel, st_d)};
			s <= stop_req ? S_IDLE : S_FETCH;
		end
		default: s <= S_IDLE;
	endcase

	// a fetch or wait abandoned by a stop, once no access is in flight
	if ((s == S_FETCH || s == S_WAIT) && stop_req && !dm_req) s <= S_IDLE;

	// a stop is done once the engine is idle
	if (s == S_IDLE) begin
		if (stop_req && irq_pend) irq <= 1'b1;
		stop_req  <= 1'b0;
		irq_pend  <= 1'b0;
		flush_req <= 1'b0;
		flushing  <= 1'b0;
		lv        <= 32'h0;
	end

	if (reset) begin
		stat      <= 16'h0;
		cmd_ptr   <= 32'h0;
		int_sel   <= 32'h0;
		br_sel    <= 32'h0;
		wait_sel  <= 32'h0;
		s         <= S_IDLE;
		dm_req    <= 1'b0;
		stop_req  <= 1'b0;
		irq_pend  <= 1'b0;
		flush_req <= 1'b0;
		flushing  <= 1'b0;
		pausing   <= 1'b0;
		in_end    <= 1'b0;
		lv        <= 32'h0;
		lb_ok     <= 1'b0;
		cmd       <= 4'd7;
		cmd_bits  <= 8'h0;
		irq       <= 1'b0;
	end
end

endmodule

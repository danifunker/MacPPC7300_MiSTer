//============================================================================
//
//  PPCMac - the machine around the CPU
//  The SWIM3, Grand Central's floppy controller, with an internal
//  Superdrive and no disk in it
//
//  The registers as dingusppc's devices/floppy/swim3.cpp has them (its
//  read and write), the drive's command and status lines as its
//  superdrive.cpp answers them for an empty drive, so that the ROM's probe
//  of the chip (interrupt mask <- 0, mode set 01, mode clear 18, phase <- 5
//  and read back: 5) finds it and the 68k .Sony driver (DRVR 4) installs.
//  Mac OS 7.6.1's System assumes it did: with SonyVars (0134) left at -1
//  by the ROM it takes the long before the Sony variables from the top of
//  the ROM and dereferences it, which was the "bus error" at "Welcome to
//  Mac OS" (2026-10-07; MacsBug: CMPM.W (A2)+,(A0)+ with A2 084BF6D6).
//
//  Registers, by (offset >> 4) & F (grandcentral.cpp maps them so):
//    0 data             reads 0: nothing is ever transferred
//    1 timer            written: counts down a microsecond at a time, the
//                       timer-done flag when it reaches 0; read: what is left
//    2 error            reads 0
//    3 parameter data   stored
//    4 phase            the four phase lines, read back; written with CA3
//                       (bit 3) high it strobes a command to the drive: the
//                       address from HEADSEL and bits 1-0, the value bit 2
//    5 setup            stored, read back
//    6 status / mode 0  read: the mode register; written: ones clear mode bits
//    7 handshake / mode 1  read: the selected drive's status line for the
//                       address from HEADSEL and bits 2-0, in bits 2 and 3
//                       (RDDATA and SENSE, wired together); 0C with no drive
//                       selected; written: ones set mode bits, GO_STEP
//                       starting the steps, GO a disk access
//    8 interrupt flags  read, and cleared by the read
//    9 step count       the steps to make: the first at once, then one every
//                       80 us, step-done at the last
//    A current track    reads FF, B current sector 7F, C format 0 (no
//                       address mark is ever read)
//    D first sector, E sectors to transfer, F interrupt mask   stored
//  The interrupt: INT_ENA (mode bit 0) and a flag that is unmasked
//  (swim3.cpp update_irq), Grand Central's source 13.
//
//  The drive (superdrive.cpp): commands 0 step direction (1 = back),
//  1 step (on 0; the track kept within 0-79), 2 motor (0 = on; ready
//  follows the disk, which is not there), 3 eject (sets the latch, the
//  drive back to its reset state), 4 reset the latch, 5 drive mode (0 = MFM;
//  ready set). Status, in the drive's own inverted sense as dingusppc
//  returns it: 1 step 1, 2 motor off, 3 eject latch, 4 head 0 (0), 5 MFM 1,
//  6 double sided 1, 7 drive exists 0, 8 disk in drive 1 (none), 9 write
//  protect 1 (none), A track zero (0 at track 0), C head 1 (1), D drive
//  mode, E ready, F media kind 0 (high density).
//
//  Left out (docs/PPCMac_stubs.md): a disk (reading, writing, DMA channel
//  1), the second drive.
//
//============================================================================

module PPCMac_swim3
(
	input  logic       clk,
	input  logic       reset,
	input  logic       us_tick,        // one clock a microsecond
	input  logic       sel,            // an access, for one cycle
	input  logic       we,
	input  logic [3:0] rn,             // the register, (offset >> 4) & F
	input  logic [7:0] wdata,
	output logic [7:0] rq,             // what a read of rn returns now (the caller registers it)
	output logic       irq
);

localparam logic [7:0] I_TIMER = 8'h01;
localparam logic [7:0] I_STEP  = 8'h02;

logic [7:0] setup_r, mode_r, int_flags, int_mask, step_count, xfer_cnt, first_sec, pram, timer_val;
logic [3:0] phase;
// the drive
logic       motor_on, eject_latch, drive_mfm, ready, step_back;
logic [6:0] track;
// stepping under way: the microseconds to the next step
logic       stepping;
logic [6:0] step_wait;

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
		4'h8:    stat = 1'b1;           // no disk in it
		4'h9:    stat = 1'b1;           // not write-protected
		4'hA:    stat = track != 7'd0;
		4'hC:    stat = 1'b1;
		4'hD:    stat = drive_mfm;
		4'hE:    stat = ~ready;
		4'hF:    stat = 1'b0;           // high density
		default: stat = 1'b0;
	endcase
end

always_comb begin
	case (rn)
		4'h1:    rq = timer_val;
		4'h4:    rq = {4'h0, phase};
		4'h5:    rq = setup_r;
		4'h6:    rq = mode_r;
		4'h7:    rq = mode_r[1] ? {4'h0, stat, stat, 2'b00} : 8'h0C;
		4'h8:    rq = int_flags;
		4'h9:    rq = step_count;
		4'hA:    rq = 8'hFF;
		4'hB:    rq = 8'h7F;
		4'hD:    rq = first_sec;
		4'hE:    rq = xfer_cnt;
		4'hF:    rq = int_mask;
		default: rq = 8'h00;            // 0 data, 2 error, 3 parameter data, C format
	endcase
end

assign irq = mode_r[0] & |(int_flags & int_mask);

always_ff @(posedge clk) begin
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
	end

	if (sel & ~we & rn == 4'h8) int_flags <= 8'h0;

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
						4'h2: begin
							motor_on <= ~wdata[2];
							if (~wdata[2]) ready <= 1'b0;    // ready follows the disk: none
						end
						4'h3: if (wdata[2]) begin
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
			end
			4'h5: setup_r <= wdata;
			4'h6: begin
				mode_r <= mode_r & ~wdata;
				if (wdata[7]) begin stepping <= 1'b0; step_count <= 8'd0; end
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
				// GO: a disk access, which with no disk never produces anything
			end
			4'h9: step_count <= wdata;
			4'hD: first_sec <= wdata;
			4'hE: xfer_cnt <= wdata;
			4'hF: int_mask <= wdata;
			default: ;
		endcase
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
		drive_mfm   <= 1'b1;
		ready       <= 1'b0;
		step_back   <= 1'b0;
		track       <= 7'd0;
		stepping    <= 1'b0;
		step_wait   <= 7'd0;
	end
end

endmodule

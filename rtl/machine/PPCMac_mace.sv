//============================================================================
//
//  PPCMac - the machine around the CPU
//  MACE, the Ethernet controller (Am79C940) behind Grand Central, with the
//  cable unplugged
//
//  The registers as dingusppc's devices/ethernet/mace.cpp reads and writes
//  them (MACE revision A2, chip ID 0941), the bits as the Am79C940's data
//  sheet and Linux's drivers/net/ethernet/apple/mace.h name them, and the
//  transmitter doing what a MACE does with no cable on its port: every
//  frame goes out onto nothing and ends with loss of carrier. One byte
//  each, 16 bytes apart in Grand Central's 11000 window (offset >> 4):
//     0  RCVFIFO   reads 0: nothing is ever received
//     1  XMTFIFO   writes ignored (the transmit data comes by DMA, below)
//     2  XMTFC     stored
//     3  XMTFS     transmit status: XMTSV (80) | LCAR (02) after a frame;
//                  cleared by a read
//     4  XMTRC     0: no retries (nothing on the wire collides)
//     5  RCVFC     stored, 1 from reset
//     6  RCVFS     0
//     7  FIFOFC    transmit frames held (bits 3-0: 0 or 1)
//     8  IR        the interrupt flags: XMTINT (01) as a frame's status
//                  becomes valid; a read returns them and clears them
//     9  IMR       stored; a 1 masks the flag
//    10  PR        XMTSV (80) while XMTFS is valid, TDTREQ (40) while the
//                  transmitter takes bytes
//    11  BIUCC     stored; SWRST (01) resets the chip's registers and clears
//                  itself at once
//    12  FIFOCC    stored
//    13  MACCC     stored; ENXMT (02) lets a frame go out (until it is set,
//                  a frame waits)
//    14  PLSCC     stored (dingusppc reads it as 0)
//    15  PHYCC     stored; LNKFL (80) reads 1, the link failed (no cable),
//                  unless DLNKTST (40) disables the link test
//    16  CHIPID    41, then 09 at 17
//    18  IAC       PHYADDR (04) or LOGADDR (02) set the byte pointer to 0
//                  for registers 21 (6 bytes) and 20 (8 bytes), each
//                  clearing after its last byte; ADDRCHG (80) clears at once
//                  (no frame is ever being received; dingusppc keeps it set)
//    24  MPC       0
//    29  UTR       stored
//  Others read 0 and ignore writes. The addresses written are not kept.
//
//  Transmit: Grand Central's DMA channel 2 (Ethernet out) puts the frame's
//  bytes (do_put), the last of an OUTPUT_LAST marking its end (do_last).
//  The frame then takes its time on the wire at 10 Mbit/s (16 us of
//  preamble and gap, then 0.8 us a byte, on us_tick) and its status
//  becomes valid with loss of carrier: on an unplugged port no carrier
//  comes back (the Am79C940's data sheet: LCAR for every frame sent in
//  the link fail state). One frame at a time: the next waits until then.
//  Receive: nothing; DMA channel 3 (Ethernet in) waits for ever.
//
//  The interrupt (Grand Central's source 0E) is a flag in IR that IMR does
//  not mask, as the chip's INTR pin.
//
//  Left out (docs/PPCMac_stubs.md): a network (the MiSTer's Main could
//  bridge one, as the Quadra 800 core does for its SONIC), the FIFOs'
//  contents and watermarks, transmit by programmed I/O, the loopback modes,
//  collisions, CERR (the heartbeat).
//
//============================================================================

module PPCMac_mace
(
	input  logic       clk,
	input  logic       reset,
	input  logic       us_tick,         // one clock a microsecond

	// the registers: an access for one clock
	input  logic       sel,
	input  logic       we,
	input  logic [4:0] rn,              // offset >> 4
	input  logic [7:0] wdata,
	output logic [7:0] rq,              // what a read of rn returns now

	// the transmit DMA channel's bytes
	output logic       do_ready,
	input  logic       do_put,
	input  logic       do_last,

	output logic       irq
);

logic [7:0]  xmt_fc, rcv_fc, int_stat, int_mask, biu_cc, fifo_cc, mac_cc, pls_cc, phy_cc, iac, utr, xmt_fs;
logic [2:0]  aptr;
logic [11:0] f_len;                    // bytes of the frame being taken
logic        f_held;                   // a whole frame waits for the wire
logic        f_wire;                   // ... and is on it
logic [11:0] f_us;                     // microseconds left on the wire
wire         swrst = sel & we & (rn == 5'd11) & wdata[0];
// the frame's time on the wire: 16 us, and 13/16 us a byte (0.8, near enough)
wire  [11:0] len_a = f_len - {2'b00, f_len[11:2]};
wire  [11:0] len_b = len_a + {4'h0, f_len[11:4]};
wire  [11:0] f_time = len_b + 12'd16;

assign irq      = |(int_stat & ~int_mask);
assign do_ready = ~f_held;

always_comb begin
	case (rn)
		5'd2:    rq = xmt_fc;
		5'd3:    rq = xmt_fs;
		5'd5:    rq = rcv_fc;
		5'd7:    rq = {7'h0, f_held};
		5'd8:    rq = int_stat;
		5'd9:    rq = int_mask;
		5'd10:   rq = {xmt_fs[7], ~f_held, 6'h0};
		5'd11:   rq = biu_cc;
		5'd12:   rq = fifo_cc;
		5'd13:   rq = mac_cc;
		5'd14:   rq = pls_cc;
		5'd15:   rq = {~phy_cc[6], phy_cc[6:0]};
		5'd16:   rq = 8'h41;
		5'd17:   rq = 8'h09;
		5'd18:   rq = iac;
		5'd29:   rq = utr;
		default: rq = 8'h00;
	endcase
end

always_ff @(posedge clk) begin
	// the transmitter: the frame's bytes, then its time on the wire
	if (do_put) begin
		f_len <= (f_len == 12'hFFF) ? f_len : f_len + 12'd1;
		if (do_last) f_held <= 1'b1;
	end
	if (f_held && !f_wire && mac_cc[1]) begin
		f_wire <= 1'b1;
		f_us   <= f_time;
	end
	if (f_wire && us_tick) begin
		if (f_us == 12'd0) begin
			f_wire      <= 1'b0;
			f_held      <= 1'b0;
			f_len       <= 12'd0;
			xmt_fs      <= 8'h82;                // XMTSV | LCAR
			int_stat[0] <= 1'b1;                 // XMTINT
		end
		else f_us <= f_us - 12'd1;
	end

	// reads that clear
	if (sel & ~we & (rn == 5'd8)) int_stat <= 8'h00;
	if (sel & ~we & (rn == 5'd3)) xmt_fs <= 8'h00;

	if (sel & we) begin
		case (rn)
			5'd2:  xmt_fc   <= wdata;
			5'd5:  rcv_fc   <= wdata;
			5'd9:  int_mask <= wdata;
			5'd11: biu_cc   <= wdata & 8'hFE;
			5'd12: fifo_cc  <= wdata;
			5'd13: mac_cc   <= wdata;
			5'd14: pls_cc   <= wdata;
			5'd15: phy_cc   <= wdata & 8'h7F;
			5'd18: begin
				// LOGADDR wins over PHYADDR; either sets the pointer to 0
				iac  <= {1'b0, wdata[6:3], (wdata[2] & ~wdata[1]), wdata[1:0]};
				if (wdata[2] | wdata[1]) aptr <= 3'd0;
			end
			5'd20: if (iac[1]) begin
				aptr <= aptr + 3'd1;
				if (aptr == 3'd7) iac[1] <= 1'b0;
			end
			5'd21: if (iac[2]) begin
				if (aptr == 3'd5) begin
					aptr    <= 3'd0;
					iac[2]  <= 1'b0;
				end
				else aptr <= aptr + 3'd1;
			end
			5'd29: utr      <= wdata;
			default: ;
		endcase
	end

	if (reset | swrst) begin
		xmt_fc    <= 8'h00;
		rcv_fc    <= 8'h01;
		int_stat  <= 8'h00;
		int_mask  <= 8'h00;
		biu_cc    <= 8'h00;
		fifo_cc   <= 8'h00;
		mac_cc    <= 8'h00;
		pls_cc    <= 8'h00;
		phy_cc    <= 8'h00;
		iac       <= 8'h00;
		utr       <= 8'h00;
		xmt_fs    <= 8'h00;
		aptr      <= 3'd0;
		f_len     <= 12'd0;
		f_held    <= 1'b0;
		f_wire    <= 1'b0;
		f_us      <= 12'd0;
	end
end

endmodule

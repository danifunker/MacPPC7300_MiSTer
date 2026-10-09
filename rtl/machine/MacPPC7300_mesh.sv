//============================================================================
//
//  MacPPC7300 - the machine around the CPU
//  MESH, the internal SCSI controller (Macintosh Enhanced SCSI Hardware,
//  Apple 343S1146 on the TNT boards)
//
//  As dingusppc's devices/common/scsi/mesh.cpp and the bus controller it
//  runs on (scsibusctrl.cpp, scsibus.cpp, scsi.h) have it, where those model
//  the chip, and as Linux's drivers/scsi/mesh.c uses it where they do not
//  (the information phases on a real bus, DMA out). The registers, 16 bytes
//  apart, (offset >> 4) & F:
//
//    0, 1  transfer count, low and high      read and written; counts down as
//                                            the data move
//    2     FIFO                              16 bytes: a write puts a byte in,
//                                            a read takes one out
//    3     sequence: the command              read back; a write runs it
//    4     bus status 0 (REQ ACK ATN MSG C/D I/O in 5-0)  the bus's lines; a
//    5     bus status 1 (RST BSY SEL in 7-5)              write drives MESH's
//    6     FIFO count                        the bytes in the FIFO
//    7     exception: selection timeout 1, phase mismatch 2, arbitration lost 4
//    8     error                             0
//    9     interrupt mask
//    A     interrupt: command done 1, exception 2, error 4; a write clears the
//          bits written
//    B     source ID                         written, reads 0 (MESH is ID 7)
//    C     destination ID
//    D     synchronous parameters            2 after a hard reset
//    E     MESH ID                           E2 (CHIP_ID; Heathrow's cell is 4)
//    F     selection timeout, in 10 ms       written, reads 0
//
//  The interrupt line (Grand Central's source 0D) is any interrupt bit that
//  is unmasked, at all times, as a chip's pin is.
//
//  The bus (o_* what MESH drives, b_* the lines as they are, 1 = asserted):
//  MacPPC7300_machine ORs MESH's lines with the targets' (MacPPC7300_scsidisk).
//
//  The sequencer commands (the low four bits of a sequence write; bit 7 asks
//  for DMA, bit 5 for ATN; every command first clears command done):
//
//    1  arbitrate     the exception register keeps only its arbitration-lost
//                     bit; MESH lets go of every line; once the bus is free,
//                     800 ns of bus-free delay and 400 of settling, then BSY
//                     and MESH's ID bit for 2,400 ns of arbitration, which
//                     MESH, alone as an initiator, wins: SEL up, done
//    2  select        the exception register keeps only its selection-timeout
//                     bit; the data lines carry MESH's ID and the destination
//                     ID, ATN goes up if asked, BSY is let go; once a target
//                     answers with BSY, SEL and the data lines are let go and
//                     the command is done; with no answer after the selection
//                     timeout (the register's value times 10 ms, 0 counting
//                     as 256), every line is let go and the command ends in a
//                     selection-timeout exception
//    3-8  command, status, data out, data in, message out, message in: the
//                     count's bytes moved, each as the target asks with REQ in
//                     the command's phase (data out: from the FIFO onto the
//                     data lines, then ACK; in: into the FIFO, then ACK), ATN
//                     as the command's bit 5 says; a REQ in another phase is a
//                     phase-mismatch exception and ends the command; the
//                     count used up, the command is done (data in with DMA:
//                     once the FIFO and the DMA channel have emptied too). A
//                     data phase's count of 0 is 65,536. After the last byte
//                     of a message in, ACK stays up (so a reject can be
//                     signalled) until the next command lets it go; after a
//                     status byte too, so the target cannot ask for the
//                     message before the driver asks MESH for it (the 7300's
//                     SIM waits for REQ to drop after the status, FFEB8D98,
//                     and would wait for ever on a target that asks at once)
//    9  bus free      lets go of ACK; done once BSY drops, a phase mismatch
//                     if the target asks for more (REQ) first: with ATN up
//                     (the SIM's way to answer a message), MESSAGE OUT.
//                     dingusppc keeps ACK there and moves its target on by
//                     hand; on a bus of signals only ACK going moves it
//                     (Mac OS 8.5's driver, 2026-10-08)
//    C, D             reselection on, off: no command done (dingusppc sets
//                     it; Linux's mesh.c issues C when idle and takes any
//                     interrupt after D as a reselection, 2026-10-08)
//    E  reset MESH    the registers dingusppc's reset(false) resets (not the
//                     bus status, synchronous parameters or destination ID),
//                     the FIFO emptied, any running command stopped; then done
//    F  flush FIFO    the FIFO emptied
//    0, A, B          nothing to do here (parity checking on, off)
//
//  DMA (bit 7, data out and data in): the FIFO's bytes go to DBDMA channel A
//  (di_*) or come from it (do_*), MacPPC7300_dbdma's device side. di_flush tells
//  the channel no more bytes are coming (the count is used up and the FIFO
//  is empty).
//
//  Time comes from tick, a clock at TICK_HZ made from the CPU's clock by
//  phase accumulation (MacPPC7300_machine); a byte's handshake runs in the
//  CPU's clock.
//
//  Left out (docs/MacPPC7300_stubs.md): reselection, target mode, parity, the
//  error register's conditions (an unexpected disconnect, a reset), the
//  synchronous transfers (the parameters are kept, the bytes go
//  asynchronously).
//
//============================================================================

module MacPPC7300_mesh
#(
	parameter logic [7:0]  CHIP_ID = 8'hE2,         // mesh.h TntMeshID
	parameter int unsigned TICK_HZ = 25_000_000     // a whole number of MHz
)
(
	input  logic       clk,
	input  logic       reset,
	input  logic       tick,            // one clock at TICK_HZ
	input  logic       sel,             // an access, for one cycle
	input  logic       we,
	input  logic [3:0] rn,              // register number: (offset >> 4) & F
	input  logic [7:0] wdata,
	output logic [7:0] rq,              // what a read of rn returns now (the caller registers it)
	output logic       irq,             // to Grand Central, source 0D

	// the SCSI bus: what MESH drives, and the lines
	output logic       o_rst, o_bsy, o_sel, o_atn, o_ack, o_req, o_msg, o_cd, o_io,
	output logic [7:0] o_db,            // 0 where MESH does not drive
	input  logic       b_rst, b_bsy, b_sel, b_atn, b_ack, b_req, b_msg, b_cd, b_io,
	input  logic [7:0] b_db,

	// DMA: DBDMA channel A's device side
	output logic       di_valid,
	output logic [7:0] di_data,
	input  logic       di_take,
	output logic       di_flush,
	output logic       do_ready,
	input  logic [7:0] do_data,
	input  logic       do_put,
	input  logic       dma_drained
);

// the delays of scsi.h, in ticks
localparam int unsigned T_MHZ    = TICK_HZ / 1_000_000;
localparam int unsigned D_FREE   = T_MHZ * 800 / 1000;      // BUS_FREE_DELAY (and BUS_CLEAR_DELAY)
localparam int unsigned D_SETTLE = T_MHZ * 1200 / 1000;     // BUS_FREE_DELAY + BUS_SETTLE_DELAY
localparam int unsigned D_ARB    = T_MHZ * 2400 / 1000;     // ARB_DELAY
localparam int unsigned D_10MS   = TICK_HZ / 100;           // the selection timeout's unit

logic [15:0] xfer_count;
logic        xc_hi;                         // the count is 65,536 (a data phase's 0)
logic [7:0]  cur_cmd, int_mask, dst_id, sync_params, sel_to;
logic [2:0]  int_stat, exception;

// the lines MESH drives, and what bus status 0 and 1 were last written,
// which a write compares against (mesh.cpp update_bus_status)
logic [5:0]  ln_lo, bstat_lo;               // REQ ACK ATN MSG C/D I/O
logic [2:0]  ln_hi, bstat_hi;               // RST BSY SEL
logic [7:0]  db_out;
logic        db_oe;
assign {o_req, o_ack, o_atn, o_msg, o_cd, o_io} = ln_lo;
assign {o_rst, o_bsy, o_sel} = ln_hi;
assign o_db = db_oe ? db_out : 8'h00;

// ---- the FIFO -----------------------------------------------------------------------------
logic [7:0] fifo [16];
logic [3:0] f_rp, f_wp;
logic [4:0] f_cnt;
wire  [7:0] f_head = fifo[f_rp];
wire        f_full = f_cnt[4];
wire        f_empty = f_cnt == 5'd0;

// the sequencer
typedef enum logic [3:0] {
	SQ_IDLE, SQ_WAIT, SQ_FREE, SQ_ARB_BEGIN, SQ_ARB_END, SQ_SEL, SQ_SEL_WAIT, SQ_SEL_DONE, SQ_SEL_END,
	SQ_XFER, SQ_OUT_ACK, SQ_ACK_WAIT, SQ_DRAIN, SQ_BUSFREE
} sq_t;
sq_t         sq, sq_nxt;
logic [17:0] dly;                           // ticks left in this wait
logic [7:0]  units;                         // further 10 ms periods (the selection timeout)
logic [2:0]  ph;                            // the command's phase: MSG C/D I/O
logic        dma;                           // the command moves its data by DMA
logic        last_in;                       // the byte being acknowledged is a message in's last
wire         bus_free = ~b_bsy & ~b_sel;
wire  [2:0]  b_ph = {b_msg, b_cd, b_io};
wire  [16:0] xc = {xc_hi, xfer_count};      // bytes still to move

assign irq = |(int_stat & int_mask[2:0]);

// DMA with DBDMA channel A
wire dma_in  = (sq == SQ_XFER || sq == SQ_ACK_WAIT || sq == SQ_DRAIN) & dma & (ph == 3'b001);
wire dma_out = (sq == SQ_XFER || sq == SQ_OUT_ACK || sq == SQ_ACK_WAIT) & dma & (ph == 3'b000);
assign di_valid = dma_in & ~f_empty;
assign di_data  = f_head;
assign di_flush = dma_in & f_empty & (xc == 17'd0);
assign do_ready = dma_out & ~f_full & (17'(f_cnt) < xc);

// what a read returns
always_comb begin
	case (rn)
		4'h0:    rq = xfer_count[7:0];
		4'h1:    rq = xfer_count[15:8];
		4'h2:    rq = f_empty ? 8'h00 : f_head;
		4'h3:    rq = cur_cmd;
		4'h4:    rq = {2'b00, b_req, b_ack, b_atn, b_msg, b_cd, b_io};
		4'h5:    rq = {b_rst, b_bsy, b_sel, 5'b00000};
		4'h6:    rq = {3'b000, f_cnt};
		4'h7:    rq = {5'b00000, exception};
		4'h9:    rq = int_mask;
		4'hA:    rq = {5'b00000, int_stat};
		4'hC:    rq = dst_id;
		4'hD:    rq = sync_params;
		4'hE:    rq = CHIP_ID;
		default: rq = 8'h00;                // error, source ID, selection timeout
	endcase
end

wire       wr  = sel & we;
wire       cmd = wr & (rn == 4'h3);
wire [3:0] op  = wdata[3:0];
wire [5:0] chg_lo = wdata[5:0] ^ bstat_lo;
wire [2:0] chg_hi = wdata[7:5] ^ bstat_hi;

// the interrupt bits: set by the sequencer and by commands, cleared by a
// write of the interrupt register and by every command's start (command done)
logic [2:0] int_set, int_clr;
logic       done_now, mm_now;               // the sequencer ends a command: done; a phase mismatch
always_comb begin
	int_set = 3'b000;
	int_clr = 3'b000;
	if (sq == SQ_ARB_END || sq == SQ_SEL_DONE || done_now) int_set = int_set | 3'b001;
	if (sq == SQ_SEL_END) int_set = int_set | 3'b011;
	if (mm_now) int_set = int_set | 3'b010;
	if (wr & rn == 4'hA) int_clr = int_clr | wdata[2:0];
	if (cmd) begin
		int_clr = int_clr | 3'b001;
		if (op == 4'hE) begin int_clr = 3'b111; int_set = 3'b001; end
	end
end

// the FIFO's movers this clock: the bus side, and the CPU's or DMA's side
logic       bus_push, bus_pop;
wire        cpu_push = wr & (rn == 4'h2);
wire        cpu_pop  = sel & ~we & (rn == 4'h2) & ~f_empty;
wire        host_push = (cpu_push | do_put) & ~bus_push;
wire        host_pop  = (cpu_pop | di_take) & ~bus_pop;
wire [7:0]  host_byte = do_put ? do_data : wdata;

always_comb begin
	done_now = 1'b0;
	mm_now   = 1'b0;
	bus_push = 1'b0;
	bus_pop  = 1'b0;
	case (sq)
		SQ_XFER: begin
			if (xc == 17'd0) done_now = 1'b1;      // (a DMA data in ends through SQ_DRAIN)
			else if (b_req && b_ph != ph) mm_now = 1'b1;
			else if (b_req && ph[0]) bus_push = ~f_full;   // in: the byte into the FIFO, then ACK
		end
		SQ_OUT_ACK: bus_pop = 1'b0;
		SQ_ACK_WAIT: if (!b_req && !ph[0]) bus_pop = 1'b1;  // out: the byte gone
		SQ_DRAIN: if (f_empty && dma_drained) done_now = 1'b1;
		SQ_BUSFREE: begin
			if (!b_bsy) done_now = 1'b1;
			else if (b_req) mm_now = 1'b1;
		end
		default: ;
	endcase
end

always_ff @(posedge clk) begin
	int_stat <= (int_stat & ~int_clr) | int_set;
	if (mm_now) exception[1] <= 1'b1;

	// ---- the FIFO ---------------------------------------------------------------------------
	if (bus_push) begin fifo[f_wp] <= b_db; f_wp <= f_wp + 4'd1; end
	else if (host_push && !f_full) begin fifo[f_wp] <= host_byte; f_wp <= f_wp + 4'd1; end
	if (bus_pop | host_pop) f_rp <= f_rp + 4'd1;
	f_cnt <= f_cnt + {4'd0, bus_push | (host_push & ~f_full)} - {4'd0, bus_pop | host_pop};

	// ---- the sequencer ----------------------------------------------------------------------
	case (sq)
		SQ_WAIT: if (tick) begin
			if (dly > 18'd1) dly <= dly - 18'd1;
			else if (units != 8'd0) begin
				units <= units - 8'd1;
				dly   <= 18'(D_10MS);
			end
			else sq <= sq_nxt;
		end
		SQ_FREE: begin                      // scsibusctrl.cpp BUS_FREE
			sq    <= SQ_WAIT;
			units <= 8'd0;
			if (bus_free) begin
				dly    <= 18'(D_SETTLE);
				sq_nxt <= SQ_ARB_BEGIN;
			end
			else begin
				dly    <= 18'(D_FREE);
				sq_nxt <= SQ_FREE;
			end
		end
		SQ_ARB_BEGIN: begin
			sq    <= SQ_WAIT;
			units <= 8'd0;
			if (bus_free) begin             // BSY and MESH's ID bit
				ln_hi[1] <= 1'b1;
				db_out   <= 8'h80;
				db_oe    <= 1'b1;
				dly    <= 18'(D_ARB);
				sq_nxt <= SQ_ARB_END;
			end
			else begin                      // BUS_CLEAR_DELAY, then from the start
				dly    <= 18'(D_FREE);
				sq_nxt <= SQ_FREE;
			end
		end
		SQ_ARB_END: begin                   // won, alone as an initiator: SEL up, done
			ln_hi[0] <= 1'b1;
			sq <= SQ_IDLE;
		end
		SQ_SEL: if (tick) begin             // a bus settle with the IDs out, then BSY let go
			ln_hi[1] <= 1'b0;
			sq <= SQ_SEL_WAIT;
		end
		SQ_SEL_WAIT: begin                  // a target's BSY, or the timeout
			if (b_bsy) sq <= SQ_SEL_DONE;
			else if (tick) begin
				if (dly > 18'd1) dly <= dly - 18'd1;
				else if (units != 8'd0) begin
					units <= units - 8'd1;
					dly   <= 18'(D_10MS);
				end
				else sq <= SQ_SEL_END;
			end
		end
		SQ_SEL_DONE: begin                  // selected: SEL and the IDs let go
			ln_hi[0] <= 1'b0;
			db_oe    <= 1'b0;
			sq <= SQ_IDLE;
		end
		SQ_SEL_END: begin                   // no target answered: a selection timeout
			ln_lo     <= 6'h00;
			ln_hi     <= 3'b000;
			db_oe     <= 1'b0;
			exception[0] <= 1'b1;
			sq <= SQ_IDLE;
		end

		SQ_XFER: begin
			if (mm_now || done_now) sq <= SQ_IDLE;
			else if (b_req) begin
				if (!ph[0]) begin               // out: a byte from the FIFO onto the lines
					if (!f_empty) begin
						db_out <= f_head;
						db_oe  <= 1'b1;
						sq     <= SQ_OUT_ACK;
					end
				end
				else if (bus_push) begin        // in: taken; ACK
					ln_lo[4] <= 1'b1;
					// (ACK stays up after a message in's last byte, and a status's)
					last_in  <= (ph == 3'b111 || ph == 3'b011) && (xc == 17'd1);
					sq       <= SQ_ACK_WAIT;
				end
			end
		end
		SQ_OUT_ACK: begin                   // the data settled: ACK
			ln_lo[4] <= 1'b1;
			last_in  <= 1'b0;
			sq       <= SQ_ACK_WAIT;
		end
		SQ_ACK_WAIT: if (!b_req) begin      // the target took it: ACK down (but after a message's last byte)
			if (!last_in) ln_lo[4] <= 1'b0;
			db_oe <= 1'b0;
			{xc_hi, xfer_count} <= xc - 17'd1;
			if (xc == 17'd1 && dma && ph == 3'b001) sq <= SQ_DRAIN;
			else sq <= SQ_XFER;
		end
		SQ_DRAIN: if (done_now) sq <= SQ_IDLE;
		SQ_BUSFREE: if (done_now || mm_now) sq <= SQ_IDLE;
		default: ;
	endcase

	// ---- register writes ----------------------------------------------------------------
	if (wr) begin
		case (rn)
			4'h0: xfer_count[7:0]  <= wdata;
			4'h1: xfer_count[15:8] <= wdata;
			4'h4: begin                     // the lines whose bit changed follow it
				ln_lo    <= (ln_lo & ~chg_lo) | (wdata[5:0] & chg_lo);
				bstat_lo <= wdata[5:0];
			end
			4'h5: begin
				ln_hi    <= (ln_hi & ~chg_hi) | (wdata[7:5] & chg_hi);
				bstat_hi <= wdata[7:5];
			end
			4'h9: int_mask    <= wdata;
			4'hC: dst_id      <= wdata;
			4'hD: sync_params <= wdata;
			4'hF: sel_to      <= wdata;
			default: ;
		endcase
	end

	// ---- a command (mesh.cpp perform_command) ------------------------------------------
	if (cmd) begin
		cur_cmd <= wdata;
		dma     <= wdata[7];
		case (op)
			4'h1: begin                     // arbitrate
				exception <= exception & 3'b100;
				ln_lo     <= 6'h00;
				ln_hi     <= 3'b000;
				db_oe     <= 1'b0;
				sq <= SQ_FREE;
			end
			4'h2: begin                     // select
				exception <= exception & 3'b001;
				db_out    <= 8'h80 | (8'h01 << dst_id[2:0]);
				db_oe     <= 1'b1;
				ln_lo[3]  <= wdata[5];
				units     <= sel_to - 8'd1;
				dly       <= 18'(D_10MS);
				sq        <= SQ_SEL;
			end
			4'h3, 4'h4, 4'h5, 4'h6, 4'h7, 4'h8: begin
				case (op)
					4'h3:    ph <= 3'b010;      // command
					4'h4:    ph <= 3'b011;      // status
					4'h5:    ph <= 3'b000;      // data out
					4'h6:    ph <= 3'b001;      // data in
					4'h7:    ph <= 3'b110;      // message out
					default: ph <= 3'b111;      // message in
				endcase
				xc_hi    <= (op == 4'h5 || op == 4'h6) && xfer_count == 16'h0;
				ln_lo[3] <= wdata[5];
				ln_lo[4] <= 1'b0;           // a message in's ACK let go
				db_oe    <= 1'b0;
				sq <= SQ_XFER;
			end
			4'h9: begin                     // bus free
				ln_lo[4] <= 1'b0;
				db_oe <= 1'b0;
				sq <= SQ_BUSFREE;
			end
			4'hE: begin                     // reset MESH
				cur_cmd    <= 8'h00;
				int_mask   <= 8'h00;
				exception  <= 3'b000;
				xfer_count <= 16'h0;
				xc_hi      <= 1'b0;
				f_rp <= 4'd0; f_wp <= 4'd0; f_cnt <= 5'd0;
				sq <= SQ_IDLE;
			end
			4'hF: begin f_rp <= 4'd0; f_wp <= 4'd0; f_cnt <= 5'd0; end
			default: ;
		endcase
	end

	if (reset) begin
		xfer_count  <= 16'h0;
		xc_hi       <= 1'b0;
		cur_cmd     <= 8'h00;
		int_mask    <= 8'h00;
		int_stat    <= 3'b000;
		exception   <= 3'b000;
		dst_id      <= 8'h00;
		sync_params <= 8'h02;               // "fast async operation (guessed)", mesh.cpp
		sel_to      <= 8'h19;               // 250 ms until software sets it
		ln_lo       <= 6'h00;
		ln_hi       <= 3'b000;
		bstat_lo    <= 6'h00;
		bstat_hi    <= 3'b000;
		db_out      <= 8'h00;
		db_oe       <= 1'b0;
		sq          <= SQ_IDLE;
		sq_nxt      <= SQ_IDLE;
		dly         <= 18'd0;
		units       <= 8'd0;
		ph          <= 3'b000;
		dma         <= 1'b0;
		last_in     <= 1'b0;
		f_rp        <= 4'd0;
		f_wp        <= 4'd0;
		f_cnt       <= 5'd0;
		for (int i = 0; i < 16; i++) fifo[i] <= 8'h00;
	end
end

endmodule

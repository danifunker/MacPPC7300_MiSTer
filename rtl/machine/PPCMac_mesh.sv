//============================================================================
//
//  PPCMac - the machine around the CPU
//  MESH, the internal SCSI controller (Macintosh Enhanced SCSI Hardware,
//  Apple 343S1146 on the TNT boards), with an empty bus
//
//  As dingusppc's devices/common/scsi/mesh.cpp and the bus controller it
//  runs on (scsibusctrl.cpp, scsibus.cpp, scsi.h) have it, the registers 16
//  bytes apart, (offset >> 4) & F:
//
//    0, 1  transfer count, low and high      read and written
//    2     FIFO                               left out: reads 0, writes ignored
//    3     sequence: the command              read back; a write runs it
//    4     bus status 0 (REQ ACK ATN MSG C/D I/O in 5-0)  the lines MESH
//    5     bus status 1 (RST BSY SEL in 7-5)              drives; a write
//                                                         drives them
//    6     FIFO count                         0
//    7     exception: selection timeout 1, phase mismatch 2, arbitration lost 4
//    8     error                              0
//    9     interrupt mask
//    A     interrupt: command done 1, exception 2, error 4; a write clears the
//          bits written
//    B     source ID                          written, reads 0 (MESH is ID 7)
//    C     destination ID
//    D     synchronous parameters             2 after a hard reset
//    E     MESH ID                            E2 (CHIP_ID; Heathrow's cell is 4)
//    F     selection timeout, in 10 ms        written, reads 0
//
//  The interrupt line (Grand Central's source 0D) is any interrupt bit that
//  is unmasked, at all times, as a chip's pin is. (dingusppc recomputes its
//  line only at some events; where it does not, after the reselection
//  commands, the line here moves a few instructions earlier.)
//
//  The sequencer commands (the low four bits of a sequence write; each
//  first clears command done):
//
//    1  arbitrate     the exception register keeps only its arbitration-lost
//                     bit, as dingusppc's does; MESH lets go of every line;
//                     once the bus is free, 800 ns of bus-free delay and 400
//                     of settling, then 2,400 ns of arbitration, which MESH,
//                     alone on the bus, wins: it asserts SEL and the command
//                     is done
//    2  select        the exception register keeps only its selection-timeout
//                     bit; after a won arbitration SEL is up, ATN goes up with
//                     it when the command's bit 5 asks; with no target, after
//                     the selection timeout (the register's value times 10 ms,
//                     0 counting as 256: the ROM writes 0x19, 250 ms, which is
//                     dingusppc's fixed SEL_TIME_OUT) every line is let go and
//                     the command ends in a selection-timeout exception
//    9  bus free      lets go of ACK unless ATN is up; done, or a phase
//                     mismatch if BSY is still up
//    C, D             reselection on, off: command done at once
//    E  reset MESH    the registers dingusppc's reset(false) resets (not the
//                     bus status, synchronous parameters or destination ID),
//                     any running command stopped; then command done
//    0, A, B, F       nothing to do here (no operation; parity checking on,
//                     off; flush the FIFO, which is not modelled)
//    3-8              the information phases (command, status, data out and
//                     in, message out and in) need a target: here they only
//                     clear command done (milestone S builds them)
//
//  The bus is free while MESH drives none of RST, BSY and SEL and is not
//  arbitrating. Time comes from tick, a clock at TICK_HZ made from the CPU's
//  clock by phase accumulation (PPCMac_machine).
//
//  Left out until milestone S (docs/PPCMac_stubs.md): the FIFO, the
//  information phases, DMA, reselection, targets, parity.
//
//============================================================================

module PPCMac_mesh
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
	output logic       irq              // to Grand Central, source 0D
);

// the delays of scsi.h, in ticks
localparam int unsigned T_MHZ    = TICK_HZ / 1_000_000;
localparam int unsigned D_FREE   = T_MHZ * 800 / 1000;      // BUS_FREE_DELAY (and BUS_CLEAR_DELAY)
localparam int unsigned D_SETTLE = T_MHZ * 1200 / 1000;     // BUS_FREE_DELAY + BUS_SETTLE_DELAY
localparam int unsigned D_ARB    = T_MHZ * 2400 / 1000;     // ARB_DELAY
localparam int unsigned D_10MS   = TICK_HZ / 100;           // the selection timeout's unit

logic [15:0] xfer_count;
logic [7:0]  cur_cmd, int_mask, dst_id, sync_params, sel_to;
logic [2:0]  int_stat, exception;

// the lines MESH drives (dingusppc's dev_ctrl_lines for MESH's ID): REQ ACK
// ATN MSG C/D I/O, and RST BSY SEL; and what bus status 0 and 1 were last
// written, which a write compares against (mesh.cpp update_bus_status)
logic [5:0]  lines_lo, bstat_lo;
logic [2:0]  lines_hi, bstat_hi;            // RST BSY SEL

// the sequencer
typedef enum logic [2:0] {SQ_IDLE, SQ_WAIT, SQ_FREE, SQ_ARB_BEGIN, SQ_ARB_END, SQ_SEL_END} sq_t;
sq_t         sq, sq_nxt;
logic [17:0] dly;                           // ticks left in this wait
logic [7:0]  units;                         // further 10 ms periods (the selection timeout)
logic        arbitrating;
wire         bus_free = ~|lines_hi & ~arbitrating;

assign irq = |(int_stat & int_mask[2:0]);

// what a read returns
always_comb begin
	case (rn)
		4'h0:    rq = xfer_count[7:0];
		4'h1:    rq = xfer_count[15:8];
		4'h3:    rq = cur_cmd;
		4'h4:    rq = {2'b00, lines_lo};
		4'h5:    rq = {lines_hi, 5'b00000};
		4'h7:    rq = {5'b00000, exception};
		4'h9:    rq = int_mask;
		4'hA:    rq = {5'b00000, int_stat};
		4'hC:    rq = dst_id;
		4'hD:    rq = sync_params;
		4'hE:    rq = CHIP_ID;
		default: rq = 8'h00;                // FIFO, FIFO count, error, source ID, selection timeout
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
always_comb begin
	int_set = 3'b000;
	int_clr = 3'b000;
	if (sq == SQ_ARB_END) int_set = int_set | 3'b001;
	if (sq == SQ_SEL_END) int_set = int_set | 3'b011;
	if (wr & rn == 4'hA) int_clr = int_clr | wdata[2:0];
	if (cmd) begin
		int_clr = int_clr | 3'b001;
		case (op)
			4'h9:       int_set = int_set | (lines_hi[1] ? 3'b010 : 3'b001);
			4'hC, 4'hD: int_set = int_set | 3'b001;
			4'hE:       begin int_clr = 3'b111; int_set = 3'b001; end
			default: ;
		endcase
	end
end

always_ff @(posedge clk) begin
	int_stat <= (int_stat & ~int_clr) | int_set;

	// ---- the sequencer ----------------------------------------------------------------
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
			if (bus_free) begin
				arbitrating <= 1'b1;
				dly    <= 18'(D_ARB);
				sq_nxt <= SQ_ARB_END;
			end
			else begin                      // BUS_CLEAR_DELAY, then from the start
				dly    <= 18'(D_FREE);
				sq_nxt <= SQ_FREE;
			end
		end
		SQ_ARB_END: begin                   // won, alone on the bus: SEL up, done
			arbitrating <= 1'b0;
			lines_hi[0] <= 1'b1;
			sq <= SQ_IDLE;
		end
		SQ_SEL_END: begin                   // no target answered: a selection timeout
			lines_lo     <= 6'h00;
			lines_hi     <= 3'b000;
			exception[0] <= 1'b1;
			sq <= SQ_IDLE;
		end
		default: ;
	endcase

	// ---- register writes ----------------------------------------------------------------
	if (wr) begin
		case (rn)
			4'h0: xfer_count[7:0]  <= wdata;
			4'h1: xfer_count[15:8] <= wdata;
			4'h4: begin                     // the lines whose bit changed follow it
				lines_lo <= (lines_lo & ~chg_lo) | (wdata[5:0] & chg_lo);
				bstat_lo <= wdata[5:0];
			end
			4'h5: begin
				lines_hi <= (lines_hi & ~chg_hi) | (wdata[7:5] & chg_hi);
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
		case (op)
			4'h1: begin                     // arbitrate
				exception   <= exception & 3'b100;
				lines_lo    <= 6'h00;
				lines_hi    <= 3'b000;
				arbitrating <= 1'b0;
				sq <= SQ_FREE;
			end
			4'h2: begin                     // select
				exception <= exception & 3'b001;
				// after a won arbitration SEL is up, and ATN goes up with it
				// if asked (scsibus.cpp begin_selection); without one the
				// lines stay as they are and the selection times out all
				// the same
				if (lines_hi[0] & wdata[5]) lines_lo[3] <= 1'b1;
				sq     <= SQ_WAIT;
				dly    <= 18'(D_10MS);
				units  <= sel_to - 8'd1;
				sq_nxt <= SQ_SEL_END;
			end
			4'h9: begin                     // bus free
				if (!lines_lo[3]) lines_lo[4] <= 1'b0;
				if (lines_hi[1]) exception[1] <= 1'b1;
			end
			4'hE: begin                     // reset MESH
				cur_cmd     <= 8'h00;
				int_mask    <= 8'h00;
				exception   <= 3'b000;
				xfer_count  <= 16'h0;
				arbitrating <= 1'b0;
				sq <= SQ_IDLE;
			end
			default: ;
		endcase
	end

	if (reset) begin
		xfer_count  <= 16'h0;
		cur_cmd     <= 8'h00;
		int_mask    <= 8'h00;
		int_stat    <= 3'b000;
		exception   <= 3'b000;
		dst_id      <= 8'h00;
		sync_params <= 8'h02;               // "fast async operation (guessed)", mesh.cpp
		sel_to      <= 8'h19;               // 250 ms until software sets it
		lines_lo    <= 6'h00;
		lines_hi    <= 3'b000;
		bstat_lo    <= 6'h00;
		bstat_hi    <= 3'b000;
		sq          <= SQ_IDLE;
		sq_nxt      <= SQ_IDLE;
		dly         <= 18'd0;
		units       <= 8'd0;
		arbitrating <= 1'b0;
	end
end

endmodule

//============================================================================
//
//  MacPPC7300 - the machine around the CPU
//  Curio's SCSI controller, the external bus: an Am53CF94 (a 53C94 with
//  AMD's extended features), with an empty bus
//
//  As dingusppc's devices/common/scsi/sc53c94.cpp has it (Curio, the
//  Am79C950, holds a 53CF94-compatible cell), the registers 16 bytes apart,
//  (offset >> 4) & F, reads and writes reaching different registers:
//
//        read                          write
//    0   transfer count, low           start transfer count, low
//    1   transfer count, middle        start transfer count, middle
//    2   FIFO (16 bytes)               FIFO
//    3   command (the oldest queued)   command
//    4   status                        destination ID
//    5   interrupt status (a read      selection timeout
//        clears it, and with it the
//        sequence step and status's
//        error bits)
//    6   sequence step                 synchronous period (ignored)
//    7   FIFO flags: the internal      synchronous offset (ignored)
//        step in 7-5, the FIFO's
//        count in 4-0
//    8   configuration 1               configuration 1
//    9   -                             clock conversion factor
//    B   -                             configuration 2 (bit 6, ENF: the
//                                      extended features)
//    C   configuration 3               configuration 3
//    D   configuration 4               configuration 4
//    E   transfer count, high, with    -
//        ENF (else 0): after a chip
//        reset, the part's ID (CHIP_ID)
//
//  Registers with nothing to read read 0 (dingusppc returns an
//  uninitialised byte).
//
//  Commands go through a two-deep command FIFO, as dingusppc's: a command
//  starts when it reaches the bottom; reset chip, reset bus and DMA stop
//  go to the bottom at once; after a chip reset only no operation and clear
//  FIFO are taken until one of them comes. Bit 7 of a command (DMA) loads
//  the transfer count from the start count. The commands:
//
//    00  no operation               01  clear FIFO
//    02  reset chip                 03  reset the SCSI bus: RST for 25 us,
//                                       a bus-reset interrupt unless
//                                       configuration 1's bit 6 disables it
//    1B  reset ATN                  44  enable selection and reselection
//    41, 42, 43  select without ATN, with ATN, with ATN and stop: 800 ns of
//        bus-free delay and 400 of settling, 2,400 ns of arbitration (won:
//        the chip is alone on the bus), 1,200 ns, then SEL (and ATN); with no
//        target, after the selection timeout a disconnect interrupt, the
//        sequence step 0, the bytes put in the FIFO still there
//    10, 11, 12, 18 (transfer information, initiator command complete,
//        message accepted, transfer pad): initiator commands, which need a
//        connected target: here, as on a 53C94 that is not connected, an
//        invalid-command interrupt (dingusppc stops)
//    anything else: an invalid-command interrupt, as in dingusppc
//
//  The selection timeout is the 53C94's: 8192 times the clock conversion
//  factor (0 meaning 8) times the register's value, in the chip's clocks
//  (MAME's ncr53c90.cpp likewise; dingusppc waits a fixed 250 ms). tick is
//  the chip's clock, made from the CPU's clock by phase accumulation; at
//  25 MHz the ROM's values (factor 5, timeout A7) make 273.6 ms. The chip's
//  real clock on a 7300 is not known yet (docs/MacPPC7300_stubs.md).
//
//  The interrupt line (Grand Central's source 0C) is the interrupt status
//  being non-zero, as is status bit 7. The status register's phase bits are
//  the bus's MSG, C/D and I/O, which no target ever drives here.
//
//  Left out (Curio stays an empty bus; docs/MacPPC7300_stubs.md): targets,
//  the information phases, DMA and the pseudo-DMA port, reselection, the
//  target-mode commands, parity, the phase latch.
//
//============================================================================

module MacPPC7300_sc53c94
#(
	parameter logic [7:0]  CHIP_ID = 8'h0C,         // sc53c94.h's default part ID
	parameter int unsigned TICK_HZ = 25_000_000     // the chip's clock; a whole number of MHz
)
(
	input  logic       clk,
	input  logic       reset,
	input  logic       tick,            // one clock of the chip's clock
	input  logic       sel,             // an access, for one cycle
	input  logic       we,
	input  logic [3:0] rn,              // register number: (offset >> 4) & F
	input  logic [7:0] wdata,
	output logic [7:0] rq,              // what a read of rn returns now (the caller registers it)
	output logic       irq              // to Grand Central, source 0C
);

// the delays of scsi.h, in ticks
localparam int unsigned T_MHZ    = TICK_HZ / 1_000_000;
localparam int unsigned D_FREE   = T_MHZ * 800 / 1000;      // BUS_FREE_DELAY (and BUS_CLEAR_DELAY)
localparam int unsigned D_SETTLE = T_MHZ * 1200 / 1000;     // BUS_FREE_DELAY + BUS_SETTLE_DELAY
localparam int unsigned D_ARB    = T_MHZ * 2400 / 1000;     // ARB_DELAY
localparam int unsigned D_RST    = T_MHZ * 25;              // RST held 25 us

// commands
localparam logic [6:0] C_NOP = 7'h00, C_CLEAR_FIFO = 7'h01, C_RESET_DEVICE = 7'h02,
                       C_RESET_BUS = 7'h03, C_DMA_STOP = 7'h04, C_RESET_ATN = 7'h1B,
                       C_SELECT = 7'h41, C_SELECT_ATN = 7'h42, C_SELECT_ATN_STOP = 7'h43,
                       C_ENA_SEL_RESEL = 7'h44;

logic [23:0] xfer_count;
logic [15:0] set_xfer;
logic [7:0]  cmd0, cmd1;                    // the command FIFO, the bottom first
logic [1:0]  cmd_pos;
logic [7:0]  fifo [16];
logic [4:0]  fifo_pos;
logic [7:0]  int_status, sel_timeout, config1, config2, config3, config4;
logic [2:0]  clk_factor, seq_step, cur_step;
logic [6:0]  cur_cmd;
logic        stat_ge;                       // status bit 6: gross error
logic        on_reset;                      // after a chip reset: only 00 and 01 taken
logic        exec_req, next_req;            // run cmd0; the command at the bottom is finished

wire enf = config2[6];
assign irq = int_status != 8'h00;

// ---- the bus: RST, SEL, ATN as this chip drives them; nothing else is on it --------------
logic [9:0]  rst_cnt;                       // ticks of RST left
logic        my_sel, my_atn, arbitrating;
wire         bus_free = (rst_cnt == 10'd0) & ~my_sel & ~arbitrating;

// ---- the selection sequencer (sc53c94.cpp sequencer) -------------------------------------
typedef enum logic [2:0] {SQ_IDLE, SQ_WAIT, SQ_FREE, SQ_ARB_BEGIN, SQ_ARB_END, SQ_SEL_BEGIN, SQ_SEL_END} sq_t;
sq_t         sq, sq_nxt;
logic [13:0] dly;                           // ticks left in this wait
logic [10:0] units;                         // further periods of 8192 ticks (the selection timeout)
wire  [3:0]  ccf      = clk_factor == 3'd0 ? 4'd8 : {1'b0, clk_factor};
wire  [10:0] to_units = {7'd0, ccf} * {3'd0, sel_timeout};

// ---- what a read returns -----------------------------------------------------------------
always_comb begin
	case (rn)
		4'h0:    rq = xfer_count[7:0];
		4'h1:    rq = xfer_count[15:8];
		4'h2:    rq = fifo_pos == 5'd0 ? 8'h00 : fifo[0];
		4'h3:    rq = cmd0;
		4'h4:    rq = {irq, stat_ge, 6'b000000};   // no target: the phase bits are 0
		4'h5:    rq = int_status;
		4'h6:    rq = {5'b00000, seq_step};
		4'h7:    rq = {cur_step, fifo_pos};
		4'h8:    rq = config1;
		4'hC:    rq = config3;
		4'hD:    rq = config4;
		4'hE:    rq = enf ? xfer_count[23:16] : 8'h00;
		default: rq = 8'h00;
	endcase
end

wire       rd     = sel & ~we;
wire       wr     = sel & we;
wire       cmd_wr = wr & (rn == 4'h3);
wire [6:0] wop    = wdata[6:0];
wire [6:0] op     = cmd0[6:0];
// where a written command goes: the bottom for reset chip, reset bus and DMA stop
wire [1:0] pos0   = (wop == C_RESET_DEVICE || wop == C_RESET_BUS || wop == C_DMA_STOP) ? 2'd0 : cmd_pos;

always_ff @(posedge clk) begin
	if (tick && rst_cnt != 10'd0) rst_cnt <= rst_cnt - 10'd1;

	// ---- reads that change something ------------------------------------------------------
	if (rd & rn == 4'h2) begin
		if (fifo_pos == 5'd0) stat_ge <= 1'b1;          // underflow
		else begin
			for (int i = 0; i < 15; i++) fifo[i] <= fifo[i + 1];
			fifo_pos <= fifo_pos - 5'd1;
		end
	end
	if (rd & rn == 4'h5 & irq) begin
		stat_ge    <= 1'b0;
		int_status <= 8'h00;
		seq_step   <= 3'd0;
	end

	// ---- register writes --------------------------------------------------------------------
	if (wr) begin
		case (rn)
			4'h0: set_xfer[7:0]  <= wdata;
			4'h1: set_xfer[15:8] <= wdata;
			4'h2: begin
				if (fifo_pos == 5'd16) stat_ge <= 1'b1;  // overflow
				else begin
					fifo[fifo_pos[3:0]] <= wdata;
					fifo_pos <= fifo_pos + 5'd1;
				end
			end
			4'h3: begin                     // sc53c94.cpp update_command_reg
				if (!on_reset || wop == C_NOP || wop == C_CLEAR_FIFO) begin
					if (pos0 < 2'd2) begin
						if (pos0 == 2'd0) cmd0 <= wdata; else cmd1 <= wdata;
						cmd_pos <= pos0 + 2'd1;
						if (pos0 == 2'd0) exec_req <= 1'b1;
					end
					else stat_ge <= 1'b1;   // the command FIFO overwritten
				end
			end
			4'h4: ;                         // the destination ID: there is no one to select
			4'h5: sel_timeout <= wdata;
			4'h8: config1     <= wdata;
			4'h9: clk_factor  <= wdata[2:0];
			4'hB: config2     <= wdata;
			4'hC: config3     <= wdata;
			4'hD: config4     <= wdata;
			default: ;
		endcase
	end

	// ---- the command at the bottom of the FIFO (exec_command), in a cycle with no access ----
	if (!sel) begin
		if (exec_req) begin
			exec_req <= 1'b0;
			cur_cmd  <= op;
			if (cmd0[7])                    // DMA: the transfer count from the start count
				xfer_count <= enf ? {8'h00, set_xfer} : (set_xfer == 16'h0 ? 24'h01_0000 : {8'h00, set_xfer});
			case (op)
				C_NOP: begin
					on_reset <= 1'b0;
					next_req <= 1'b1;
				end
				C_CLEAR_FIFO: begin
					on_reset <= 1'b0;
					fifo_pos <= 5'd0;
					fifo[0]  <= 8'h00;
					next_req <= 1'b1;
				end
				C_RESET_DEVICE: begin       // reset_device(), and every running command stopped
					xfer_count  <= {CHIP_ID, 16'h0000};
					clk_factor  <= 3'd2;
					sel_timeout <= 8'h00;
					cmd_pos     <= 2'd0;
					fifo_pos    <= 5'd0;
					fifo[0]     <= 8'h00;
					cur_step    <= 3'd0;
					seq_step    <= 3'd0;
					stat_ge     <= 1'b0;
					int_status  <= 8'h00;
					on_reset    <= 1'b1;
					my_sel      <= 1'b0;
					my_atn      <= 1'b0;
					arbitrating <= 1'b0;
					sq          <= SQ_IDLE;
				end
				C_RESET_BUS: begin
					rst_cnt <= 10'(D_RST);
					if (!config1[6]) int_status <= 8'h80;   // bus reset
					next_req <= 1'b1;
				end
				C_RESET_ATN: begin
					my_atn   <= 1'b0;
					next_req <= 1'b1;
				end
				C_ENA_SEL_RESEL: next_req <= 1'b1;
				C_SELECT, C_SELECT_ATN, C_SELECT_ATN_STOP: begin
					seq_step <= 3'd0;
					cur_step <= 3'd0;
					sq       <= SQ_FREE;
				end
				default: begin              // invalid here: off the FIFO, an interrupt
					cmd_pos    <= cmd_pos - 2'd1;
					int_status <= 8'h40;
				end
			endcase
		end
		else if (next_req) begin            // exec_next_command
			next_req <= 1'b0;
			if (cmd_pos != 2'd0) begin
				cmd_pos <= cmd_pos - 2'd1;
				if (cmd_pos == 2'd2) begin
					cmd0     <= cmd1;
					exec_req <= 1'b1;
				end
			end
		end
	end

	// ---- the sequencer ------------------------------------------------------------------------
	case (sq)
		SQ_WAIT: if (tick) begin
			if (dly > 14'd1) dly <= dly - 14'd1;
			else if (units != 11'd0) begin
				units <= units - 11'd1;
				dly   <= 14'd8192;
			end
			else sq <= sq_nxt;
		end
		SQ_FREE: begin
			sq    <= SQ_WAIT;
			units <= 11'd0;
			if (bus_free) begin
				dly    <= 14'(D_SETTLE);
				sq_nxt <= SQ_ARB_BEGIN;
			end
			else begin
				dly    <= 14'(D_FREE);
				sq_nxt <= SQ_FREE;
			end
		end
		SQ_ARB_BEGIN: begin
			sq    <= SQ_WAIT;
			units <= 11'd0;
			if (bus_free) begin
				arbitrating <= 1'b1;
				dly    <= 14'(D_ARB);
				sq_nxt <= SQ_ARB_END;
			end
			else begin
				dly    <= 14'(D_FREE);
				sq_nxt <= SQ_FREE;
			end
		end
		SQ_ARB_END: begin                   // won: alone on the bus
			sq     <= SQ_WAIT;
			units  <= 11'd0;
			dly    <= 14'(D_SETTLE);        // BUS_CLEAR_DELAY + BUS_SETTLE_DELAY
			sq_nxt <= SQ_SEL_BEGIN;
		end
		SQ_SEL_BEGIN: begin
			arbitrating <= 1'b0;
			my_sel <= 1'b1;
			my_atn <= cur_cmd != C_SELECT;
			sq     <= SQ_WAIT;
			sq_nxt <= SQ_SEL_END;
			if (to_units == 11'd0) begin    // no timeout at all
				dly   <= 14'd1;
				units <= 11'd0;
			end
			else begin
				dly   <= 14'd8192;
				units <= to_units - 11'd1;
			end
		end
		SQ_SEL_END: begin                   // no target answered: disconnected
			my_sel     <= 1'b0;
			my_atn     <= 1'b0;
			seq_step   <= 3'd0;
			int_status <= 8'h20;
			next_req   <= 1'b1;
			sq <= SQ_IDLE;
		end
		default: ;
	endcase

	if (reset) begin
		xfer_count  <= {CHIP_ID, 16'h0000};
		set_xfer    <= 16'h0;
		cmd0        <= 8'h00;
		cmd1        <= 8'h00;
		cmd_pos     <= 2'd0;
		fifo_pos    <= 5'd0;
		for (int i = 0; i < 16; i++) fifo[i] <= 8'h00;
		int_status  <= 8'h00;
		sel_timeout <= 8'h00;
		config1     <= 8'h00;
		config2     <= 8'h00;
		config3     <= 8'h00;
		config4     <= 8'h00;
		clk_factor  <= 3'd2;
		seq_step    <= 3'd0;
		cur_step    <= 3'd0;
		cur_cmd     <= 7'h00;
		stat_ge     <= 1'b0;
		on_reset    <= 1'b0;
		exec_req    <= 1'b0;
		next_req    <= 1'b0;
		rst_cnt     <= 10'd0;
		my_sel      <= 1'b0;
		my_atn      <= 1'b0;
		arbitrating <= 1'b0;
		sq          <= SQ_IDLE;
		sq_nxt      <= SQ_IDLE;
		dly         <= 14'd0;
		units       <= 11'd0;
	end
end

endmodule

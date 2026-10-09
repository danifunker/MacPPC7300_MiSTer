//============================================================================
//
//  MacPPC7300 - the machine around the CPU
//  The SDRAM controller, in the memory clock, on DSPPC604_memcdc's b side
//
//  Adapted from Sorgelig's MiSTer sdram.sv (2015-2019, GPL-3.0-or-later),
//  as used unmodified in MacQuadra800_danifunker rtl/sdram.sv (aff6dfd), where
//  it is hardware-tested at 99 MHz with eight-beat bursts and CAS latency 2,
//  and in Sun-3_MiSTer rtl/sdram.sv. Kept from it: the power-up sequence
//  (100 us of NOPs, then PRECHARGE ALL, two AUTO REFRESH and LOAD MODE for
//  each rank, 8 clocks apart), the mode word (burst of 8 for reads, single
//  writes, sequential, CAS 2), the refresh pairs for the two ranks, ACTIVE
//  to READ/WRITE after two clocks and PRECHARGE to ACTIVE after three, the
//  read capture (the input register samples the first beat three clocks
//  after the READ command) and the data bus driven from a register with an
//  output enable. New here: the request side, for the CPU's memory port, with
//  one row opened and closed per request (no open pages yet); the upload port.
//
//  The module it assumes (a MiSTer SDRAM board of 128 MB): two ranks of
//  64 MB on one bus, each 4 banks x 8192 rows x 1024 columns x 16 bits
//  (AS4C32M16SB class); SDRAM_nCS low selects rank 0 and the board inverts
//  it for rank 1, so every command goes to exactly one rank. A byte offset
//  in the module maps to rank off[26], bank off[25:24], row off[23:11],
//  column off[10:1]. A 64 MB board is rank 0 alone.
//
//  The port (the CPU's memory port protocol): req held until ack, a 32-byte
//  line (word 0, the lowest address, in bits 255-224) or one word with byte
//  enables (be[3] the lowest address, bits 31-24). Byte order on the chip:
//  the byte at the even address is DQ[15:8], so a file written byte by byte
//  reads back as the CPU expects. A line is two READs of eight beats, back
//  to back (sixteen beats without a gap), or sixteen single WRITEs; a word
//  is two halfwords, DQMH and DQML masking the bytes not enabled, so nothing
//  is read to be written back.
//
//  The upload port writes the ROM file into the module before the CPU runs:
//  one byte per strobe, addresses counting up, paired into halfwords; it
//  waits while a CPU request is served (it has the lower priority) and asks
//  for the next byte to be held while a halfword is being written (busy).
//
//============================================================================

module MacPPC7300_sdram
#(
	parameter int CLK_MHZ = 100                // the memory clock
)
(
	input  logic         clk,
	input  logic         init,                 // run the power-up sequence again
	output logic         ready,                // the power-up sequence is done

	// the memory port, by byte offset in the module
	input  logic         req,
	input  logic         we,
	input  logic         line,
	input  logic [26:2]  addr,
	input  logic [3:0]   be,
	input  logic [255:0] wdata,
	output logic         ack,
	output logic [255:0] rdata,

	// the upload, in the same clock
	input  logic         up_wr,                // one strobe per byte
	input  logic [26:0]  up_addr,
	input  logic [7:0]   up_data,
	output logic         up_busy,

	// the chip (the top level makes DQ a tristate bus and SDRAM_CLK)
	output logic [12:0]  SDRAM_A,
	output logic [1:0]   SDRAM_BA,
	output logic         SDRAM_nCS,
	output logic         SDRAM_nRAS,
	output logic         SDRAM_nCAS,
	output logic         SDRAM_nWE,
	output logic         SDRAM_DQML,
	output logic         SDRAM_DQMH,
	output logic         SDRAM_CKE,
	output logic [15:0]  dq_out,
	output logic         dq_oe,
	input  logic [15:0]  dq_in
);

// ---- the chip's commands and timings ----------------------------------------------------
localparam logic [2:0] CMD_NOP       = 3'b111;
localparam logic [2:0] CMD_ACTIVE    = 3'b011;
localparam logic [2:0] CMD_READ      = 3'b101;
localparam logic [2:0] CMD_WRITE     = 3'b100;
localparam logic [2:0] CMD_PRECHARGE = 3'b010;
localparam logic [2:0] CMD_REFRESH   = 3'b001;
localparam logic [2:0] CMD_MODE      = 3'b000;

// burst of 8 (011), sequential, CAS latency 2, single-location writes
localparam logic [12:0] MODE = {3'b000, 1'b1, 2'b00, 3'd2, 1'b0, 3'b011};

localparam int STARTUP  = CLK_MHZ * 121;       // 121 us of NOPs (sdram.sv: 12100 at 100 MHz)
localparam int REFRESH  = CLK_MHZ * 78 / 10;   // 7.8 us: 8192 rows in 64 ms
localparam int T_RCD    = 2;                   // ACTIVE to READ or WRITE
localparam int T_RP     = 3;                   // PRECHARGE to ACTIVE (30 ns at 99 MHz)
localparam int T_RAS    = 5;                   // ACTIVE to PRECHARGE, at least
localparam int T_WR     = 2;                   // last write to PRECHARGE
localparam int T_RFC    = 8;                   // AUTO REFRESH to the next command
localparam int CAP      = 4;                   // READ to the first beat in dq_q, plus one

logic [2:0]  command;
logic        chip;
logic [1:0]  dqm;
assign SDRAM_nCS  = chip;
assign {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE} = command;
assign SDRAM_CKE  = 1'b1;
assign {SDRAM_DQMH, SDRAM_DQML} = dqm;

// the input register: the first beat of a burst arrives here three clocks
// after the READ command
logic [15:0] dq_q;
always_ff @(posedge clk) dq_q <= dq_in;

// ---- what the idle state takes next: a refresh, a request, an upload halfword --------
typedef enum logic [2:0] {
	S_INIT, S_IDLE, S_REF, S_ACT, S_READ, S_WRITE, S_PRE
} state_t;
state_t      state;
logic        ref_due;                  // a refresh is owed
logic        up_pend;                  // an upload halfword is waiting
logic        acked;                    // the request is answered; it may still be up
wire         cpu_req  = req & ~acked & ~ack;
wire         idle     = state == S_IDLE;
wire         ref_take = idle & ref_due;
wire         cpu_take = idle & ~ref_due & cpu_req;
wire         up_take  = idle & ~ref_due & ~cpu_req & up_pend;

// ---- refresh ------------------------------------------------------------------------------
logic [15:0] ref_cnt;
always_ff @(posedge clk) begin
	if (ref_take) ref_due <= 1'b0;
	if (ref_cnt == 16'(REFRESH - 1)) begin
		ref_cnt <= 16'd0;
		ref_due <= 1'b1;
	end
	else ref_cnt <= ref_cnt + 16'd1;
	if (init) begin
		ref_cnt <= 16'd0;
		ref_due <= 1'b0;
	end
end

// ---- the upload's halfwords -----------------------------------------------------------
logic [26:1] up_hw;
logic [15:0] up_d;
logic [7:0]  up_hi;
assign up_busy = up_pend;
always_ff @(posedge clk) begin
	// taken in this clock: the next pair may be stored at once
	if (up_take) up_pend <= 1'b0;
	if (up_wr) begin
		if (~up_addr[0]) up_hi <= up_data;
		else begin
			up_pend <= 1'b1;
			up_hw   <= up_addr[26:1];
			up_d    <= {up_hi, up_data};
		end
	end
	if (init) up_pend <= 1'b0;
end

// ---- the request side -------------------------------------------------------------------
logic [15:0] t;                        // clocks in this state
logic        r_we, r_line, r_up;       // what is being served
logic [26:1] r_hw;                     // its first halfword
logic [3:0]  r_be;
logic [255:0] r_wd;
logic [15:0] r_ud;
logic [4:0]  beat;                     // beats captured
logic [4:0]  issued;                   // WRITEs or READs issued

wire [4:0]  nbeats  = r_line ? 5'd16 : 5'd2;

always_ff @(posedge clk) begin
	command  <= CMD_NOP;
	dq_oe    <= 1'b0;
	ack      <= 1'b0;
	t        <= t + 16'd1;
	if (~req) acked <= 1'b0;

	case (state)
		// the power-up sequence of sdram.sv, each command 8 clocks apart, for
		// rank 0 and then rank 1
		S_INIT: begin
			SDRAM_A  <= 13'h0;
			SDRAM_BA <= 2'b00;
			dqm      <= 2'b11;
			if (t >= 16'(STARTUP)) begin
				case (t - 16'(STARTUP))
					16'd0:  begin chip <= 1'b0; command <= CMD_PRECHARGE; SDRAM_A[10] <= 1'b1; end
					16'd8:  command <= CMD_REFRESH;
					16'd16: command <= CMD_REFRESH;
					16'd24: begin command <= CMD_MODE; SDRAM_A <= MODE; end
					16'd32: begin chip <= 1'b1; command <= CMD_PRECHARGE; SDRAM_A[10] <= 1'b1; end
					16'd40: command <= CMD_REFRESH;
					16'd48: command <= CMD_REFRESH;
					16'd56: begin command <= CMD_MODE; SDRAM_A <= MODE; end
					16'd64: begin state <= S_IDLE; ready <= 1'b1; end
					default: ;
				endcase
			end
		end

		S_IDLE: begin
			t <= 16'd0;
			dqm <= 2'b00;
			if (ref_take) begin
				// both ranks, one after the other
				chip     <= 1'b0;
				command  <= CMD_REFRESH;
				state    <= S_REF;
			end
			else if (cpu_take | up_take) begin
				r_up   <= ~cpu_req;
				r_we   <= cpu_req ? we : 1'b1;
				r_line <= cpu_req & line;
				r_hw   <= cpu_req ? {addr[26:5], line ? 3'b000 : addr[4:2], 1'b0} : up_hw;
				r_be   <= be;
				r_wd   <= wdata;
				r_ud   <= up_d;
				// ACTIVE: rank, bank, row
				chip     <= cpu_req ? addr[26] : up_hw[26];
				SDRAM_BA <= cpu_req ? addr[25:24] : up_hw[25:24];
				SDRAM_A  <= cpu_req ? addr[23:11] : up_hw[23:11];
				command  <= CMD_ACTIVE;
				state    <= S_ACT;
			end
		end

		S_REF: begin
			if (t == 16'd0) begin chip <= 1'b1; command <= CMD_REFRESH; end
			if (t == 16'(T_RFC)) state <= S_IDLE;
		end

		S_ACT: begin
			beat   <= 5'd0;
			issued <= 5'd0;
			if (t == 16'(T_RCD - 2)) state <= r_we ? S_WRITE : S_READ;
		end

		// READ at the first column, and for a line again eight clocks later at
		// the ninth: sixteen beats without a gap. A word takes its two beats
		// and lets the burst run out.
		S_READ: begin
			if (issued == 5'd0 || (r_line && issued == 5'd1 && t == 16'd8)) begin
				command  <= CMD_READ;
				SDRAM_A  <= {2'b00, 1'b0, r_hw[10:5], r_line ? issued[0] : r_hw[4], r_hw[3:1]};
				issued   <= issued + 5'd1;
				if (issued == 5'd0) t <= 16'd1;
			end
			if (t >= 16'(CAP) && beat < nbeats) begin
				// a line's halfword k at bits 255-16k down; a word in bits 31-0
				if (r_line) rdata[255 - 16 * beat -: 16] <= dq_q;
				else        rdata[31 - 16 * beat[0] -: 16] <= dq_q;
				beat <= beat + 5'd1;
				if (beat == nbeats - 5'd1) begin
					ack   <= 1'b1;
					acked <= 1'b1;
				end
			end
			// precharge once the burst has left the bus (8 or 16 beats)
			if (t == 16'(CAP) + (r_line ? 16'd16 : 16'd8)) begin
				command     <= CMD_PRECHARGE;
				SDRAM_A[10] <= 1'b0;
				t           <= 16'd0;
				state       <= S_PRE;
			end
		end

		// single WRITEs on consecutive clocks: sixteen for a line, two for a
		// word, one for an upload halfword
		S_WRITE: begin
			if (r_up ? issued == 5'd0 : issued < nbeats) begin
				command <= CMD_WRITE;
				dq_oe   <= 1'b1;
				SDRAM_A <= {2'b00, 1'b0, r_hw[10:1] + {6'h0, issued[3:0]}};
				if (r_up) begin
					dq_out <= r_ud;
					dqm    <= 2'b00;
				end
				else if (r_line) begin
					dq_out <= r_wd[255 - 16 * issued -: 16];
					dqm    <= 2'b00;
				end
				else begin
					// the word's high halfword (the lower address) first
					dq_out <= issued[0] ? r_wd[15:0] : r_wd[31:16];
					dqm    <= issued[0] ? ~r_be[1:0] : ~r_be[3:2];
				end
				issued <= issued + 5'd1;
				t      <= 16'd0;
			end
			else if (t == 16'(T_WR) && issued != 5'd0) begin
				if (~r_up) begin
					ack   <= 1'b1;
					acked <= 1'b1;
				end
				command     <= CMD_PRECHARGE;
				SDRAM_A[10] <= 1'b0;
				dqm         <= 2'b00;
				t           <= 16'd0;
				state       <= S_PRE;
			end
		end

		S_PRE: begin
			if (t == 16'(T_RP - 2)) state <= S_IDLE;
		end

		default: state <= S_IDLE;
	endcase

	if (init) begin
		state   <= S_INIT;
		t       <= 16'd0;
		ready   <= 1'b0;
		chip    <= 1'b0;
		acked   <= 1'b0;
		ack     <= 1'b0;
		dqm     <= 2'b11;
	end
end

endmodule

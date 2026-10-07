//============================================================================
//
//  PPCMac - the machine around the CPU
//  The debug readout: rows of squares on the video output, the same rows as
//  hex on the UART once a second, the user LED
//
//  Each row is a 32-bit value as 32 squares of 16 by 16 pixels, bit 31 at
//  the left: a lit square is a 1, a dim one a 0, the nibbles alternating
//  between two colours so that the value can be read from a photograph. No
//  font is needed. The rows, from the top:
//
//     0  the pc of the last instruction retired
//     1  that instruction
//     2  instructions retired since the CPU left reset
//     3  CPU clocks since it left reset
//     4  the MSR as the last instruction left it
//     5  the last address the CPU put on its memory port
//     6  status: 31 ROM loaded, 30 SDRAM ready, 29 CPU in reset, 28 stuck,
//        27 booting the memory test, 26 PLL locked, 23-16 RAM in MB,
//        15-0 how long Cuda held the CPU in reset after the machine's
//        reset, in milliseconds (its cold start: about 1,284, 0504)
//     7  the build date, BCD: 20YYMMDD
//     8  memory test: passes completed      9  errors
//    10  address of the first error        11  its status word
//    12  device writes (word writes to F0000000-FFBFFFFF) since reset
//    13  instructions retired before the last of them
//
//  The three groups (0-7, 8-11, 12-13) have colours of their own. Rows 12
//  and 13 compare a run with the simulation's (run_machine.py --dev-log):
//  before Cuda was built, the 7600's ROM made 26,771 device writes, the
//  last after 18,273,776 instructions, before Open Firmware waited for it
//  forever (docs/DSPPC604_plan.md, M6).
//
//  "Stuck" is nothing retired for 2^24 CPU clocks while out of reset. The
//  LED toggles every 2^20 instructions retired and stays on when stuck.
//
//  The UART sends the fourteen rows as hex, separated by spaces, one line a
//  second, at 115200 8N1.
//
//  Clocks: the capture runs in the CPU's clock; the picture and the UART in
//  the video clock, on the clocks ce_vid enables (20 MHz of them, the
//  template's timing at 15 kHz, doubled when the scan doubler is forced; the
//  core runs it in the 100 MHz memory clock, the Control video's). The values cross once a frame by a
//  request/acknowledge pair of toggles, so a row is never half updated.
//
//============================================================================

module PPCMac_debug
#(
	parameter logic [31:0] BUILD   = 32'h0,
	parameter int          CPU_HZ  = 65_000_000,
	parameter int          VID_HZ  = 20_000_000,
	parameter int          BAUD    = 115_200
)
(
	// the CPU's clock
	input  logic        clk_cpu,
	input  logic        mach_reset,         // the machine's reset (Cuda starts when it ends)
	input  logic        cpu_reset,          // the CPU's: the machine's, or Cuda holding it
	input  logic        trace_valid,
	input  logic        trace_last,
	input  logic [31:0] trace_pc,
	input  logic [31:0] trace_insn,
	input  logic [31:0] trace_msr,
	input  logic        cpu_req,
	input  logic        cpu_we,
	input  logic        cpu_ack,
	input  logic [31:2] cpu_addr,
	input  logic [31:0] mt_passes,
	input  logic [31:0] mt_errors,
	input  logic [31:0] mt_first,
	input  logic [31:0] mt_status,
	output logic        led,

	// status, from wherever it is made (synchronised here)
	input  logic        rom_loaded,
	input  logic        sdram_ready,
	input  logic        boot_memtest,
	input  logic        pll_locked,
	input  logic [7:0]  ram_mb,

	// the video clock, and its enable: the picture and the UART count VID_HZ
	// enabled clocks a second (1 when clk_vid is VID_HZ)
	input  logic        clk_vid,
	input  logic        ce_vid,
	input  logic        pal,
	input  logic        scandouble,
	output logic        ce_pix,
	output logic        hblank,
	output logic        hsync,
	output logic        vblank,
	output logic        vsync,
	output logic [7:0]  r,
	output logic [7:0]  g,
	output logic [7:0]  b,
	output logic        uart_txd
);

localparam int NROWS = 14;

// ---- capture, in the CPU's clock ---------------------------------------------------------
logic [31:0] last_pc, last_insn, last_msr, last_addr, retired, cycles, dev_writes, dev_last;
logic [23:0] idle;
logic        stuck;
wire         dev_space = cpu_addr[31:28] == 4'hF && cpu_addr[31:22] != 10'h3FF;
always_ff @(posedge clk_cpu) begin
	cycles <= cycles + 32'd1;
	if (cpu_req & cpu_ack & cpu_we & dev_space) begin
		dev_writes <= dev_writes + 32'd1;
		dev_last   <= retired;
	end
	if (trace_valid & trace_last) begin
		last_pc   <= trace_pc;
		last_insn <= trace_insn;
		last_msr  <= trace_msr;
		retired   <= retired + 32'd1;
		idle      <= 24'd0;
	end
	else if (~&idle) idle <= idle + 24'd1;
	if (cpu_req) last_addr <= {cpu_addr, 2'b00};
	if (cpu_reset) begin
		retired    <= 32'd0;
		cycles     <= 32'd0;
		idle       <= 24'd0;
		dev_writes <= 32'd0;
		dev_last   <= 32'd0;
	end
end
assign stuck = &idle;
assign led   = stuck | retired[20];

// how long Cuda holds the CPU after the machine's reset, in milliseconds
localparam int MS_DIV = CPU_HZ / 1000;
logic [16:0] ms_div;
logic [15:0] hold_ms;
always_ff @(posedge clk_cpu) begin
	if (cpu_reset) begin
		if (ms_div == 17'(MS_DIV - 1)) begin
			ms_div <= 17'd0;
			if (~&hold_ms) hold_ms <= hold_ms + 16'd1;
		end
		else ms_div <= ms_div + 17'd1;
	end
	if (mach_reset) begin
		ms_div  <= 17'd0;
		hold_ms <= 16'd0;
	end
end

// ---- the crossing: a snapshot once a frame -------------------------------------------------
logic        req_v, ack_c;                  // toggles: video asks, CPU answers
logic [2:0]  req_sync;
logic [31:0] snap [NROWS];
always_ff @(posedge clk_cpu) begin
	req_sync <= {req_sync[1:0], req_v};
	if (req_sync[2] ^ req_sync[1]) begin
		snap[0]  <= last_pc;
		snap[1]  <= last_insn;
		snap[2]  <= retired;
		snap[3]  <= cycles;
		snap[4]  <= last_msr;
		snap[5]  <= last_addr;
		snap[8]  <= mt_passes;
		snap[9]  <= mt_errors;
		snap[10] <= mt_first;
		snap[11] <= mt_status;
		snap[12] <= dev_writes;
		snap[13] <= dev_last;
		snap[6]  <= {2'b00, cpu_reset, stuck, 12'h0, hold_ms};  // the rest is made in the video clock
		snap[7]  <= 32'h0;
		ack_c <= ~ack_c;
	end
end

// ---- the video timing (the template's: 638 x 262, or 525 lines doubled; PAL 312/625) ------
logic [9:0] hc, vc;
logic       pix_t;                          // this enabled clock is a pixel
assign ce_pix = pix_t & ce_vid;
always_ff @(posedge clk_vid) if (ce_vid) begin
	pix_t <= scandouble ? 1'b1 : ~pix_t;
	if (pix_t) begin
		if (hc == 10'd637) begin
			hc <= 10'd0;
			if (vc >= (pal ? (scandouble ? 10'd623 : 10'd311) : (scandouble ? 10'd523 : 10'd261))) vc <= 10'd0;
			else vc <= vc + 10'd1;
		end
		else hc <= hc + 10'd1;
	end
end
always_ff @(posedge clk_vid) if (ce_vid) begin
	if (hc == 10'd529) hblank <= 1'b1;
	else if (hc == 10'd0) hblank <= 1'b0;
	if (hc == 10'd544) begin
		hsync <= 1'b1;
		if (pal) begin
			if (vc == (scandouble ? 10'd609 : 10'd304)) vsync <= 1'b1;
			else if (vc == (scandouble ? 10'd617 : 10'd308)) vsync <= 1'b0;
			if (vc == (scandouble ? 10'd601 : 10'd300)) vblank <= 1'b1;
			else if (vc == 10'd0) vblank <= 1'b0;
		end
		else begin
			if (vc == (scandouble ? 10'd490 : 10'd245)) vsync <= 1'b1;
			else if (vc == (scandouble ? 10'd496 : 10'd248)) vsync <= 1'b0;
			if (vc == (scandouble ? 10'd480 : 10'd240)) vblank <= 1'b1;
			else if (vc == 10'd0) vblank <= 1'b0;
		end
	end
	if (hc == 10'd590) hsync <= 1'b0;
end

// ---- the rows, in the video clock ------------------------------------------------------------
logic [31:0] row [NROWS];
logic [2:0]  ack_sync;
logic [5:0]  st_sync [2];                   // status bits through two flip-flops
logic [7:0]  ram_q [2];
logic [1:0]  cpu_flags;
logic [15:0] hold_q;
logic        vblank_q;
always_ff @(posedge clk_vid) if (ce_vid) begin
	st_sync[0] <= {rom_loaded, sdram_ready, 1'b0, 1'b0, boot_memtest, pll_locked};
	st_sync[1] <= st_sync[0];
	ram_q[0]   <= ram_mb;
	ram_q[1]   <= ram_q[0];
	vblank_q   <= vblank;
	if (vblank & ~vblank_q) req_v <= ~req_v;                // ask for a snapshot each frame
	ack_sync <= {ack_sync[1:0], ack_c};
	if (ack_sync[2] ^ ack_sync[1]) begin
		for (int i = 0; i < NROWS; i++) row[i] <= snap[i];
		cpu_flags <= snap[6][29:28];                        // CPU in reset, stuck
		hold_q    <= snap[6][15:0];                         // Cuda's hold, ms
	end
	row[6] <= {st_sync[1][5], st_sync[1][4], cpu_flags, st_sync[1][1], st_sync[1][0], 2'b00, ram_q[1], hold_q};
	row[7] <= BUILD;
end

// pixel: 32 squares from x = 9, fourteen rows from line 8 (224 lines, inside
// the 240 of the 15 kHz picture), a one-pixel gap round each square
wire [9:0] line = scandouble ? {1'b0, vc[9:1]} : vc;
wire [9:0] x    = hc - 10'd9;
wire [9:0] y    = line - 10'd8;
wire [4:0] col  = x[8:4];
wire [4:0] slot = y[8:4];
wire       in_x = hc >= 10'd9 && x < 10'd512 && x[3:0] != 4'd0 && x[3:0] != 4'd15;
wire       in_y = line >= 10'd8 && slot < 5'(NROWS) && y[3:0] != 4'd0 && y[3:0] != 4'd15;
wire [3:0]  ridx  = slot[3:0];
wire [31:0] rword = row[ridx];              // (a one-dimensional vector before the bit select)
wire        bit_v = rword[5'd31 - col];
wire [1:0]  group = slot < 5'd8 ? 2'd0 : slot < 5'd12 ? 2'd1 : 2'd2;
always_ff @(posedge clk_vid) if (ce_vid) begin
	if (in_x & in_y & ~hblank & ~vblank) begin
		case ({group, col[2]})
			// the machine's rows: yellow and cyan nibbles
			3'b000: {r, g, b} <= bit_v ? 24'hFFFF40 : 24'h303014;
			3'b001: {r, g, b} <= bit_v ? 24'h40FFFF : 24'h141430;
			// the memory test's: green and magenta
			3'b010: {r, g, b} <= bit_v ? 24'h40FF40 : 24'h143014;
			3'b011: {r, g, b} <= bit_v ? 24'hFF40FF : 24'h301430;
			// the device writes: white and orange
			3'b100: {r, g, b} <= bit_v ? 24'hFFFFFF : 24'h303030;
			default: {r, g, b} <= bit_v ? 24'hFF9020 : 24'h302010;
		endcase
	end
	else {r, g, b} <= 24'h0;
end

// ---- the UART: the rows as hex, once a second -------------------------------------------------
localparam int DIV = (VID_HZ + BAUD / 2) / BAUD;
localparam int LINE_CHARS = NROWS * 9 + 2;              // "xxxxxxxx " per row, then CR LF
logic [15:0] baud_cnt;
logic [24:0] sec_cnt;
logic [3:0]  bitn;                                      // 0 idle; 1 start, 2-9 data, 10 stop
logic [7:0]  ch_idx;
logic [9:0]  shifter;
logic        sending;
logic [31:0] urow [NROWS];

function automatic logic [7:0] hexc(input logic [3:0] n);
	hexc = n < 4'd10 ? 8'h30 + {4'h0, n} : 8'h37 + {4'h0, n};
endfunction

wire [3:0]  u_row  = 4'(ch_idx / 8'd9);
wire [3:0]  u_pos  = 4'(ch_idx % 8'd9);
wire [31:0] u_word = urow[u_row];           // (a one-dimensional vector before the part select)
wire [7:0]  u_char = ch_idx == 8'(LINE_CHARS - 2) ? 8'h0D :
                     ch_idx == 8'(LINE_CHARS - 1) ? 8'h0A :
                     u_pos == 4'd8 ? 8'h20 : hexc(u_word[31 - 4 * u_pos -: 4]);

always_ff @(posedge clk_vid) if (ce_vid) begin
	if (sec_cnt == 25'(VID_HZ - 1)) begin
		sec_cnt <= 25'd0;
		if (~sending) begin
			sending <= 1'b1;
			ch_idx  <= 8'd0;
			bitn    <= 4'd0;
			for (int i = 0; i < NROWS; i++) urow[i] <= row[i];
		end
	end
	else sec_cnt <= sec_cnt + 25'd1;

	if (sending) begin
		if (bitn == 4'd0) begin
			shifter  <= {1'b1, u_char, 1'b0};               // stop, data LSB first, start
			bitn     <= 4'd1;
			baud_cnt <= 16'd0;
		end
		else if (baud_cnt == 16'(DIV - 1)) begin
			baud_cnt <= 16'd0;
			shifter  <= {1'b1, shifter[9:1]};
			if (bitn == 4'd10) begin
				bitn <= 4'd0;
				if (ch_idx == 8'(LINE_CHARS - 1)) sending <= 1'b0;
				else ch_idx <= ch_idx + 8'd1;
			end
			else bitn <= bitn + 4'd1;
		end
		else baud_cnt <= baud_cnt + 16'd1;
	end
end
assign uart_txd = ~sending | bitn == 4'd0 | shifter[0];

endmodule

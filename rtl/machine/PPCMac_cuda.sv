//============================================================================
//
//  PPCMac - the machine around the CPU
//  Cuda: the 7600's ADB, power, reset, real-time clock and PRAM
//  microcontroller, as the chip itself: a 68HC05E1 (PPCMac_hc05) running
//  Apple's firmware 341S0060, Cuda 2.40 (PPCMac_cudarom): the 7300's own,
//  read out of its chip through the VIA on 2026-10-07 (cudadump/) and
//  byte for byte MAME's dump
//
//  The 68HC05E1, as MAME's m68hc05e1.cpp maps it and as the firmware uses it:
//
//    00-02  ports A, B, C        a read gives the pins where the DDR bit is
//                                0 and the output latch where it is 1
//    04-06  their DDRs           DDRA bit 0 always reads 0 (PA0 is an input
//                                on Apple's part: MAME, cuda.cpp:146-152)
//    07     PLL control          bit 6 (BCS) selects the bus clock: 0, the
//                                crystal's 32,768 Hz / 2; 1, the PLL at
//                                524,288 << bits 1-0 Hz (2,097,152 with the
//                                firmware's 4E)
//    08     timer control        7 TOF, every 1024 bus cycles; 6 RTIF, every
//                                2^(14 + bits 1-0) bus cycles; 5, 4 their
//                                interrupt enables. A flag is cleared by
//                                writing 0 to it, and writing 1 leaves it.
//    09     timer counter        bus cycles / 4
//    12     one-second timer     6 the flag, every second of the crystal's
//                                time; 4 its interrupt enable; 0 clears
//    90-1FF RAM, 368 bytes (PRAM is 100-1FF, the clock AB-AE)
//    F00-1FFF the ROM
//
//  Anything else reads 0. Not in MAME and here: the RTI flag (MAME has no
//  RTI, so its Cuda never runs the timer interrupt's second half: the power
//  switch's polling and the shutdown watchdog's count at 16 a second); the
//  slow bus clock before the firmware turns the PLL on (MAME runs at full
//  speed from reset); TOF at the bus clock / 1024 (MAME doubles the
//  firmware's PLL rate there). The bus clock, the timer and the one-second
//  interrupt all count from one 4,194,304 Hz phase accumulator on clk.
//
//  The firmware's own timing confirms the 2,097,152 Hz bus: its 1 ms delay
//  (1E23) is 2,096 cycles, its ADB attention pulse 1,677 cycles (800 us)
//  and its bit cells 137 and 73 (65 and 35 us), and the ADB auto-poll's
//  timer count (2 x 11 - 3 TOFs) gives the 11 ms its rate byte says.
//
//  The pins, as the 7600 board connects them (MAME, cuda.cpp:18-52):
//
//    PA7 out  ADB, 1 pulls the line low     PB7 I2C clock (open drain)
//    PA6 in   ADB, the line's level (1 high) PB6 I2C data (open drain)
//    PA5 in   1: soft power                 PB5 the VIA's CB2, data, both ways
//    PA4 out  DFAC latch                    PB4 out the VIA's CB1, the shift clock
//    PA3 out  fast reset                    PB3 in  TIP, from the VIA's PB5
//    PA2 in   1: the power key is up        PB2 in  BYTEACK, from the VIA's PB4
//    PA1 in   1: the power button is up     PB1 out TREQ, to the VIA's PB3
//    PA0 in   1: the power is good          PB0 in  1: +5 V is there
//             (an input to the firmware, as MAME makes it: DDRA bit 0
//             reads 0. The power-down path drives it low (1161-1163),
//             which switches the supply off: power_off, once it has been
//             low 256 bus cycles (the cold start's port set-up drives it
//             low for 65). The power-on path drives it high (1187))
//    PC3      the CPU's reset, low resets; pulled up
//    PC2      NMI, pulled up; driven low, Grand Central's interrupt source
//             14 (nmi): the firmware pulses it (1C2B) when the keyboard's
//             Command and power keys are down together (its key table at
//             1B7D: Control, Command, power, Option; 1DB1 picks the NMI or,
//             with Control too, the reset at 1BF6)
//    PC1, PC0 in: 1
//
//  The straps are MAME's (cuda.cpp pa_r, pb_r, pc_r) but for PA5, which
//  MAME reads as 0. MAME has no RTI, so its Cuda never runs the timer
//  interrupt's half that polls the power switches (1EA8-1EEF); with RTI,
//  PA5 = 0 reads as the switch off and the firmware powers down two ticks
//  (125 ms) after powering up. PA5 = 1 with PA1 = 1 is soft power with the
//  button up: nothing happens. With the IRQ pin high, a cold start runs the
//  firmware's battery-insert path: about a second on the slow clock, the
//  PLL on, the power-on sequence, and the CPU's reset released about 250 ms
//  later.
//
//  PA6 is the ADB line as it is (corrected 2026-10-07; it was taken
//  inverted). The firmware's ADB receive (1CF3-1D88) shows it: just after
//  its stop bit a low line is a service request (flag bit 0) and a high one
//  is none; then it waits up to 283 us for the start bit's fall, 58 us for
//  its low to end, 79 us for its high, and decides each bit by whether its
//  high outlasts its low. MAME agrees, its devices' ASSERT being the line
//  high (macadb.cpp leaves the line ASSERTed when idle).
//
//  The CPU's reset (cpu_reset): held from this module's reset until the
//  firmware first drives PC3 low and then lets it go high; again whenever it
//  drives PC3 low (a restart); and from a power-down (Shut Down, POWER_DOWN)
//  until this module's reset: the machine is off (the OSD's reset or the
//  power key, PPCMac_system, starts it again).
//
//============================================================================

module PPCMac_cuda
#(
	parameter int unsigned CLK_HZ    = 65_000_000,   // clk; at least 2 x 4,194,304
	// for the machine's test bench only: while the CPU is held in reset, a
	// 4,194,304 Hz tick on every clock, so the cold start takes 1/15 of the
	// clocks at 65 MHz. Nothing outside Cuda can see its time then (the VIA is
	// idle), so the firmware runs the same instructions, only sooner.
	parameter bit          FAST_BOOT = 1'b0
)
(
	input  logic        clk,
	input  logic        reset,

	// the VIA's side (Grand Central's VIA, port B and the shift register)
	input  logic        via_tip,         // the VIA's PB5: 0 while a transaction is in progress
	input  logic        via_byteack,     // the VIA's PB4
	output logic        treq,            // to the VIA's PB3: 0 when Cuda asks for a transaction
	output logic        cb1,             // the shift clock, to the VIA's CB1
	output logic        cb2_oe,          // Cuda drives the data line
	output logic        cb2_out,
	input  logic        cb2,             // the data line, whoever drives it

	// the rest of the board
	output logic        cpu_reset,       // the CPU's reset
	output logic        power_off,       // the firmware switched the supply off: until this module's reset
	output logic        nmi,             // PC2 driven low: the NMI (Grand Central's source 14)
	input  logic        clock_ok,        // clock_secs holds the date and time
	input  logic [31:0] clock_secs,      // seconds since 1904-01-01 (the Mac's clock), steady
	output logic        adb_low,         // pull the ADB line low
	input  logic        adb_line,        // the ADB line's level
	output logic        tick,            // the 4,194,304 Hz time base (for the ADB devices' timing)
	output logic        iic_scl_low,     // pull the I2C clock low
	output logic        iic_sda_low,     // pull the I2C data low
	input  logic        iic_scl,         // the I2C lines' levels
	input  logic        iic_sda,

	// for the test bench and the debug readout
	output logic        dbg_cen,         // a bus cycle ends at this clock
	output logic [12:0] dbg_addr,
	output logic        dbg_rd,
	output logic        dbg_wr,
	output logic [7:0]  dbg_wdata,
	output logic [7:0]  dbg_rdata,
	output logic        tr_valid,
	output logic        tr_int,
	output logic [12:0] tr_pc,
	output logic [7:0]  tr_op,
	output logic [7:0]  tr_a,
	output logic [7:0]  tr_x,
	output logic [7:0]  tr_sp,
	output logic [7:0]  tr_cc,
	output logic        dbg_cpi,         // the one-second timer's tick (the bench's clock)
	output logic        dbg_fast         // the bus runs from the PLL
);

// ---- the clocks: a 4,194,304 Hz tick, the bus cycle, the second -----------------------
logic [31:0] xacc;
logic        xtick;
logic [21:0] xdiv;                     // the crystal's time, 2^22 ticks a second
logic [7:0]  pll, tctl, onesec;
logic        cen;

wire        fast  = pll[6];
wire  [7:0] bmask = fast ? (8'h07 >> pll[1:0]) : 8'hFF;   // ticks per bus cycle, less 1
wire        sec   = xtick & (&xdiv);
assign tick = xtick;

always_ff @(posedge clk) begin
	xtick <= 1'b0;
	if (FAST_BOOT && cpu_reset) xtick <= 1'b1;
	else if (xacc + 32'd4_194_304 >= CLK_HZ) begin
		xacc  <= xacc + 32'd4_194_304 - CLK_HZ;
		xtick <= 1'b1;
	end
	else xacc <= xacc + 32'd4_194_304;
	if (xtick) xdiv <= xdiv + 22'd1;
	cen <= xtick & ((xdiv[7:0] & bmask) == bmask);
	if (reset) begin
		xacc  <= 32'h0;
		xtick <= 1'b0;
		xdiv  <= 22'h0;
		cen   <= 1'b0;
	end
end

// ---- the CPU --------------------------------------------------------------------------------
logic [12:0] addr;
logic        rd, wr;
logic [7:0]  wdata, rdata;
logic        int_timer, int_cpi;

PPCMac_hc05 cpu (
	.clk, .reset, .cen,
	.addr, .rd, .wr, .wdata, .rdata,
	.irq_n(1'b1), .int_timer, .int_cpi,
	.tr_valid, .tr_int, .tr_pc, .tr_op, .tr_a, .tr_x, .tr_sp, .tr_cc
);

// ---- the ports ------------------------------------------------------------------------------
logic [7:0] pa, pb, pc_, ddra, ddrb, ddrc;

// what each pin is: the latch where Cuda drives it, else the board
wire [7:0] pa_pins = {1'b0, adb_line, 1'b1, 1'b0, 1'b0, 1'b1, 1'b1, 1'b1};
wire [7:0] pb_pins = {iic_scl, iic_sda, cb2, 1'b0, via_tip, via_byteack, 1'b0, 1'b1};
wire [7:0] pc_pins = 8'h0F;
wire [7:0] pa_rd   = (pa_pins & ~ddra) | (pa & ddra);
wire [7:0] pb_rd   = (pb_pins & ~ddrb) | (pb & ddrb);
wire [7:0] pc_rd   = (pc_pins & ~ddrc) | (pc_ & ddrc);

assign adb_low     = ddra[7] & pa[7];
assign treq        = ~ddrb[1] | pb[1];
assign cb1         = ~ddrb[4] | pb[4];
assign cb2_oe      = ddrb[5];
assign cb2_out     = pb[5];
assign iic_sda_low = ddrb[6] & ~pb[6];
assign iic_scl_low = ddrb[7] & ~pb[7];
assign nmi         = ddrc[2] & ~pc_[2];

// the CPU's reset follows PC3, once the firmware has first pulled it low
wire  pc3 = ~ddrc[3] | pc_[3];
logic powered;
always_ff @(posedge clk) begin
	if (~pc3) powered <= 1'b1;
	cpu_reset <= ~powered | ~pc3 | power_off;
	if (reset) begin
		powered   <= 1'b0;
		cpu_reset <= 1'b1;
	end
end

// ---- the timers ------------------------------------------------------------------------------
logic [16:0] tdiv;                     // bus cycles; the timer counter is bits 9-2
wire         tof_now = &tdiv[9:0];
wire         rti_now = &(tdiv | ~(17'h1FFFF >> (2'd3 - tctl[1:0])));   // bits 13+RT .. 0 all ones
assign int_timer = (tctl[7] & tctl[5]) | (tctl[6] & tctl[4]);
assign int_cpi   = onesec[6] & onesec[4];

// ---- memory and registers --------------------------------------------------------------------
wire        is_io  = addr[12:5] == 8'h00;
wire        is_ram = addr >= 13'h0090 && addr < 13'h0200;
wire        is_rom = addr >= 13'h0F00;

// the power-down (115B) drives PA0 low (1161-1163) and waits there over a second; the port
// set-up (1255, at every cold start) for some 65 bus cycles only
logic       ddra0;                     // DDRA bit 0 as written (it reads 0)
logic [8:0] pa0_low;                   // bus cycles PA0 has been driven low
always_ff @(posedge clk) begin
	if (cen & wr & is_io && addr[4:0] == 5'h04) ddra0 <= wdata[0];
	if (!ddra0 || pa[0]) pa0_low <= 9'd0;
	else if (cen && !pa0_low[8]) pa0_low <= pa0_low + 9'd1;
	if (pa0_low[8]) power_off <= 1'b1;
	if (reset) begin
		ddra0     <= 1'b0;
		pa0_low   <= 9'd0;
		power_off <= 1'b0;
	end
end

// ---- the clock: set once, when the CPU's reset is first released ---------------------------
// As MAME's Cuda does (cuda.cpp pc_w): the firmware's cold start has set its
// clock (RAM AB-AE, seconds since 1904, the high byte first) to 630BD178;
// the date and time go there as the machine starts, a byte a clock when the
// firmware is not writing RAM itself. Not again until this module's reset.
logic [2:0] clk_ld;                    // bytes left: AE at 4 ... AB at 1
logic       clk_set, rst_q;
wire  [7:0] clk_byte = clock_secs[8 * (3'd4 - clk_ld) +: 8];
wire        cpu_ram_we = cen & wr & is_ram;
wire        ram_we     = cpu_ram_we | (clk_ld != 3'd0);
wire  [8:0] ram_wa     = cpu_ram_we ? addr[8:0] : 9'h0AA + 9'(clk_ld);
wire  [7:0] ram_wd     = cpu_ram_we ? wdata : clk_byte;

logic [7:0] ram [0:511];
logic [7:0] ram_q, rom_q, io_q;
logic [1:0] sel_q;                     // 0 nothing, 1 registers, 2 RAM, 3 ROM

PPCMac_cudarom rom (.clk, .addr(addr - 13'h0F00), .q(rom_q));

always_ff @(posedge clk) begin
	ram_q <= ram[addr[8:0]];
	sel_q <= is_rom ? 2'd3 : is_ram ? 2'd2 : is_io ? 2'd1 : 2'd0;
	case (addr[4:0])
		5'h00:   io_q <= pa_rd;
		5'h01:   io_q <= pb_rd;
		5'h02:   io_q <= pc_rd;
		5'h04:   io_q <= ddra;
		5'h05:   io_q <= ddrb;
		5'h06:   io_q <= ddrc;
		5'h07:   io_q <= pll;
		5'h08:   io_q <= tctl;
		5'h09:   io_q <= tdiv[9:2];
		5'h12:   io_q <= onesec;
		default: io_q <= 8'h00;
	endcase
	if (ram_we) ram[ram_wa] <= ram_wd;
end

always_ff @(posedge clk) begin
	rst_q <= cpu_reset;
	if (rst_q && !cpu_reset && !clk_set && clock_ok) begin
		clk_set <= 1'b1;
		clk_ld  <= 3'd4;
	end
	else if (clk_ld != 3'd0 && !cpu_ram_we) clk_ld <= clk_ld - 3'd1;
	if (reset) begin
		clk_set <= 1'b0;
		clk_ld  <= 3'd0;
		rst_q   <= 1'b1;
	end
end

assign rdata = sel_q == 2'd3 ? rom_q : sel_q == 2'd2 ? ram_q : sel_q == 2'd1 ? io_q : 8'h00;

always_ff @(posedge clk) begin
	if (cen) begin
		tdiv <= tdiv + 17'd1;
		if (tof_now) tctl[7] <= 1'b1;
		if (rti_now) tctl[6] <= 1'b1;
	end
	if (sec) onesec[6] <= 1'b1;

	if (cen & wr & is_io) begin
		case (addr[4:0])
			5'h00: pa   <= wdata;
			5'h01: pb   <= wdata;
			5'h02: pc_  <= wdata;
			5'h04: ddra <= wdata & 8'hFE;
			5'h05: ddrb <= wdata;
			5'h06: ddrc <= wdata;
			5'h07: pll  <= wdata;
			5'h08: begin
				// a flag stays set where 1 is written; one that sets in this
				// cycle is not lost
				tctl[7]   <= (tctl[7] & wdata[7]) | tof_now;
				tctl[6]   <= (tctl[6] & wdata[6]) | rti_now;
				tctl[5:0] <= wdata[5:0];
			end
			5'h12: begin
				onesec[6] <= (onesec[6] & wdata[6]) | sec;
				{onesec[7], onesec[5:0]} <= {wdata[7], wdata[5:0]};
			end
			default: ;
		endcase
	end

	if (reset) begin
		pa     <= 8'h00;
		pb     <= 8'h00;
		pc_    <= 8'h00;
		ddra   <= 8'h00;
		ddrb   <= 8'h00;
		ddrc   <= 8'h00;
		pll    <= 8'h00;
		tctl   <= 8'h00;
		onesec <= 8'h00;
		tdiv   <= 17'h0;
	end
end

assign dbg_cen   = cen;
assign dbg_addr  = addr;
assign dbg_rd    = rd;
assign dbg_wr    = wr;
assign dbg_wdata = wdata;
assign dbg_rdata = rdata;
assign dbg_cpi   = sec;
assign dbg_fast  = fast;

endmodule

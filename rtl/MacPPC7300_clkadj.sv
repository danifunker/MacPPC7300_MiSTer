//============================================================================
//
//  MacPPC7300 - the machine around the CPU
//  The CPU's clock chosen at run time
//
//  The OSD's choice of CPU clock is applied to the PLL's CPU output counter
//  (counter 1 of a 1200 MHz VCO: rtl/pll/pll_0002.v) through the PLL's
//  reconfiguration block (altera_pll_reconfig_top, in the top), the way the
//  framework adjusts its HDMI PLL. Only that counter changes: the memory and
//  video clocks keep running and the PLL keeps its lock. A change is made
//  while the machine is held in reset (the OSD's reset, or power-up: the
//  choice is "on reset", as the RAM size), and the reset is held (busy) until
//  the new clock is there; the choice in effect (cur) also selects the clock
//  rate the machine's time bases take (cpu_hz, in the top).
//
//  The reconfiguration block's writes: C_COUNTERS (5) with the counter in
//  bits 22-18, its odd-division flag in 17 and the high and low counts in
//  15-8 and 7-0, then START (2); in its wait-request mode each write is taken
//  when mgmt_waitrequest is low, and it stays high after START until the PLL
//  is reconfigured and locked.
//
//============================================================================

module MacPPC7300_clkadj
#(
	parameter logic [2:0] BUILT_IN = 3'd1    // the table's entry the PLL was built with
)
(
	input  logic        clk,                 // the PLL's reference (50 MHz), free-running
	input  logic        reset,               // the reconfiguration block's (power-up)
	input  logic [2:0]  sel,                 // the OSD's choice (another clock; synchronised here)
	input  logic        machine_reset,       // the machine is held in reset (another clock)
	input  logic        locked,
	input  logic        mgmt_waitrequest,
	output logic        mgmt_write,
	output logic [5:0]  mgmt_address,
	output logic [31:0] mgmt_writedata,
	output logic        busy,                // hold the machine in reset
	output logic [2:0]  cur                  // the choice in effect
);

// the CPU output counter's divisor for each choice (1200 MHz / C)
function automatic logic [4:0] divisor(input logic [2:0] k);
	case (k)
		3'd0:    divisor = 5'd12;            // 100 MHz
		3'd1:    divisor = 5'd11;            // 109.09
		3'd2:    divisor = 5'd10;            // 120
		3'd3:    divisor = 5'd9;             // 133.33
		3'd4:    divisor = 5'd13;            // 92.31
		3'd5:    divisor = 5'd14;            // 85.71
		3'd6:    divisor = 5'd15;            // 80
		default: divisor = 5'd16;            // 75
	endcase
endfunction

// the C_COUNTERS word for counter 1: an odd divisor counts one more high
function automatic logic [31:0] c1_word(input logic [4:0] d);
	logic [7:0] hi, lo;
	lo = {4'd0, d[4:1]};
	hi = d[0] ? lo + 8'd1 : lo;
	c1_word = {9'd0, 5'd1, d[0], 1'b0, hi, lo};
endfunction

localparam logic [5:0] C_COUNTERS_REG = 6'd5;
localparam logic [5:0] START_REG      = 6'd2;

typedef enum logic [2:0] { S_IDLE, S_SETTLE, S_COUNTER, S_START, S_WAIT } state_t;
state_t      state;
logic [2:0]  sel_1, sel_2, want;
logic        mr_1, mr_2;
logic [17:0] timer;

always_ff @(posedge clk) begin
	sel_1 <= sel;
	sel_2 <= sel_1;
	mr_1  <= machine_reset;
	mr_2  <= mr_1;
	timer <= timer + 18'd1;
	case (state)
	S_IDLE: begin
		mgmt_write <= 1'b0;
		if (mr_2 & (sel_2 != cur)) begin
			busy  <= 1'b1;
			want  <= sel_2;
			timer <= 18'd0;
			state <= S_SETTLE;
		end
	end
	S_SETTLE: if (timer[12]) begin           // 80 us: the reset held everywhere
		mgmt_write     <= 1'b1;
		mgmt_address   <= C_COUNTERS_REG;
		mgmt_writedata <= c1_word(divisor(want));
		state          <= S_COUNTER;
	end
	S_COUNTER: if (~mgmt_waitrequest) begin  // taken at this edge
		mgmt_address   <= START_REG;
		mgmt_writedata <= 32'd0;
		state          <= S_START;
	end
	S_START: if (~mgmt_waitrequest) begin
		mgmt_write <= 1'b0;
		timer      <= 18'd0;
		state      <= S_WAIT;
	end
	S_WAIT: if (timer[17] & ~mgmt_waitrequest & locked) begin   // 2.6 ms, and the block done
		cur   <= want;
		busy  <= 1'b0;
		state <= S_IDLE;
	end
	default: state <= S_IDLE;
	endcase
	if (reset) begin
		state      <= S_IDLE;
		busy       <= 1'b0;
		cur        <= BUILT_IN;
		mgmt_write <= 1'b0;
	end
end

endmodule

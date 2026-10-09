//============================================================================
//
//  MacPPC7300 - the machine around the CPU
//  Athens, the clock generator (Apple 343S1191) that makes the video's dot
//  clock, as an I2C slave on Cuda's I2C lines
//
//  Mac OS's video driver sets the dot clock through Cuda (pseudo-command 22,
//  read/write I2C: "01 22 50 reg value"); Cuda's firmware bit-bangs the
//  transfer on its pins, and this device answers on them as dingusppc's
//  devices/common/clockgen/athens.cpp does:
//
//    - address 28 (write 50, read 51); anything else is left alone;
//    - a write takes the register number, then its value; further bytes are
//      acknowledged and dropped; a register number of 8 or more is refused
//      (no acknowledge) at its value byte;
//    - a read answers 41 to every byte (dingusppc's guess at the ID);
//    - eight registers, 0 the ID, 1 D2, 2 N2, 3 P2_MUX2, 4-7 the system
//      clock's, kept and unused; D2 and N2 start at 2, P2_MUX2 at 62 (the dot
//      clock's VCO off, the crystal / 2).
//
//  The dot clock is 31.3344 MHz x N2 / (D2 x 2^(3 - P2_MUX2[1:0])) with
//  P2_MUX2[5:4] = 0, the crystal / 2^(3 - P2_MUX2[1:0]) with 2, and off
//  with P2_MUX2[7] (MacPPC7300_swatch makes it).
//
//  The lines are sampled in the CPU's clock, where Cuda drives them; Cuda's
//  I2C is a few tens of kHz, so every edge is seen many times over.
//
//============================================================================

module MacPPC7300_athens
#(
	parameter logic [6:0] ADDR = 7'h28
)
(
	input  logic       clk,
	input  logic       reset,
	input  logic       scl,           // the bus as everyone sees it (wired AND)
	input  logic       sda,
	output logic       sda_low,       // this device pulls SDA low
	output logic [7:0] d2,
	output logic [7:0] n2,
	output logic [7:0] p2_mux2
);

logic [7:0] regs [8];
logic       scl_q, sda_q;
logic [7:0] sh;
logic [3:0] bitn;                 // bits shifted in or out; 9: the acknowledge clock
logic       rd;                   // the transfer reads from us
logic       mack;                 // the master acknowledged the byte we sent
logic [7:0] reg_n;
logic [1:0] nbyte;                // data bytes written so far (saturating at 2)

typedef enum logic [1:0] {S_IDLE, S_ADDR, S_WRITE, S_READ} st_t;
st_t st;

wire start = scl & scl_q & sda_q & ~sda;
wire stop  = scl & scl_q & ~sda_q & sda;
wire rise  = scl & ~scl_q;
wire fall  = ~scl & scl_q;
wire [7:0] byte_in = sh;          // complete after eight rising edges

assign d2      = regs[1];
assign n2      = regs[2];
assign p2_mux2 = regs[3];

always_ff @(posedge clk) begin
	scl_q <= scl;
	sda_q <= sda;

	if (start) begin
		st      <= S_ADDR;
		bitn    <= 4'd0;
		nbyte   <= 2'd0;
		sda_low <= 1'b0;
	end
	else if (stop) begin
		st      <= S_IDLE;
		sda_low <= 1'b0;
	end
	else begin
		case (st)
			S_ADDR, S_WRITE: begin
				if (rise && bitn < 4'd8) begin
					sh   <= {sh[6:0], sda};
					bitn <= bitn + 4'd1;
				end
				else if (fall && bitn == 4'd8) begin
					// the eighth bit is in: acknowledge it, or not
					bitn <= 4'd9;
					if (st == S_ADDR) begin
						if (byte_in[7:1] == ADDR) begin
							sda_low <= 1'b1;
							rd      <= byte_in[0];
						end
						else st <= S_IDLE;
					end
					else begin
						if (nbyte == 2'd0) begin
							reg_n   <= byte_in;
							sda_low <= 1'b1;
						end
						else if (nbyte == 2'd1) begin
							if (reg_n < 8'd8) begin
								regs[reg_n[2:0]] <= byte_in;
								sda_low <= 1'b1;
							end
						end
						else sda_low <= 1'b1;
						if (nbyte != 2'd2) nbyte <= nbyte + 2'd1;
					end
				end
				else if (fall && bitn == 4'd9) begin
					// the acknowledge clock is over
					sda_low <= 1'b0;
					bitn    <= 4'd0;
					if (st == S_ADDR && rd) begin
						st      <= S_READ;
						sh      <= 8'h41;
						sda_low <= 1'b1;                   // bit 7 of 41: a 0
						bitn    <= 4'd1;
					end
					else if (st == S_ADDR) st <= S_WRITE;
				end
			end
			S_READ: begin
				if (fall && bitn < 4'd8) begin
					sda_low <= ~sh[7 - bitn[2:0]];
					bitn    <= bitn + 4'd1;
				end
				else if (fall && bitn == 4'd8) begin
					sda_low <= 1'b0;                       // the master's acknowledge
					bitn    <= 4'd9;
				end
				else if (rise && bitn == 4'd9) mack <= ~sda;
				else if (fall && bitn == 4'd9) begin
					if (mack) begin
						sh      <= 8'h41;
						sda_low <= 1'b1;                   // bit 7 of 41: a 0
						bitn    <= 4'd1;
					end
					else st <= S_IDLE;
				end
			end
			default: ;
		endcase
	end

	if (reset) begin
		st      <= S_IDLE;
		sda_low <= 1'b0;
		scl_q   <= 1'b1;
		sda_q   <= 1'b1;
		bitn    <= 4'd0;
		rd      <= 1'b0;
		mack    <= 1'b0;
		nbyte   <= 2'd0;
		reg_n   <= 8'h00;
		sh      <= 8'h00;
		regs[0] <= 8'h00;
		regs[1] <= 8'h02;
		regs[2] <= 8'h02;
		regs[3] <= 8'h62;
		for (int i = 4; i < 8; i++) regs[i] <= 8'h00;
	end
end

endmodule

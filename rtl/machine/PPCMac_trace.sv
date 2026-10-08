//============================================================================
//
//  PPCMac - the machine around the CPU
//  A trace in DDR3, for debugging on the board: 32-byte records from the
//  CPU's clock into a ring the ARM reads (syn/mister.py trace)
//
//  At BASE (64-bit words): 0 {"TRCE", records written}, 1 records dropped
//  (a queue of 16 overflowed), record n at 8 + (n mod RECS) * 4.
//
//============================================================================

module PPCMac_trace
#(
	parameter logic [31:0] BASE = 32'h3050_0000,
	parameter int          RECS = 2048
)
(
	// the CPU's clock
	input  logic         clk,
	input  logic         ev,
	input  logic [255:0] rec,

	// the memory clock: the DDR3 port
	input  logic         clk_h,
	input  logic         reset_h,
	input  logic         ddr_busy,
	output logic [7:0]   ddr_burstcnt,
	output logic [28:0]  ddr_addr,
	output logic         ddr_rd,
	output logic [63:0]  ddr_din,
	output logic [7:0]   ddr_be,
	output logic         ddr_we
);

localparam int          RB = $clog2(RECS);
localparam logic [28:0] W0 = BASE[31:3];
localparam logic [28:0] R0 = W0 + 29'd8;

// the CPU's clock: a queue of 16, then one record held while it is written
logic [255:0] q [16];
logic [3:0]   wp = 4'd0, rp = 4'd0;
logic [255:0] hold;
logic         c_tog = 1'b0, c_busy = 1'b0;
logic [2:0]   c_done_s;
logic [31:0]  drops = 32'd0;
logic         h_done = 1'b0;

always_ff @(posedge clk) begin
	c_done_s <= {c_done_s[1:0], h_done};
	if (ev) begin
		if (wp + 4'd1 == rp) drops <= drops + 32'd1;
		else begin
			q[wp] <= rec;
			wp    <= wp + 4'd1;
		end
	end
	if (c_busy) begin
		if (c_done_s[2] == c_tog) c_busy <= 1'b0;
	end
	else if (wp != rp) begin
		hold   <= q[rp];
		rp     <= rp + 4'd1;
		c_tog  <= ~c_tog;
		c_busy <= 1'b1;
	end
end

// hold and drops stand still from the toggle until h_done answers it
logic [2:0]  h_req_s;
logic [31:0] n = 32'd0;
logic [2:0]  k;
logic        wr = 1'b0;

assign ddr_rd       = 1'b0;
assign ddr_be       = 8'hFF;
assign ddr_burstcnt = 8'd1;

always_ff @(posedge clk_h) begin
	h_req_s <= {h_req_s[1:0], c_tog};
	if (ddr_we && !ddr_busy) ddr_we <= 1'b0;
	if (!wr) begin
		if (h_req_s[2] != h_done) begin
			k  <= 3'd0;
			wr <= 1'b1;
		end
	end
	else if (!ddr_we) begin
		ddr_we <= 1'b1;
		case (k)
			3'd0: begin ddr_addr <= R0 + 29'({n[RB-1:0], 2'd0}); ddr_din <= hold[63:0];    end
			3'd1: begin ddr_addr <= R0 + 29'({n[RB-1:0], 2'd1}); ddr_din <= hold[127:64];  end
			3'd2: begin ddr_addr <= R0 + 29'({n[RB-1:0], 2'd2}); ddr_din <= hold[191:128]; end
			3'd3: begin ddr_addr <= R0 + 29'({n[RB-1:0], 2'd3}); ddr_din <= hold[255:192]; end
			3'd4: begin ddr_addr <= W0 + 29'd1;                  ddr_din <= {32'd0, drops}; end
			default: begin ddr_addr <= W0;                       ddr_din <= {32'h5452_4345, n + 32'd1}; end
		endcase
		k <= k + 3'd1;
		if (k == 3'd5) begin
			n      <= n + 32'd1;
			h_done <= h_req_s[2];
			wr     <= 1'b0;
		end
	end
	if (reset_h) ddr_we <= 1'b0;
end

endmodule

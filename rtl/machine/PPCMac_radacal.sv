//============================================================================
//
//  PPCMac - the machine around the CPU
//  RaDACal, the Control video's RAMDAC: Grand Central's IOBus device 2
//  (F301B000), as dingusppc's devices/video/appleramdac.cpp has it
//
//  Four registers, 16 bytes apart ((offset >> 4) & 3; the IOBus gives a byte):
//
//    0  address: a colour-table index, or a register of the multipurpose
//       section; resets the component count
//    1  cursor colour table: R, G, B of entry (address & 7), then the address
//       moves on
//    2  multipurpose: the register the address names:
//         10, 11  the cursor's horizontal position, high and low byte
//         20      MISC_CTRL: bit 1 the hardware cursor on, bits 3-2 the pixel
//                 width (8 << n bits), bits 7-6 the clock divisor
//                 (2 << n, 3 meaning 1: pixels per Swatch count)
//         21      double-buffer control (0: the optional VRAM bank shown)
//         22      test control, 23 PLL control, 24/25/27/28 the PLL's M and
//                 PN values (DACula's; kept)
//         40      vendor ID, read only: 3C (dingusppc's default)
//       reads give MISC_CTRL, PLL control and the vendor ID; others 0
//    3  colour table: R, G, B of entry (address), then the address moves on;
//       a write's first component reads the entry first (the others stay),
//       a read's first fetches it
//
//  The colour table is 256 x 24 bits, in two copies written together: one
//  read in the CPU's clock, one in the video clock by the scan-out, a
//  table a component (v_index_r/g/b in, v_rgb a clock later: an 8-bit
//  pixel gives all three the same index, a 32-bit one each its component,
//  as a DirectColor RAMDAC; 2026-10-08, Linux's controlfb). The cursor table and the cursor's
//  position and the control bits go to the scan-out as they are (they change
//  between frames, and a frame's worth of tearing on a cursor is all a
//  stray read can cost).
//
//  An access is presented for one cycle (sel); the read data (rq) is valid
//  in the next cycle.
//
//============================================================================

module PPCMac_radacal
(
	input  logic         clk,
	input  logic         reset,
	input  logic         sel,
	input  logic         we,
	input  logic [1:0]   rn,
	input  logic [7:0]   wdata,
	output logic [7:0]   rq,              // the read's answer, in the cycle after sel

	// to the scan-out, standing still between the driver's changes
	output logic [7:0]   dac_cr,
	output logic [7:0]   dbl_buf_cr,
	output logic [15:0]  cursor_x,
	output logic [191:0] cursor_clut,     // entry n in bits 24n+23 .. 24n (R, G, B)

	// the colour table's second read port, in the video clock
	input  logic         clk_v,
	input  logic [7:0]   v_index_r,
	input  logic [7:0]   v_index_g,
	input  logic [7:0]   v_index_b,
	output logic [23:0]  v_rgb
);

localparam logic [7:0] VENDOR = 8'h3C;   // appleramdac.h DACULA_VENDOR_SIERRA, dingusppc's default

logic [7:0]  dac_addr, tst_cr, pll_cr;
logic [7:0]  clk_m [2];
logic [7:0]  clk_pn [2];
logic [1:0]  comp;
logic [7:0]  col0, col1, col2;          // the components of the entry in hand
logic [7:0]  rq_reg;
logic        rq_ram;                    // the answer is the table's red, fetched in this cycle
logic        fill_rd, fill_wr;          // the entry read last cycle fills col0-2, col1-2
logic [7:0]  cur_r [8];
logic [7:0]  cur_g [8];
logic [7:0]  cur_b [8];

// ---- the colour table: two copies ---------------------------------------------------------
logic [23:0] clut_c [0:255];
logic [23:0] clut_q;
logic        clut_we;
logic [23:0] clut_wv;

always_ff @(posedge clk) begin
	if (clut_we) clut_c[dac_addr] <= clut_wv;
	clut_q <= clut_c[dac_addr];
end

// the scan-out's copy, a table a component: 8-bit pixels look all three up with one index,
// 32-bit (DirectColor, as Linux's controlfb sets it up) each with its own
logic [7:0] clut_vr [0:255];
logic [7:0] clut_vg [0:255];
logic [7:0] clut_vb [0:255];
always_ff @(posedge clk) if (clut_we) clut_vr[dac_addr] <= clut_wv[23:16];
always_ff @(posedge clk) if (clut_we) clut_vg[dac_addr] <= clut_wv[15:8];
always_ff @(posedge clk) if (clut_we) clut_vb[dac_addr] <= clut_wv[7:0];
always_ff @(posedge clk_v) v_rgb[23:16] <= clut_vr[v_index_r];
always_ff @(posedge clk_v) v_rgb[15:8]  <= clut_vg[v_index_g];
always_ff @(posedge clk_v) v_rgb[7:0]   <= clut_vb[v_index_b];

assign rq = rq_ram ? clut_q[23:16] : rq_reg;

wire wr = sel & we;
wire rd = sel & ~we;

always_comb begin
	clut_we = wr & (rn == 2'd3) & (comp == 2'd2);
	clut_wv = {col0, col1, wdata};
end

always_comb
	for (int i = 0; i < 8; i++) cursor_clut[24 * i +: 24] = {cur_r[i], cur_g[i], cur_b[i]};

always_ff @(posedge clk) begin
	rq_ram <= 1'b0;
	if (fill_rd) begin col0 <= clut_q[23:16]; col1 <= clut_q[15:8]; col2 <= clut_q[7:0]; end
	if (fill_wr) begin col1 <= clut_q[15:8]; col2 <= clut_q[7:0]; end
	fill_rd <= 1'b0;
	fill_wr <= 1'b0;

	if (wr) begin
		case (rn)
			2'd0: begin dac_addr <= wdata; comp <= 2'd0; end
			2'd1: begin
				case (comp)
					2'd0: col0 <= wdata;
					2'd1: col1 <= wdata;
					default: begin
						cur_r[dac_addr[2:0]] <= col0;
						cur_g[dac_addr[2:0]] <= col1;
						cur_b[dac_addr[2:0]] <= wdata;
					end
				endcase
				if (comp == 2'd2) begin comp <= 2'd0; dac_addr <= dac_addr + 8'd1; end
				else comp <= comp + 2'd1;
			end
			2'd2: begin
				case (dac_addr)
					8'h10: cursor_x[15:8] <= wdata;
					8'h11: cursor_x[7:0]  <= wdata;
					8'h20: dac_cr     <= wdata;
					8'h21: dbl_buf_cr <= wdata;
					8'h22: tst_cr     <= wdata;
					8'h23: pll_cr     <= wdata;
					8'h24: clk_m[0]   <= wdata;
					8'h25: clk_pn[0]  <= wdata;
					8'h27: clk_m[1]   <= wdata;
					8'h28: clk_pn[1]  <= wdata;
					default: ;
				endcase
			end
			default: begin                // the colour table
				case (comp)
					2'd0: begin col0 <= wdata; fill_wr <= 1'b1; end
					2'd1: col1 <= wdata;
					default: col2 <= wdata;
				endcase
				if (comp == 2'd2) begin comp <= 2'd0; dac_addr <= dac_addr + 8'd1; end
				else comp <= comp + 2'd1;
			end
		endcase
	end

	if (rd) begin
		rq_reg <= 8'h00;
		case (rn)
			2'd2: begin
				case (dac_addr)
					8'h20:   rq_reg <= dac_cr;
					8'h23:   rq_reg <= pll_cr;
					8'h40:   rq_reg <= VENDOR;
					default: rq_reg <= 8'h00;
				endcase
			end
			2'd3: begin
				case (comp)
					2'd0: begin rq_ram <= 1'b1; fill_rd <= 1'b1; end
					2'd1: rq_reg <= col1;
					default: rq_reg <= col2;
				endcase
				if (comp == 2'd2) begin comp <= 2'd0; dac_addr <= dac_addr + 8'd1; end
				else comp <= comp + 2'd1;
			end
			default: ;
		endcase
	end

	if (reset) begin
		dac_addr   <= 8'h00;
		dac_cr     <= 8'h00;
		dbl_buf_cr <= 8'h00;
		tst_cr     <= 8'h00;
		pll_cr     <= 8'h00;
		cursor_x   <= 16'h0;
		comp       <= 2'd0;
		col0       <= 8'h00;
		col1       <= 8'h00;
		col2       <= 8'h00;
		rq_reg     <= 8'h00;
		rq_ram     <= 1'b0;
		fill_rd    <= 1'b0;
		fill_wr    <= 1'b0;
		for (int i = 0; i < 2; i++) begin clk_m[i] <= 8'h00; clk_pn[i] <= 8'h00; end
		for (int i = 0; i < 8; i++) begin cur_r[i] <= 8'h00; cur_g[i] <= 8'h00; cur_b[i] <= 8'h00; end
	end
end

endmodule

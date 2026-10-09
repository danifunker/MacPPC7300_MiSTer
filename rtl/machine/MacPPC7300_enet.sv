//============================================================================
//
//  MacPPC7300 - the machine around the CPU
//  The Ethernet bridge's DDR3 side: MACE's frames to and from the Main
//  (support/mac/mac_eth.cpp, the "macppc7300" card), through rings in DDR3
//
//  The window at BASE (64-bit words, the ARM's little-endian):
//    0       magic   "PPCE" in 63-32, the core's epoch in 7-0 (new at each
//                    start: the Main starts over)
//    1       tx_wr   frames the core has put in the transmit ring
//    2       tx_rd   frames the Main has sent
//    3       rx_wr   frames the Main has put in the receive ring
//    4       rx_rd   frames the core has taken
//    5       mac     the guest's address, bytes 0-5; bit 63: valid
//    200+    the transmit ring, 8 slots of 100 words: the length, the bytes
//    A00+    the receive ring, likewise
//  A frame goes as single-word writes, a slot is read as one burst; the
//  control words are polled every 20 us.
//
//  MACE's side (the CPU's clock): a frame buffer each way (2 KB, 64-bit
//  words, byte 0 in bits 7-0), and toggles: tx_go (a frame of tx_len bytes
//  to send), tx_done; rx_avail (a frame of rx_len bytes waits), rx_done.
//
//============================================================================

module MacPPC7300_enet
#(
	parameter logic [31:0] BASE = 32'h3040_0000
)
(
	// the memory clock: the mailbox
	input  logic        clk_h,
	input  logic        reset_h,
	input  logic        on,               // the bridge chosen (taken under reset)
	input  logic        ddr_busy,
	output logic [7:0]  ddr_burstcnt,
	output logic [28:0] ddr_addr,
	input  logic [63:0] ddr_dout,
	input  logic        ddr_dout_ready,
	output logic        ddr_rd,
	output logic [63:0] ddr_din,
	output logic [7:0]  ddr_be,
	output logic        ddr_we,

	// the CPU's clock: MACE
	input  logic        clk,
	input  logic        tx_we,
	input  logic [7:0]  tx_wa,
	input  logic [63:0] tx_wd,
	input  logic        tx_go,
	input  logic [10:0] tx_len,
	output logic        tx_done,
	input  logic [7:0]  rx_ra,
	output logic [63:0] rx_q,
	output logic        rx_avail,
	output logic [10:0] rx_len,
	input  logic        rx_done,
	output logic        link,             // the bridge is up and the Main serves it
	output logic [47:0] mac,              // the Main's address for the guest, while mac_ok
	output logic        mac_ok
);

localparam logic [28:0] W0 = BASE[31:3];

// ---- the frame buffers ------------------------------------------------------------------------
logic [63:0] txb [256];
logic [63:0] rxb [256];
logic [7:0]  t_ra, r_wa;
logic [63:0] t_q;
logic        r_we;
logic [63:0] r_wd;
always_ff @(posedge clk) begin
	if (tx_we) txb[tx_wa] <= tx_wd;
	rx_q <= rxb[rx_ra];
end
always_ff @(posedge clk_h) begin
	t_q <= txb[t_ra];
	if (r_we) rxb[r_wa] <= r_wd;
end

// ---- the crossings ----------------------------------------------------------------------------
logic [2:0]  go_s, rd_s;
logic        go_seen, rd_seen;
logic [10:0] h_txlen;
logic        h_txdone = 1'b0, h_avail = 1'b0;
logic [10:0] h_rxlen;
logic [47:0] h_mac;
logic        h_macok;
logic [2:0]  dn_s, av_s, on_s, mo_s;
always_ff @(posedge clk_h) begin
	go_s <= {go_s[1:0], tx_go};
	rd_s <= {rd_s[1:0], rx_done};
	h_txlen <= tx_len;                    // steady from before tx_go toggles
end
always_ff @(posedge clk) begin
	dn_s <= {dn_s[1:0], h_txdone};
	av_s <= {av_s[1:0], h_avail};
	on_s <= {on_s[1:0], on};
	mo_s <= {mo_s[1:0], h_macok};
	tx_done  <= dn_s[2];
	rx_avail <= av_s[2];
	rx_len   <= h_rxlen;                  // steady from before rx_avail toggles
	link     <= on_s[2] & mo_s[2];         // the Main serves the rings (it has written the address)
	mac_ok   <= mo_s[2];
	if (mo_s[2] && !mac_ok) mac <= h_mac; // steady once valid
end
wire tx_pend = go_s[2] != go_seen;
wire rx_ack  = rd_s[2] != rd_seen;

// ---- the engine -------------------------------------------------------------------------------
typedef enum logic [3:0] {
	E_OFF, E_INIT, E_IDLE, E_POLL, E_POLLW, E_TXW, E_TXPTR, E_RXLEN, E_RXLENW, E_RXDATA, E_RXDATAW, E_RXPTR
} e_t;
e_t          es;
logic [7:0]  epoch = 8'd0;
logic [2:0]  ik;                        // the start's writes
logic [31:0] tx_wr, tx_rd, rx_wr, rx_rd;
logic        rx_pend;                   // a frame is in rxb, not yet taken
logic [15:0] poll;
logic [7:0]  nb, kb;                    // beats in a transfer, beats done
logic [10:0] len;
logic        t_ok;                      // t_q holds txb[t_ra]

wire  [28:0] tx_slot = W0 + 29'h200 + {18'd0, tx_wr[2:0], 8'd0};
wire  [28:0] rx_slot = W0 + 29'hA00 + {18'd0, rx_rd[2:0], 8'd0};
wire  [31:0] tx_used = tx_wr - tx_rd;

// one word written
task automatic put(input logic [28:0] a, input logic [63:0] d);
	ddr_addr     <= a;
	ddr_din      <= d;
	ddr_be       <= 8'hFF;
	ddr_burstcnt <= 8'd1;
	ddr_we       <= 1'b1;
endtask
// n words read
task automatic get(input logic [28:0] a, input logic [7:0] n);
	ddr_addr     <= a;
	ddr_burstcnt <= n;
	ddr_rd       <= 1'b1;
	kb           <= 8'd0;
endtask

always_ff @(posedge clk_h) begin
	r_we <= 1'b0;
	if (ddr_we && !ddr_busy) ddr_we <= 1'b0;
	if (ddr_rd && !ddr_busy) ddr_rd <= 1'b0;
	if (poll != 16'd0) poll <= poll - 16'd1;

	case (es)
		E_OFF: if (on) begin
			epoch <= epoch + 8'd1;
			ik    <= 3'd0;
			tx_wr <= '0; tx_rd <= '0; rx_wr <= '0; rx_rd <= '0;
			rx_pend <= 1'b0;
			es    <= E_INIT;
		end
		// the counters, then the magic
		E_INIT: if (!ddr_we) begin
			case (ik)
				3'd0, 3'd1, 3'd2, 3'd3: put(W0 + {26'd0, ik} + 29'd1, 64'd0);
				default: put(W0, {32'h5050_4345, 24'd0, epoch});
			endcase
			ik <= ik + 3'd1;
			if (ik == 3'd4) es <= E_IDLE;
		end

		E_IDLE: if (!ddr_we && !ddr_rd) begin
			if (rx_ack) begin                           // the frame taken: the slot back to the Main
				rd_seen <= rd_s[2];
				rx_rd   <= rx_rd + 32'd1;
				rx_pend <= 1'b0;
				put(W0 + 29'd4, {32'd0, rx_rd + 32'd1});
			end
			else if (tx_pend && tx_used < 32'd8) begin  // a frame into the ring: its length, its words
				len <= h_txlen;
				nb  <= 8'((h_txlen + 11'd7) >> 3);
				kb  <= 8'd0;
				t_ra <= 8'd0;
				t_ok <= 1'b0;
				put(tx_slot, {53'd0, h_txlen});
				es  <= E_TXW;
			end
			else if (poll == 16'd0) begin
				poll <= 16'd2000;
				get(W0 + 29'd2, 8'd4);                  // tx_rd, rx_wr, rx_rd, mac
				es   <= E_POLLW;
			end
		end
		E_POLLW: if (ddr_dout_ready) begin
			kb <= kb + 8'd1;
			case (kb)
				8'd0: tx_rd <= ddr_dout[31:0];
				8'd1: rx_wr <= ddr_dout[31:0];
				8'd3: begin
					h_mac   <= ddr_dout[47:0];
					h_macok <= ddr_dout[63];
					es      <= (!rx_pend && rx_wr != rx_rd) ? E_RXLEN : E_IDLE;
				end
				default: ;
			endcase
		end

		E_TXW: if (!ddr_we) begin                       // word kb: t_q has it a clock after t_ra
			if (kb == nb) begin
				tx_wr <= tx_wr + 32'd1;
				put(W0 + 29'd1, {32'd0, tx_wr + 32'd1});
				es <= E_TXPTR;
			end
			else if (t_ok) begin
				put(tx_slot + 29'd1 + {21'd0, kb}, t_q);
				kb   <= kb + 8'd1;
				t_ra <= kb + 8'd1;
				t_ok <= 1'b0;
			end
			else t_ok <= 1'b1;
		end
		E_TXPTR: if (!ddr_we) begin
			go_seen  <= go_s[2];
			h_txdone <= ~h_txdone;
			es <= E_IDLE;
		end

		E_RXLEN: begin
			get(rx_slot, 8'd1);
			es <= E_RXLENW;
		end
		E_RXLENW: if (ddr_dout_ready) begin
			len <= (ddr_dout[15:0] > 16'd1536) ? 11'd1536 : ddr_dout[10:0];
			es  <= E_RXDATA;
		end
		E_RXDATA: begin
			if (len == 11'd0) es <= E_RXPTR;
			else begin
				get(rx_slot + 29'd1, 8'((len + 11'd7) >> 3));
				r_wa <= 8'hFF;
				es   <= E_RXDATAW;
			end
		end
		E_RXDATAW: if (ddr_dout_ready) begin
			r_we <= 1'b1;
			r_wa <= r_wa + 8'd1;
			r_wd <= ddr_dout;
			kb   <= kb + 8'd1;
			if (kb + 8'd1 == 8'((len + 11'd7) >> 3)) es <= E_RXPTR;
		end
		E_RXPTR: begin                                  // the frame handed to MACE
			h_rxlen <= len;
			h_avail <= ~h_avail;
			rx_pend <= 1'b1;
			es <= E_IDLE;
		end
		default: es <= E_OFF;
	endcase

	if (reset_h || !on) begin
		es      <= E_OFF;
		ddr_we  <= 1'b0;
		ddr_rd  <= 1'b0;
		h_macok <= 1'b0;
		poll    <= 16'd0;
		go_seen <= go_s[2];
		rd_seen <= rd_s[2];
	end
end

endmodule

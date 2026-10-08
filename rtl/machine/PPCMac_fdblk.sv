//============================================================================
//
//  PPCMac - the machine around the CPU
//  The floppy disk image: hps_io's block slot 6, read for PPCMac_swim3
//
//  An image is told by its size, as dingusppc's floppyimg.cpp tells a raw
//  one, and a DiskCopy 4.2 image the same way (its 84-byte header first,
//  any tag bytes after the data):
//      409,600  400K GCR, one side       409,684  419,284  (DiskCopy)
//      819,200  800K GCR, two sides      819,284  838,484
//      737,280  720K MFM                 737,364
//    1,474,560  1440K MFM                1,474,644
//  Any other size up to 2 MB: its first block is read, and a DiskCopy 4.2
//  header there (signature 0100, a format 0-3, that format's data size)
//  makes it a disk of that format; anything else (0: the image taken out)
//  is no disk.
//
//  The memory clock's side (hps_io's): a mount sets the disk's kind and
//  toggles m_t; a request (rq_t toggled, rq_lba the image's 512-byte
//  sector) reads that block, or with a DiskCopy image that block and the
//  next (the sector starts 84 bytes into the first), into a buffer of 1,024
//  bytes that the CPU's clock reads (ra, q a clock later), then toggles dn_t.
//  Read only: nothing is ever written to the image.
//
//============================================================================

module PPCMac_fdblk
(
	input  logic        clk_m,
	input  logic        reset_m,

	// hps_io's slot 6
	input  logic        img_mounted,
	input  logic [63:0] img_size,
	input  logic        img_readonly,
	output logic [31:0] sd_lba,
	output logic        sd_rd,
	output logic [5:0]  sd_blk_cnt,
	input  logic        sd_ack,
	input  logic [13:0] sd_buff_addr,
	input  logic [7:0]  sd_buff_dout,
	input  logic        sd_buff_wr,

	// the disk, for the CPU's clock: info stable while m_t is unchanged
	output logic        m_t,
	output logic        m_ok,
	output logic [1:0]  m_fmt,           // 0 400K, 1 800K, 2 720K, 3 1440K
	output logic        m_dc42,
	output logic        m_ro,

	// a sector, read in the CPU's clock
	input  logic        clk,
	input  logic        rq_t,
	input  logic [11:0] rq_lba,
	output logic        dn_t,
	input  logic [9:0]  ra,
	output logic [7:0]  q
);

logic [7:0] buffer [1024];
always_ff @(posedge clk_m)
	if (sd_buff_wr & sd_ack & ~sd_buff_addr[13] & ~sd_buff_addr[12] & ~sd_buff_addr[11] & ~sd_buff_addr[10])
		buffer[sd_buff_addr[9:0]] <= sd_buff_dout;
always_ff @(posedge clk) q <= buffer[ra];

logic [2:0] rq_s;
logic       rq_h;                       // the request toggle as last taken
logic       ack_q, busy;
// any other size up to 2 MB: block 0 is read for a DiskCopy 4.2 header (its
// signature 0100 at 52, a format 0-3 at 50 and that format's size at 40)
logic       pr_want, probe;
logic [7:0] h_fmt, h_m0, h_m1;
logic [31:0] h_ds;
logic [31:0] h_need;
always_comb begin
	case (h_fmt[1:0])
		2'd0:    h_need = 32'd409600;
		2'd1:    h_need = 32'd819200;
		2'd2:    h_need = 32'd737280;
		default: h_need = 32'd1474560;
	endcase
end
assign sd_blk_cnt = {5'd0, m_dc42 & ~probe};

always_ff @(posedge clk_m) begin
	rq_s  <= {rq_s[1:0], rq_t};
	ack_q <= sd_ack;

	if (img_mounted) begin
		m_ok   <= 1'b1;
		m_dc42 <= 1'b0;
		m_ro   <= img_readonly;
		m_t    <= ~m_t;
		case (img_size)
			64'd409600:  m_fmt <= 2'd0;
			64'd819200:  m_fmt <= 2'd1;
			64'd737280:  m_fmt <= 2'd2;
			64'd1474560: m_fmt <= 2'd3;
			64'd409684, 64'd419284: begin m_fmt <= 2'd0; m_dc42 <= 1'b1; end
			64'd819284, 64'd838484: begin m_fmt <= 2'd1; m_dc42 <= 1'b1; end
			64'd737364:  begin m_fmt <= 2'd2; m_dc42 <= 1'b1; end
			64'd1474644: begin m_fmt <= 2'd3; m_dc42 <= 1'b1; end
			default: begin
				m_ok <= 1'b0;
				if (img_size > 64'd84 && img_size < 64'd2097152) begin
					m_t     <= m_t;         // the kind is told once the header is read
					pr_want <= 1'b1;
				end
			end
		endcase
	end

	if (!busy && pr_want) begin
		pr_want <= 1'b0;
		probe   <= 1'b1;
		h_m0    <= 8'h00;
		sd_lba  <= 32'd0;
		sd_rd   <= 1'b1;
		busy    <= 1'b1;
	end
	else if (!busy && rq_s[2] != rq_h) begin
		rq_h   <= rq_s[2];
		sd_lba <= {20'd0, rq_lba};
		sd_rd  <= 1'b1;
		busy   <= 1'b1;
	end
	if (sd_ack) sd_rd <= 1'b0;
	if (probe && sd_ack && sd_buff_wr) begin
		case (sd_buff_addr)
			14'h40: h_ds[31:24] <= sd_buff_dout;
			14'h41: h_ds[23:16] <= sd_buff_dout;
			14'h42: h_ds[15:8]  <= sd_buff_dout;
			14'h43: h_ds[7:0]   <= sd_buff_dout;
			14'h50: h_fmt <= sd_buff_dout;
			14'h52: h_m0  <= sd_buff_dout;
			14'h53: h_m1  <= sd_buff_dout;
			default: ;
		endcase
	end
	if (busy && ack_q && !sd_ack) begin
		busy <= 1'b0;
		if (probe) begin
			probe  <= 1'b0;
			m_ok   <= h_m0 == 8'h01 && h_m1 == 8'h00 && h_fmt < 8'd4 && h_ds == h_need;
			m_fmt  <= h_fmt[1:0];
			m_dc42 <= 1'b1;
			m_t    <= ~m_t;
		end
		else dn_t <= ~dn_t;
	end

	if (reset_m) begin
		sd_rd   <= 1'b0;
		busy    <= 1'b0;
		probe   <= 1'b0;
		pr_want <= 1'b0;
	end
end

initial begin
	m_t    = 1'b0;
	m_ok   = 1'b0;
	m_fmt  = 2'd3;
	m_dc42 = 1'b0;
	m_ro   = 1'b1;
	dn_t   = 1'b0;
	rq_h   = 1'b0;
	rq_s   = 3'd0;
	sd_lba = 32'd0;
	probe  = 1'b0;
	pr_want = 1'b0;
	h_fmt  = 8'd0;
	h_m0   = 8'd0;
	h_m1   = 8'd0;
	h_ds   = 32'd0;
end

endmodule

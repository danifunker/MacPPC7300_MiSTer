// The SCSI bench's top: Grand Central (MacPPC7300_gc: MESH, its DMA channel;
// AWACS and its sound-out channel) and the disks (MacPPC7300_scsidisk) on the internal bus, wired as
// MacPPC7300_machine wires them, and the floppy's image (MacPPC7300_fdblk) for
// SWIM3; Grand Central's register port, its DMA port and the hps_io side
// are the bench's. The SCSI controllers' 25 MHz tick is made here by phase
// accumulation, as in MacPPC7300_machine.

module scsi_tb_top
#(
	parameter int unsigned CPU_HZ  = 65_000_000,
	parameter int unsigned SCSI_HZ = 25_000_000
)
(
	input  logic         clk,
	input  logic         reset,

	// Grand Central's registers
	input  logic         sel,
	input  logic         we,
	input  logic [16:2]  addr,
	input  logic [3:0]   be,
	input  logic [31:0]  wdata,
	output logic [31:0]  rdata,
	output logic         irq,

	// the DMA port
	output logic         dm_req,
	output logic         dm_we,
	output logic         dm_line,
	output logic [31:2]  dm_addr,
	output logic [3:0]   dm_be,
	output logic [255:0] dm_wdata,
	input  logic         dm_ack,
	input  logic [255:0] dm_rdata,

	// the targets' hps_io side
	input  logic         clk_h,
	input  logic [5:0]   img_mounted,
	input  logic [63:0]  img_size,
	output logic [31:0]  sd_lba,
	output logic [5:0]   sd_rd,
	output logic [5:0]   sd_wr,
	output logic [5:0]   sd_blk_cnt,
	input  logic [5:0]   sd_ack,
	input  logic [13:0]  sd_buff_addr,
	input  logic [7:0]   sd_buff_dout,
	output logic [7:0]   sd_buff_din,
	input  logic         sd_buff_wr,
	output logic [15:0]  cd_left,
	output logic [15:0]  cd_right,
	// AWACS's samples (DMA channel 8)
	output logic [15:0]  snd_left,
	output logic [15:0]  snd_right,
	// the floppy's slot (6)
	input  logic         fd_mounted,
	output logic [31:0]  fd_lba,
	output logic         fd_rd,
	output logic [5:0]   fd_blk_cnt,
	input  logic         fd_ack,

	// the bus, to watch
	output logic         bus_bsy, bus_sel, bus_req, bus_ack, bus_atn,
	output logic [2:0]   bus_phase,
	output logic [7:0]   bus_db
);

logic [31:0] scsi_acc;
logic        scsi_tick;
always_ff @(posedge clk) begin
	scsi_tick <= 1'b0;
	if (scsi_acc + SCSI_HZ >= CPU_HZ) begin
		scsi_acc  <= scsi_acc + SCSI_HZ - CPU_HZ;
		scsi_tick <= 1'b1;
	end
	else scsi_acc <= scsi_acc + SCSI_HZ;
	if (reset) begin scsi_acc <= 32'h0; scsi_tick <= 1'b0; end
end

// AWACS's 88,200 Hz, as MacPPC7300_machine makes it
logic [31:0] snd_acc;
logic        snd_tick;
always_ff @(posedge clk) begin
	snd_tick <= 1'b0;
	if (snd_acc + 32'd88_200 >= CPU_HZ) begin
		snd_acc  <= snd_acc + 32'd88_200 - CPU_HZ;
		snd_tick <= 1'b1;
	end
	else snd_acc <= snd_acc + 32'd88_200;
	if (reset) begin snd_acc <= 32'h0; snd_tick <= 1'b0; end
end

// the floppy's microseconds, 16 times as fast as the CPU's clock would make them
logic [1:0] us_div = 2'd0;
always_ff @(posedge clk) us_div <= us_div + 2'd1;
wire us_tick = us_div == 2'd0;

logic        fd_m_t, fd_m_ok, fd_m_dc42, fd_rq_t, fd_dn_t;
logic [1:0]  fd_m_fmt;
logic [11:0] fd_rq_lba;
logic [9:0]  fd_ra;
logic [7:0]  fd_q;

logic       mesh_rst, mesh_bsy, mesh_sel, mesh_atn, mesh_ack, mesh_req, mesh_msg, mesh_cd, mesh_io;
logic [7:0] mesh_db;
logic       t_bsy, t_req, t_msg, t_cd, t_io;
logic [7:0] t_db;
wire        scsi_rst = mesh_rst;
wire        scsi_bsy = mesh_bsy | t_bsy;
wire        scsi_sel = mesh_sel;
wire        scsi_atn = mesh_atn;
wire        scsi_ack = mesh_ack;
wire        scsi_req = mesh_req | t_req;
wire        scsi_msg = mesh_msg | t_msg;
wire        scsi_cd  = mesh_cd  | t_cd;
wire        scsi_io  = mesh_io  | t_io;
wire [7:0]  scsi_db  = mesh_db  | t_db;

assign bus_bsy = scsi_bsy;
assign bus_sel = scsi_sel;
assign bus_req = scsi_req;
assign bus_ack = scsi_ack;
assign bus_atn = scsi_atn;
assign bus_phase = {scsi_msg, scsi_cd, scsi_io};
assign bus_db = scsi_db;

/* verilator lint_off PINCONNECTEMPTY */
MacPPC7300_gc #(.SCSI_HZ(SCSI_HZ)) gc (
	.clk, .reset, .via_tick(1'b0), .rtxc_tick(1'b0), .scsi_tick, .us_tick, .snd_tick,
	.sel, .we, .addr, .be, .wdata, .rdata, .irq,
	.cuda_treq(1'b1), .cuda_cb1(1'b1), .cb2(1'b1), .via_tip(), .via_byteack(), .via_cb2_oe(), .via_cb2_out(),
	.modem_txd(), .modem_rxd(1'b1), .modem_cts(1'b0), .modem_rts(),
	.net_link(1'b0), .net_tx_we(), .net_tx_wa(), .net_tx_wd(), .net_tx_go(), .net_tx_len(), .net_tx_done(1'b0),
	.net_rx_ra(), .net_rx_q(64'd0), .net_rx_avail(1'b0), .net_rx_len(11'd0), .net_rx_done(), .net_mac(48'd0),
	.net_mac_ok(1'b0), .nv_ld_we(1'b0), .nv_ld_re(1'b0), .nv_ld_addr(13'h0), .nv_ld_data(8'h0),
	.nv_ld_rack(), .nv_ld_q(), .nv_wr_cpu(),
	.ctl_irq(1'b0), .nmi(1'b0),
	.mesh_rst, .mesh_bsy, .mesh_sel, .mesh_atn, .mesh_ack, .mesh_req, .mesh_msg, .mesh_cd, .mesh_io, .mesh_db,
	.scsi_rst, .scsi_bsy, .scsi_sel, .scsi_atn, .scsi_ack, .scsi_req, .scsi_msg, .scsi_cd, .scsi_io, .scsi_db,
	.dm_req, .dm_we, .dm_line, .dm_addr, .dm_be, .dm_wdata, .dm_ack, .dm_rdata,
	.snd_left, .snd_right, .snd_frame(),
	.dac_cr(), .dbl_buf_cr(), .cursor_x(), .cursor_clut(), .clk_v(clk_h), .clut_index(24'h0), .clut_rgb(),
	.dfin(), .dfin_ch(), .dfin_type(), .dfin_info(), .itr_ev(), .itr_st(), .itr8_ev(), .itr8_st(),
	.fd_m_t, .fd_m_ok, .fd_m_fmt, .fd_m_dc42, .fd_rq_t, .fd_rq_lba, .fd_dn_t, .fd_ra, .fd_q
);

MacPPC7300_fdblk fdblk (
	.clk_m(clk_h), .reset_m(reset),
	.img_mounted(fd_mounted), .img_size, .img_readonly(1'b0),
	.sd_lba(fd_lba), .sd_rd(fd_rd), .sd_blk_cnt(fd_blk_cnt), .sd_ack(fd_ack),
	.sd_buff_addr, .sd_buff_dout, .sd_buff_wr,
	.m_t(fd_m_t), .m_ok(fd_m_ok), .m_fmt(fd_m_fmt), .m_dc42(fd_m_dc42), .m_ro(),
	.clk, .rq_t(fd_rq_t), .rq_lba(fd_rq_lba), .dn_t(fd_dn_t), .ra(fd_ra), .q(fd_q)
);

MacPPC7300_scsidisk #(.CLK_HZ(CPU_HZ)) disks (
	.clk, .reset,
	.t_bsy, .t_req, .t_msg, .t_cd, .t_io, .t_db,
	.b_rst(scsi_rst), .b_bsy(scsi_bsy), .b_sel(scsi_sel), .b_atn(scsi_atn), .b_ack(scsi_ack), .b_db(scsi_db),
	.clk_h, .img_mounted, .img_size, .img_readonly(1'b0),
	.sd_lba, .sd_rd, .sd_wr, .sd_blk_cnt, .sd_ack, .sd_buff_addr, .sd_buff_dout, .sd_buff_din, .sd_buff_wr,
	.busy(), .cd_left, .cd_right, .tr_ev(), .tr_rec()
);
/* verilator lint_on PINCONNECTEMPTY */

endmodule

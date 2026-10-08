// The SCSI bench's top: Grand Central (PPCMac_gc: MESH, its DMA channel)
// and the disks (PPCMac_scsidisk) on the internal bus, wired as
// PPCMac_machine wires them; Grand Central's register port, its DMA port
// and the disks' hps_io side are the bench's. The SCSI controllers' 25 MHz
// tick is made here by phase accumulation, as in PPCMac_machine.

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
PPCMac_gc #(.SCSI_HZ(SCSI_HZ)) gc (
	.clk, .reset, .via_tick(1'b0), .rtxc_tick(1'b0), .scsi_tick, .us_tick(1'b0), .snd_tick(1'b0),
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
	.snd_left(), .snd_right(),
	.dac_cr(), .dbl_buf_cr(), .cursor_x(), .cursor_clut(), .clk_v(clk_h), .clut_index(8'h0), .clut_rgb()
);

PPCMac_scsidisk #(.CLK_HZ(CPU_HZ)) disks (
	.clk, .reset,
	.t_bsy, .t_req, .t_msg, .t_cd, .t_io, .t_db,
	.b_rst(scsi_rst), .b_bsy(scsi_bsy), .b_sel(scsi_sel), .b_atn(scsi_atn), .b_ack(scsi_ack), .b_db(scsi_db),
	.clk_h, .img_mounted, .img_size, .img_readonly(1'b0),
	.sd_lba, .sd_rd, .sd_wr, .sd_blk_cnt, .sd_ack, .sd_buff_addr, .sd_buff_dout, .sd_buff_din, .sd_buff_wr,
	.busy(), .cd_left, .cd_right
);
/* verilator lint_on PINCONNECTEMPTY */

endmodule

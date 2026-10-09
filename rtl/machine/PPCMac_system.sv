//============================================================================
//
//  PPCMac - the machine around the CPU
//  The CPU, the machine and the clock crossing to memory, as one block
//
//    DSPPC604 --(memory port)--> PPCMac_machine --(RAM, ROM)--> PPCMac_l2 --> DSPPC604_memcdc --> b_*
//
//  Everything left of the crossing runs in the CPU's clock; b_* is the same
//  port protocol in the memory's clock, addressed by SDRAM offset, for the
//  SDRAM controller (or the test bench's memory). The MiSTer top and the
//  test bench both instantiate this block, so the bench runs the machine
//  exactly as the FPGA does.
//
//  The CPU's retirement trace and its memory port are brought out for the
//  test bench and the debug readout; a build that does not use them leaves
//  them unconnected.
//
//============================================================================

module PPCMac_system
#(
	parameter int unsigned CPU_HZ   = 65_000_000,
	parameter int unsigned TB_HZ    = 12_500_000,
	parameter int unsigned SDRAM_MB = 128,
	parameter int unsigned L2_KB    = 128,          // the L2 cache (PPCMac_l2)
	parameter int unsigned CUDA_FAST_BOOT = 0       // 1: the test bench's (PPCMac_cuda FAST_BOOT)
)
(
	input  logic         clk,             // the CPU's clock
	input  logic         reset,           // in the CPU's clock: the machine's reset
	output logic         cpu_in_reset,    // the CPU is held in reset (by reset or by Cuda)
	output logic         power_wake,      // shut down, then the power key: the machine wants a reset
	input  logic [31:0]  reset_pc,
	input  logic [7:0]   ram_mb,          // installed RAM, at most SDRAM_MB - 4
	input  logic         boot_memtest,    // the memory test in place of the ROM
	input  logic         l2_on,           // the L2 cache in the memory path (quasi-static, taken under reset)

	// memory, in the memory's clock, by SDRAM offset
	input  logic         clk_b,
	input  logic         reset_b,
	output logic         b_req,
	output logic         b_we,
	output logic         b_line,
	output logic [31:2]  b_addr,
	output logic [3:0]   b_be,
	output logic [255:0] b_wdata,
	input  logic         b_ack,
	input  logic [255:0] b_rdata,

	// the CPU's memory port, as the machine sees it
	output logic         cpu_req,
	output logic         cpu_we,
	output logic         cpu_line,
	output logic [31:2]  cpu_addr,
	output logic [3:0]   cpu_be,
	output logic [255:0] cpu_wdata,
	output logic         cpu_ack,
	output logic [255:0] cpu_rdata,
	output logic         cpu_irq,
	output logic         cpu_tb_tick,

	// the modem port (the ESCC's channel A), 1 when idle; asynchronous in
	output logic         modem_txd,
	input  logic         modem_rxd,
	input  logic         modem_cts,       // asynchronous: 0 clear to send
	output logic         modem_rts,       // 1 while a received byte waits

	// the sound AWACS plays, signed, in the CPU's clock, changing at its
	// frame rate (the framework's audio input takes a value seen twice)
	output logic [15:0]  snd_left,
	output logic [15:0]  snd_right,

	// Grand Central's NVRAM written from outside, a byte a cycle in the
	// CPU's clock, while reset is held; or read from outside (nv_ld_re held
	// until nv_ld_rack, the byte in nv_ld_q then); nv_wr_cpu marks the CPU's
	// writes (the save to the SD card)
	input  logic         nv_ld_we,
	input  logic         nv_ld_re,
	input  logic [12:0]  nv_ld_addr,
	input  logic [7:0]   nv_ld_data,
	output logic         nv_ld_rack,
	output logic [7:0]   nv_ld_q,
	output logic         nv_wr_cpu,

	// the monitor: its AppleSense codes
	input  logic [2:0]   mon_std,
	input  logic [5:0]   mon_ext,

	// the keyboard, the mouse and the game controller, as hps_io gives them
	// (the ADB devices synchronise them)
	input  logic [10:0]  ps2_key,
	input  logic [24:0]  ps2_mouse,
	input  logic [51:0]  joy,

	// the date and time for Cuda's clock (seconds since 1904), steady in the
	// CPU's clock while clock_ok; set once as the machine starts
	input  logic         clock_ok,
	input  logic [31:0]  clock_secs,

	// the SCSI targets' images: hps_io's block devices (0, 1 the disks, 3 the
	// Toolbox, 4 the CD-ROM, 5 the CD changer; 2 not driven here), in the
	// memory's clock
	input  logic [5:0]   img_mounted,
	input  logic [63:0]  img_size,
	input  logic         img_readonly,
	output logic [31:0]  sd_lba,
	output logic [5:0]   sd_rd,
	output logic [5:0]   sd_wr,
	output logic [5:0]   sd_blk_cnt,
	input  logic [5:0]   sd_ack,
	input  logic [13:0]  sd_buff_addr,
	input  logic [7:0]   sd_buff_dout,
	output logic [7:0]   sd_buff_din,
	input  logic         sd_buff_wr,
	output logic         disk_busy,
	output logic signed [15:0] cd_left,  // the CD's audio, in the CPU's clock
	output logic signed [15:0] cd_right,
	// the floppy disk's image: hps_io's slot 6 (the other signals shared)
	input  logic         fd_mounted,
	output logic [31:0]  fd_lba,
	output logic         fd_rd,
	output logic [5:0]   fd_blk_cnt,
	input  logic         fd_ack,

	// the VRAM's accesses as the picture side answers them, in the memory's
	// clock (for the test bench)
	output logic         vram_ack,
	output logic         vram_we,
	output logic         vram_line,
	output logic [21:2]  vram_addr,
	output logic [255:0] vram_rdata,

	// a DMA write to RAM as it goes into memory (for the test bench)
	output logic         dma_wr,
	output logic         dma_wr_line,
	output logic [31:2]  dma_wr_addr,
	output logic [3:0]   dma_wr_be,
	output logic [255:0] dma_wr_data,

	// the network bridge chosen (the OSD's Ethernet, taken under reset), in the memory's clock
	input  logic         net_on,
	// the trace also takes MESH's accesses (quasi-static, in the CPU's clock)
	input  logic         tr_mesh,

	// the VRAM and the network's rings in DDR3 (the framework's DDRAM port), in the memory's clock
	input  logic         ddr_busy,
	output logic [7:0]   ddr_burstcnt,
	output logic [28:0]  ddr_addr,
	input  logic [63:0]  ddr_dout,
	input  logic         ddr_dout_ready,
	output logic         ddr_rd,
	output logic [63:0]  ddr_din,
	output logic [7:0]   ddr_be,
	output logic         ddr_we,

	// the Control video's picture, in the memory's clock
	output logic         vid_ce,
	output logic [7:0]   vid_r,
	output logic [7:0]   vid_g,
	output logic [7:0]   vid_b,
	output logic         vid_hs,
	output logic         vid_vs,
	output logic         vid_hblank,
	output logic         vid_vblank,

	// the machine's debug registers (the memory test's report)
	output logic [31:0]  dbg_status,
	output logic [31:0]  dbg_passes,
	output logic [31:0]  dbg_errors,
	output logic [31:0]  dbg_first,

	// the CPU's retirement trace (see DSPPC604)
	output logic         trace_valid,
	output logic         trace_last,
	output logic [31:0]  trace_pc,
	output logic [31:0]  trace_insn,
	output logic         trace_reg_we,
	output logic [6:0]   trace_reg_idx,
	output logic [63:0]  trace_reg_val,
	output logic [31:0]  trace_cr,
	output logic [31:0]  trace_xer,
	output logic [31:0]  trace_lr,
	output logic [31:0]  trace_ctr,
	output logic [31:0]  trace_fpscr,
	output logic [31:0]  trace_msr,
	output logic         trace_dreq,
	output logic         trace_dwe,
	output logic [2:0]   trace_dkind,
	output logic [31:2]  trace_daddr,
	output logic [3:0]   trace_dbe,
	output logic [31:0]  trace_dwdata
);

logic         c_req, c_we, c_line, c_ack;
logic [31:2]  c_addr;
logic [3:0]   c_be;
logic [255:0] c_wdata, c_rdata;
logic         m_req, m_we, m_line, m_ack;
logic [31:2]  m_addr;
logic [3:0]   m_be;
logic [255:0] m_wdata, m_rdata;
logic         ext_irq, tb_tick;
logic         snoop_req, snoop_we, snoop_ack;   // the DMA channels' lines, through the caches
logic [31:5]  snoop_addr;
logic         cuda_reset;         // Cuda holds the CPU in reset (PPCMac_cuda)
wire          cpu_reset = reset | cuda_reset;

assign cpu_in_reset = cpu_reset;

DSPPC604 cpu (
	.clk, .reset(cpu_reset), .reset_pc,
	.ext_irq, .tb_tick,
	.mem_req(c_req), .mem_we(c_we), .mem_line(c_line), .mem_addr(c_addr), .mem_be(c_be),
	.mem_wdata(c_wdata), .mem_ack(c_ack), .mem_rdata(c_rdata),
	.snoop_req, .snoop_we, .snoop_addr, .snoop_ack,
	.trace_valid, .trace_last, .trace_pc, .trace_insn, .trace_reg_we, .trace_reg_idx, .trace_reg_val,
	.trace_cr, .trace_xer, .trace_lr, .trace_ctr, .trace_fpscr, .trace_msr,
	.trace_dreq, .trace_dwe, .trace_dkind, .trace_daddr, .trace_dbe, .trace_dwdata
);

// the VRAM's path and the video registers, between the machine and the picture side
logic         v_req, v_we, v_line, v_ack;
logic [21:2]  v_addr;
logic [3:0]   v_be;
logic [255:0] v_wdata, v_rdata;
logic         vb_req, vb_we, vb_line, vb_ack;
logic [31:2]  vb_addr;
logic [3:0]   vb_be;
logic [255:0] vb_wdata, vb_rdata;
logic         timing_on, hs_pos, vs_pos, vbl_start_tog, vbl_end_tog;
logic [191:0] sw_params, cursor_clut;
logic [21:0]  fb_base;
logic [14:0]  row_words;
logic [7:0]   dac_cr, dbl_buf_cr, athens_d2, athens_n2, athens_p2;
logic [23:0]  clut_index;
logic [15:0]  cursor_x;
logic [23:0]  clut_rgb;
logic         net_link, net_tx_we, net_tx_go, net_tx_done, net_rx_avail, net_rx_done, net_mac_ok;
logic [7:0]   net_tx_wa, net_rx_ra;
logic [63:0]  net_tx_wd, net_rx_q;
logic [10:0]  net_tx_len, net_rx_len;
logic [47:0]  net_mac;
logic         scsi_tr_ev;
logic [255:0] scsi_tr_rec;

PPCMac_machine #(.CPU_HZ(CPU_HZ), .TB_HZ(TB_HZ), .SDRAM_MB(SDRAM_MB), .CUDA_FAST_BOOT(CUDA_FAST_BOOT)) machine (
	.clk, .reset, .ram_mb, .boot_memtest,
	.c_req, .c_we, .c_line, .c_addr, .c_be, .c_wdata, .c_ack, .c_rdata,
	.m_req, .m_we, .m_line, .m_addr, .m_be, .m_wdata, .m_ack, .m_rdata,
	.ext_irq, .tb_tick, .cpu_reset(cuda_reset), .power_wake,
	.snoop_req, .snoop_we, .snoop_addr, .snoop_ack,
	.img_mounted, .img_size, .img_readonly, .sd_lba, .sd_rd, .sd_wr, .sd_blk_cnt, .sd_ack,
	.sd_buff_addr, .sd_buff_dout, .sd_buff_din, .sd_buff_wr, .disk_busy, .cd_left, .cd_right,
	.fd_mounted, .fd_lba, .fd_rd, .fd_blk_cnt, .fd_ack,
	.dma_wr, .dma_wr_line, .dma_wr_addr, .dma_wr_be, .dma_wr_data,
	.modem_txd, .modem_rxd, .modem_cts, .modem_rts, .snd_left, .snd_right,
	.net_link, .net_tx_we, .net_tx_wa, .net_tx_wd, .net_tx_go, .net_tx_len, .net_tx_done,
	.net_rx_ra, .net_rx_q, .net_rx_avail, .net_rx_len, .net_rx_done, .net_mac, .net_mac_ok,
	.nv_ld_we, .nv_ld_re, .nv_ld_addr, .nv_ld_data, .nv_ld_rack, .nv_ld_q, .nv_wr_cpu,
	.mon_std, .mon_ext, .ps2_key, .ps2_mouse, .joy, .clock_ok, .clock_secs,
	.v_req, .v_we, .v_line, .v_addr, .v_be, .v_wdata, .v_ack, .v_rdata,
	.timing_on, .sw_params, .fb_base, .row_words, .hs_pos, .vs_pos, .dac_cr, .dbl_buf_cr,
	.cursor_x, .cursor_clut, .athens_d2, .athens_n2, .athens_p2, .vbl_start_tog, .vbl_end_tog,
	.clk_v(clk_b), .clut_index, .clut_rgb,
	.dbg_status, .dbg_passes, .dbg_errors, .dbg_first,
	.tr_mesh, .tr_ev(scsi_tr_ev), .tr_rec(scsi_tr_rec)
);

DSPPC604_memcdc vcdc (
	.clk_a(clk), .reset_a(reset),
	.a_req(v_req), .a_we(v_we), .a_line(v_line), .a_addr({10'h0, v_addr}), .a_be(v_be), .a_wdata(v_wdata),
	.a_ack(v_ack), .a_rdata(v_rdata),
	.clk_b, .reset_b,
	.b_req(vb_req), .b_we(vb_we), .b_line(vb_line), .b_addr(vb_addr), .b_be(vb_be), .b_wdata(vb_wdata),
	.b_ack(vb_ack), .b_rdata(vb_rdata)
);

// ---- the DDR3 port: the video first, then the network's rings ----
logic        va_busy, va_dout_ready, va_rd, va_we, na_busy, na_dout_ready, na_rd, na_we;
logic [7:0]  va_burstcnt, va_be, na_burstcnt, na_be;
logic [28:0] va_addr, na_addr;
logic [63:0] va_din, na_din;

PPCMac_ddrarb ddrarb (
	.clk(clk_b), .reset(reset_b),
	.a_busy(va_busy), .a_burstcnt(va_burstcnt), .a_addr(va_addr), .a_dout_ready(va_dout_ready),
	.a_rd(va_rd), .a_din(va_din), .a_be(va_be), .a_we(va_we),
	.b_busy(na_busy), .b_burstcnt(na_burstcnt), .b_addr(na_addr), .b_dout_ready(na_dout_ready),
	.b_rd(na_rd), .b_din(na_din), .b_be(na_be), .b_we(na_we),
	.ddr_busy, .ddr_burstcnt, .ddr_addr, .ddr_dout_ready, .ddr_rd, .ddr_din, .ddr_be, .ddr_we
);

// ---- B: the network's rings first, then the trace ----
logic        ne_busy, ne_dout_ready, ne_rd, ne_we, tr_busy, tr_dout_ready, tr_rd, tr_we;
logic [7:0]  ne_burstcnt, ne_be, tr_burstcnt, tr_be;
logic [28:0] ne_addr, tr_addr;
logic [63:0] ne_din, tr_din;

PPCMac_ddrarb ddrarb_b (
	.clk(clk_b), .reset(reset_b),
	.a_busy(ne_busy), .a_burstcnt(ne_burstcnt), .a_addr(ne_addr), .a_dout_ready(ne_dout_ready),
	.a_rd(ne_rd), .a_din(ne_din), .a_be(ne_be), .a_we(ne_we),
	.b_busy(tr_busy), .b_burstcnt(tr_burstcnt), .b_addr(tr_addr), .b_dout_ready(tr_dout_ready),
	.b_rd(tr_rd), .b_din(tr_din), .b_be(tr_be), .b_we(tr_we),
	.ddr_busy(na_busy), .ddr_burstcnt(na_burstcnt), .ddr_addr(na_addr), .ddr_dout_ready(na_dout_ready),
	.ddr_rd(na_rd), .ddr_din(na_din), .ddr_be(na_be), .ddr_we(na_we)
);

PPCMac_trace trace (
	.clk, .ev(scsi_tr_ev), .rec(scsi_tr_rec),
	.clk_h(clk_b), .reset_h(reset_b),
	.ddr_busy(tr_busy), .ddr_burstcnt(tr_burstcnt), .ddr_addr(tr_addr), .ddr_rd(tr_rd), .ddr_din(tr_din),
	.ddr_be(tr_be), .ddr_we(tr_we)
);

// ---- the network bridge: MACE's frames to and from the Main, through DDR3 ----
PPCMac_enet enet (
	.clk_h(clk_b), .reset_h(reset_b), .on(net_on),
	.ddr_busy(ne_busy), .ddr_burstcnt(ne_burstcnt), .ddr_addr(ne_addr), .ddr_dout, .ddr_dout_ready(ne_dout_ready),
	.ddr_rd(ne_rd), .ddr_din(ne_din), .ddr_be(ne_be), .ddr_we(ne_we),
	.clk, .tx_we(net_tx_we), .tx_wa(net_tx_wa), .tx_wd(net_tx_wd), .tx_go(net_tx_go), .tx_len(net_tx_len),
	.tx_done(net_tx_done), .rx_ra(net_rx_ra), .rx_q(net_rx_q), .rx_avail(net_rx_avail), .rx_len(net_rx_len),
	.rx_done(net_rx_done), .link(net_link), .mac(net_mac), .mac_ok(net_mac_ok)
);

PPCMac_video video (
	.clk(clk_b), .reset(reset_b),
	.c_req(vb_req), .c_we(vb_we), .c_line(vb_line), .c_addr(vb_addr[21:2]), .c_be(vb_be), .c_wdata(vb_wdata),
	.c_ack(vb_ack), .c_rdata(vb_rdata),
	.ddr_busy(va_busy), .ddr_burstcnt(va_burstcnt), .ddr_addr(va_addr), .ddr_dout, .ddr_dout_ready(va_dout_ready),
	.ddr_rd(va_rd), .ddr_din(va_din), .ddr_be(va_be), .ddr_we(va_we),
	.timing_on, .sw_params, .fb_base, .row_words, .hs_pos, .vs_pos, .dac_cr, .dbl_buf_cr,
	.cursor_x, .cursor_clut, .athens_d2, .athens_n2, .athens_p2, .vbl_start_tog, .vbl_end_tog,
	.clut_index, .clut_rgb,
	.ce_pix(vid_ce), .r(vid_r), .g(vid_g), .b(vid_b), .hs(vid_hs), .vs(vid_vs),
	.hblank(vid_hblank), .vblank(vid_vblank)
);

// the L2 cache between the machine's memory port and the crossing
logic         l_req, l_we, l_line, l_ack;
logic [31:2]  l_addr;
logic [3:0]   l_be;
logic [255:0] l_wdata, l_rdata;

PPCMac_l2 #(.L2_KB(L2_KB)) l2 (
	.clk, .reset, .on(l2_on),
	.a_req(m_req), .a_we(m_we), .a_line(m_line), .a_addr(m_addr), .a_be(m_be), .a_wdata(m_wdata),
	.a_ack(m_ack), .a_rdata(m_rdata),
	.b_req(l_req), .b_we(l_we), .b_line(l_line), .b_addr(l_addr), .b_be(l_be), .b_wdata(l_wdata),
	.b_ack(l_ack), .b_rdata(l_rdata)
);

DSPPC604_memcdc cdc (
	.clk_a(clk), .reset_a(reset),
	.a_req(l_req), .a_we(l_we), .a_line(l_line), .a_addr(l_addr), .a_be(l_be), .a_wdata(l_wdata),
	.a_ack(l_ack), .a_rdata(l_rdata),
	.clk_b, .reset_b,
	.b_req, .b_we, .b_line, .b_addr, .b_be, .b_wdata, .b_ack, .b_rdata
);

assign vram_ack    = vb_ack;
assign vram_we     = vb_we;
assign vram_line   = vb_line;
assign vram_addr   = vb_addr[21:2];
assign vram_rdata  = vb_rdata;

assign cpu_req     = c_req;
assign cpu_we      = c_we;
assign cpu_line    = c_line;
assign cpu_addr    = c_addr;
assign cpu_be      = c_be;
assign cpu_wdata   = c_wdata;
assign cpu_ack     = c_ack;
assign cpu_rdata   = c_rdata;
assign cpu_irq     = ext_irq;
assign cpu_tb_tick = tb_tick;

endmodule

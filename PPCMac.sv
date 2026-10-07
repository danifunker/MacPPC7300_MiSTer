//============================================================================
//
//  PPCMac: a PowerPC Macintosh (the Power Macintosh 7600) for MiSTer
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================
//
//  Clocks from one PLL (rtl/pll.v):
//    clk_cpu  CPU_MHZ  the CPU and the machine (PPCMac_system)
//    clk_mem  100 MHz  the SDRAM controller, hps_io, the ROM upload, the VRAM in
//                      DDR3 and the Control video's scan-out; also the video
//                      clock, the debug readout's picture running on a 20 MHz
//                      enable of it
//  (outclk_0, 20 MHz, is no longer used.)
//
//  The picture (OSD) is the Mac's, Control's scan-out at the mode Mac OS set
//  (the monitor the sense lines report is an OSD choice: Apple's 16-inch RGB,
//  832 x 624, or the 13-inch, 640 x 480; it takes effect at the next reset),
//  or the debug readout's rows of squares.
//
//  The machine is held in reset while RESET, the OSD's reset or the button is
//  down, while the SDRAM is not ready, while a ROM is being uploaded, until
//  a ROM has been uploaded (unless the OSD boots the memory test), and for a
//  moment after the RAM size or boot option changes. Then Cuda starts, and
//  holds the CPU in reset until its firmware has powered the machine up
//  (about 1.3 s; the debug readout counts from there). The ROM goes into the
//  top 4 MB of the 128 MB SDRAM board, written byte by byte from the OSD's
//  file upload (index 1, or index 0: a boot.rom in the core's folder is
//  loaded at start). A boot1.rom there (index 40, loaded before boot.rom)
//  is an 8 KB image for Grand Central's NVRAM, which reset leaves alone
//  (verilator/nvram.py makes one; syn/nvram_of_prompt.bin stops Open
//  Firmware at its prompt).
//
//  The MiSTer's UART is the machine's modem port (the ESCC's channel A,
//  Open Firmware's console with a blank NVRAM: 38,400 baud), or, as the OSD
//  chooses, the debug readout's hex lines at 115,200.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

localparam int CPU_MHZ = 65;            // 60 and 70 also work with the PLL (VCO 1200, 1400 MHz)

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_DTR} = 0;      // (the modem port's handshake lines are not modelled)
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 0;
assign AUDIO_L = 0;
assign AUDIO_R = 0;
assign AUDIO_MIX = 0;

wire   disk_busy;                     // a block moving to or from an image (the memory clock's side syncs it)
reg    [1:0] disk_led_s;
always @(posedge clk_mem) disk_led_s <= {disk_led_s[0], disk_busy};
assign LED_DISK = {1'b0, disk_led_s[1]};
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"PPCMac;UART115200;",
	"-;",
	"F1,ROM,Load ROM;",
	// the disks: SC, so the Main remembers the image and mounts it at the
	// next start (as the other Mac cores); slots 2-5 are the Mac SCSI
	// family's (NVRAM, BlueSCSI Toolbox, CD-ROM, CD changer), not used yet
	"SC0,HDAVHD,Mount SCSI disk 0;",
	"SC1,HDAVHD,Mount SCSI disk 1;",
	"-;",
	"O[3:1],RAM,16 MB,24 MB,48 MB,64 MB,96 MB,6 MB;",
	"O[4],Boot,ROM,Memory test;",
	"O[6],UART,Modem port,Debug readout;",
	"-;",
	"O[7],Picture,Mac,Debug readout;",
	"O[8],Monitor,16-inch 832x624,13-inch 640x480;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[5],TV Mode,NTSC,PAL;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"v,0;",
	"V,v",`BUILD_DATE
};

// the build date, YYMMDD in ASCII, as BCD 20YYMMDD for the debug readout
localparam [47:0] BD = `BUILD_DATE;
localparam [31:0] BUILD = {8'h20, BD[43:40], BD[35:32], BD[27:24], BD[19:16], BD[11:8], BD[3:0]};

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_vid, clk_cpu, clk_mem, pll_locked;
pll #(.CPU_FREQ(CPU_MHZ == 60 ? "60.000000 MHz" : CPU_MHZ == 70 ? "70.000000 MHz" : "65.000000 MHz")) pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_vid),
	.outclk_1(clk_cpu),
	.outclk_2(clk_mem),
	.locked(pll_locked)
);

wire clk_sys = clk_mem;

///////////////////////   HPS   ///////////////////////////////

wire        forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire        ioctl_download;
wire [15:0] ioctl_index;
wire [10:0] ps2_key;
wire [24:0] ps2_mouse;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        ioctl_wait;

// the block devices, as the Mac SCSI family's layout has them (VDNUM 6):
// SCSI disks 0 and 1 on slots 0 and 1; 2-5 tied off for now
localparam VDNUM = 6;
wire [31:0] sd_lba[VDNUM];
wire  [5:0] sd_blk_cnt[VDNUM];
wire [VDNUM-1:0] sd_rd, sd_wr, sd_ack, img_mounted;
wire [13:0] sd_buff_addr;
wire  [7:0] sd_buff_dout;
wire  [7:0] sd_buff_din[VDNUM];
wire        sd_buff_wr, img_readonly;
wire [63:0] img_size;
wire [31:0] disk_lba;
wire  [7:0] disk_buff_din;
wire  [1:0] disk_rd, disk_wr;
assign sd_lba[0] = disk_lba;   assign sd_lba[1] = disk_lba;
assign sd_lba[2] = 0; assign sd_lba[3] = 0; assign sd_lba[4] = 0; assign sd_lba[5] = 0;
assign sd_blk_cnt[0] = 0; assign sd_blk_cnt[1] = 0; assign sd_blk_cnt[2] = 0;
assign sd_blk_cnt[3] = 0; assign sd_blk_cnt[4] = 0; assign sd_blk_cnt[5] = 0;
assign sd_rd = {4'b0000, disk_rd};
assign sd_wr = {4'b0000, disk_wr};
assign sd_buff_din[0] = disk_buff_din;   assign sd_buff_din[1] = disk_buff_din;
assign sd_buff_din[2] = 0; assign sd_buff_din[3] = 0; assign sd_buff_din[4] = 0; assign sd_buff_din[5] = 0;

hps_io #(.CONF_STR(CONF_STR), .VDNUM(VDNUM), .BLKSZ(2)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),
	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait)
);

///////////////////////   OPTIONS AND RESET (memory clock)   ///////////////////////////////

reg  [7:0] ram_mb;
always @(posedge clk_mem) begin
	case (status[3:1])
		3'd1:    ram_mb <= 8'd24;
		3'd2:    ram_mb <= 8'd48;
		3'd3:    ram_mb <= 8'd64;
		3'd4:    ram_mb <= 8'd96;
		3'd5:    ram_mb <= 8'd6;
		default: ram_mb <= 8'd16;
	endcase
end
wire boot_memtest = status[4];

// the ROM upload: index 1 from the OSD, index 0 a boot.rom loaded at start
wire rom_index = ioctl_index[7:0] == 8'd0 || ioctl_index[7:0] == 8'd1;
wire rom_wr    = ioctl_download & rom_index & ioctl_wr;
reg  rom_loaded = 0, dl_q = 0, rom_dl = 0;
always @(posedge clk_mem) begin
	dl_q <= ioctl_download;
	if (ioctl_download & ~dl_q & rom_index) begin rom_dl <= 1; rom_loaded <= 0; end
	if (~ioctl_download & dl_q & rom_dl) begin rom_dl <= 0; rom_loaded <= 1; end
end

// the NVRAM image (boot1.rom, index 40): each byte handed to the CPU's clock
// by a toggle, hps_io waiting until it is taken; the machine is in reset
// meanwhile (the image comes before the ROM)
wire nv_index = ioctl_index[7:0] == 8'h40;
wire nv_dl    = ioctl_download & nv_index;
reg  [12:0] nv_m_addr;
reg  [7:0]  nv_m_data;
reg         nv_req = 0, nv_busy = 0;
reg  [2:0]  nv_ack_s;
wire        nv_ack;                   // the CPU's side, toggled when a byte is written
always @(posedge clk_mem) begin
	nv_ack_s <= {nv_ack_s[1:0], nv_ack};
	if (nv_dl & ioctl_wr & ~nv_busy & ioctl_addr[26:13] == 14'd0) begin
		nv_m_addr <= ioctl_addr[12:0];
		nv_m_data <= ioctl_dout;
		nv_req    <= ~nv_req;
		nv_busy   <= 1;
	end
	else if (nv_busy & (nv_ack_s[2] == nv_req)) nv_busy <= 0;
end
wire sd_up_busy;
assign ioctl_wait = sd_up_busy | nv_busy;

reg  [1:0] locked_m = 0;
always @(posedge clk_mem) locked_m <= {locked_m[0], pll_locked};
wire sdram_init = ~locked_m[1];
wire sdram_ready;

// a change of RAM size, boot option or monitor resets the CPU for a moment
wire [4:0] cfg = {status[8], status[4:1]};
reg  [4:0] cfg_q;
reg  [7:0] cfg_hold = 8'hFF;
reg  [2:0] reset_in;
always @(posedge clk_mem) begin
	reset_in <= {reset_in[1:0], RESET | status[0] | buttons[1]};
	cfg_q <= cfg;
	if (cfg_q != cfg) cfg_hold <= 8'hFF;
	else if (cfg_hold != 0) cfg_hold <= cfg_hold - 1'd1;
end

// the monitor's AppleSense codes (dingusppc's displayid.cpp): the 16-inch RGB
// (7, 2D) or the 13-inch (6, 2B)
wire [2:0] mon_std = status[8] ? 3'd6 : 3'd7;
wire [5:0] mon_ext = status[8] ? 6'h2B : 6'h2D;

reg cpu_reset_m = 1;
always @(posedge clk_mem)
	cpu_reset_m <= reset_in[2] | ~sdram_ready | rom_dl | nv_dl | (~boot_memtest & ~rom_loaded) | (cfg_hold != 0);

// into the CPU's clock (the options are quasi-static: they change only with the reset held)
reg [2:0] cpu_reset_s = 3'b111;
reg [7:0] ram_mb_c [2];
reg [1:0] boot_memtest_c;
reg [8:0] mon_c [2];
always @(posedge clk_cpu) begin
	cpu_reset_s    <= {cpu_reset_s[1:0], cpu_reset_m};
	ram_mb_c[0]    <= ram_mb;
	ram_mb_c[1]    <= ram_mb_c[0];
	boot_memtest_c <= {boot_memtest_c[0], boot_memtest};
	mon_c[0]       <= {mon_std, mon_ext};
	mon_c[1]       <= mon_c[0];
end
wire cpu_reset = cpu_reset_s[2];

// the NVRAM image's bytes, in the CPU's clock (address and data are stable
// from the toggle until the acknowledge returns)
reg  [2:0]  nv_req_s;
reg         nv_ack_c = 0, nv_ld_we = 0;
reg  [12:0] nv_ld_addr;
reg  [7:0]  nv_ld_data;
always @(posedge clk_cpu) begin
	nv_req_s <= {nv_req_s[1:0], nv_req};
	nv_ld_we <= 0;
	if (nv_req_s[2] != nv_ack_c) begin
		nv_ld_addr <= nv_m_addr;
		nv_ld_data <= nv_m_data;
		nv_ld_we   <= 1;
		nv_ack_c   <= nv_req_s[2];
	end
end
assign nv_ack = nv_ack_c;

// the UART: the modem port, or the debug readout (status[6])
wire uart_debug = status[6];
wire modem_txd, dbg_txd;
reg  [1:0] uart_debug_c;
always @(posedge clk_cpu) uart_debug_c <= {uart_debug_c[0], uart_debug};
wire modem_rxd = uart_debug_c[1] | UART_RXD;
assign UART_TXD = uart_debug ? dbg_txd : modem_txd;

///////////////////////   THE MACHINE   ///////////////////////////////

wire         b_req, b_we, b_line, b_ack;
wire [31:2]  b_addr;
wire  [3:0]  b_be;
wire [255:0] b_wdata, b_rdata;

wire         cpu_req, cpu_we, cpu_line, cpu_ack, cpu_irq, cpu_tb_tick;
wire         cpu_held;          // the CPU in reset: cpu_reset, or Cuda holding it
wire [31:2]  cpu_addr;
wire  [3:0]  cpu_be;
wire [255:0] cpu_wdata, cpu_rdata;
wire  [31:0] dbg_status, dbg_passes, dbg_errors, dbg_first;
wire         trace_valid, trace_last, trace_reg_we, trace_dreq, trace_dwe;
wire  [31:0] trace_pc, trace_insn, trace_cr, trace_xer, trace_lr, trace_ctr, trace_fpscr, trace_msr, trace_dwdata;
wire   [6:0] trace_reg_idx;
wire  [63:0] trace_reg_val;
wire   [2:0] trace_dkind;
wire  [31:2] trace_daddr;
wire   [3:0] trace_dbe;
wire         mac_ce, mac_hs, mac_vs, mac_hblank, mac_vblank;
wire   [7:0] mac_r, mac_g, mac_b;

assign DDRAM_CLK = clk_mem;

PPCMac_system #(.CPU_HZ(CPU_MHZ * 1000000), .TB_HZ(12500000), .SDRAM_MB(128)) system
(
	.clk(clk_cpu),
	.reset(cpu_reset),
	.cpu_in_reset(cpu_held),
	.reset_pc(32'hFFF00100),
	.ram_mb(ram_mb_c[1]),
	.boot_memtest(boot_memtest_c[1]),

	.clk_b(clk_mem),
	.reset_b(cpu_reset_m),
	.b_req, .b_we, .b_line, .b_addr, .b_be, .b_wdata, .b_ack, .b_rdata,

	.cpu_req, .cpu_we, .cpu_line, .cpu_addr, .cpu_be, .cpu_wdata, .cpu_ack, .cpu_rdata, .cpu_irq, .cpu_tb_tick,
	.modem_txd, .modem_rxd, .nv_ld_we, .nv_ld_addr, .nv_ld_data,
	.mon_std(mon_c[1][8:6]), .mon_ext(mon_c[1][5:0]),
	.ps2_key, .ps2_mouse,                 // in the memory clock: PPCMac_adb synchronises them
	.img_mounted(img_mounted[1:0]), .img_size, .img_readonly,   // the disks' side runs in the memory clock
	.sd_lba(disk_lba), .sd_rd(disk_rd), .sd_wr(disk_wr), .sd_ack(sd_ack[1:0]),
	.sd_buff_addr, .sd_buff_dout, .sd_buff_din(disk_buff_din), .sd_buff_wr, .disk_busy,
	.ddr_busy(DDRAM_BUSY), .ddr_burstcnt(DDRAM_BURSTCNT), .ddr_addr(DDRAM_ADDR), .ddr_dout(DDRAM_DOUT),
	.ddr_dout_ready(DDRAM_DOUT_READY), .ddr_rd(DDRAM_RD), .ddr_din(DDRAM_DIN), .ddr_be(DDRAM_BE), .ddr_we(DDRAM_WE),
	.vid_ce(mac_ce), .vid_r(mac_r), .vid_g(mac_g), .vid_b(mac_b), .vid_hs(mac_hs), .vid_vs(mac_vs),
	.vid_hblank(mac_hblank), .vid_vblank(mac_vblank),
	.dbg_status, .dbg_passes, .dbg_errors, .dbg_first,
	.trace_valid, .trace_last, .trace_pc, .trace_insn, .trace_reg_we, .trace_reg_idx, .trace_reg_val,
	.trace_cr, .trace_xer, .trace_lr, .trace_ctr, .trace_fpscr, .trace_msr,
	.trace_dreq, .trace_dwe, .trace_dkind, .trace_daddr, .trace_dbe, .trace_dwdata
);

///////////////////////   SDRAM   ///////////////////////////////

wire [15:0] sd_dq_out;
wire        sd_dq_oe;
assign SDRAM_DQ = sd_dq_oe ? sd_dq_out : 16'hZZZZ;

PPCMac_sdram #(.CLK_MHZ(100)) sdram
(
	.clk(clk_mem),
	.init(sdram_init),
	.ready(sdram_ready),

	.req(b_req), .we(b_we), .line(b_line), .addr(b_addr[26:2]), .be(b_be), .wdata(b_wdata),
	.ack(b_ack), .rdata(b_rdata),

	.up_wr(rom_wr),
	.up_addr(27'h7C00000 + ioctl_addr),      // the top 4 MB of the 128 MB board
	.up_data(ioctl_dout),
	.up_busy(sd_up_busy),

	.SDRAM_A, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nRAS, .SDRAM_nCAS, .SDRAM_nWE,
	.SDRAM_DQML, .SDRAM_DQMH, .SDRAM_CKE,
	.dq_out(sd_dq_out), .dq_oe(sd_dq_oe), .dq_in(SDRAM_DQ)
);

// SDRAM_CLK is the memory clock inverted, from a DDR output register, as in
// Sorgelig's sdram.sv
altddio_out
#(
	.extend_oe_disable("OFF"),
	.intended_device_family("Cyclone V"),
	.invert_output("OFF"),
	.lpm_hint("UNUSED"),
	.lpm_type("altddio_out"),
	.oe_reg("UNREGISTERED"),
	.power_up_high("OFF"),
	.width(1)
)
sdramclk_ddr
(
	.datain_h(1'b0),
	.datain_l(1'b1),
	.outclock(clk_mem),
	.dataout(SDRAM_CLK),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(1'b1),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);

///////////////////////   THE DEBUG READOUT   ///////////////////////////////

wire       hblank, hsync, vblank, vsync, ce_pix;
wire [7:0] dbg_r, dbg_g, dbg_b;
wire       led_user;

// its 20 MHz: every fifth clock of the memory clock
reg  [2:0] ce5 = 0;
always @(posedge clk_mem) ce5 <= (ce5 == 3'd4) ? 3'd0 : ce5 + 1'd1;
wire ce_dbg = ce5 == 3'd0;

PPCMac_debug #(.BUILD(BUILD), .CPU_HZ(CPU_MHZ * 1000000), .VID_HZ(20000000), .BAUD(115200)) debug
(
	.clk_cpu(clk_cpu),
	.mach_reset(cpu_reset),
	.cpu_reset(cpu_held),
	.trace_valid, .trace_last, .trace_pc, .trace_insn, .trace_msr,
	.cpu_req, .cpu_we, .cpu_ack, .cpu_addr,
	.mt_passes(dbg_passes), .mt_errors(dbg_errors), .mt_first(dbg_first), .mt_status(dbg_status),
	.led(led_user),

	.rom_loaded(rom_loaded),
	.sdram_ready(sdram_ready),
	.boot_memtest(boot_memtest),
	.pll_locked(pll_locked),
	.ram_mb(ram_mb),

	.clk_vid(clk_mem),
	.ce_vid(ce_dbg),
	.pal(status[5]),
	.scandouble(forced_scandoubler),
	.ce_pix(ce_pix),
	.hblank(hblank), .hsync(hsync), .vblank(vblank), .vsync(vsync),
	.r(dbg_r), .g(dbg_g), .b(dbg_b),
	.uart_txd(dbg_txd)
);

///////////////////////   THE PICTURE   ///////////////////////////////

// the Mac's (Control's scan-out) or the debug readout's, both in the memory clock
wire show_dbg = status[7];
assign CLK_VIDEO = clk_mem;
assign CE_PIXEL  = show_dbg ? ce_pix : mac_ce;
assign VGA_DE    = show_dbg ? ~(hblank | vblank) : ~(mac_hblank | mac_vblank);
assign VGA_HS    = show_dbg ? hsync : mac_hs;
assign VGA_VS    = show_dbg ? vsync : mac_vs;
assign VGA_R     = show_dbg ? dbg_r : mac_r;
assign VGA_G     = show_dbg ? dbg_g : mac_g;
assign VGA_B     = show_dbg ? dbg_b : mac_b;

assign LED_USER  = led_user;

endmodule

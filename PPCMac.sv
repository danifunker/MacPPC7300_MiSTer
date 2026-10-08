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
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// AWACS's samples, signed; they change in the CPU's clock at the sample
// rate, and the framework's audio input keeps a value only once it has seen
// it twice in its own clock
wire [15:0] snd_left, snd_right;
wire signed [15:0] cd_left, cd_right; // the CD-ROM drive's audio, likewise
assign AUDIO_S = 1;
assign AUDIO_MIX = 0;

wire   disk_busy;                     // a block moving to or from an image (the memory clock's side syncs it)
reg    [1:0] disk_led_s;
always @(posedge clk_mem) disk_led_s <= {disk_led_s[0], disk_busy};
assign LED_DISK = {1'b0, disk_led_s[1]};
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];         // the aspect ratio (video_freak, below)

`include "build_id.v"
localparam CONF_STR = {
	"PPCMac;UART115200:57600:38400:19200:9600,MIDI;",
	"-;",
	"F1,ROM,Load ROM;",
	// the disks: SC, so the Main remembers the image and mounts it at the
	// next start (as the other Mac cores); slots 2-5 are the Mac SCSI
	// family's (NVRAM, BlueSCSI Toolbox, CD-ROM, CD changer); slot 2 holds
	// Grand Central's NVRAM (an 8 KB .nvr file, PPCMac_nvsave); the Toolbox
	// and the changer are the Main's own (no menu entry); the CD-ROM needs
	// the Main's Mac CD layer (PPCMac_scsidisk); the floppy (slot 6) is not
	// remembered: a disk left in would be tried at every start
	"SC0,HDAVHD,Mount SCSI disk 0;",
	"SC1,HDAVHD,Mount SCSI disk 1;",
	"SC4,ISOTO*CUEBINCHD,Mount CD-ROM;",
	"S6,DSKIMGIMA,Insert floppy disk;",
	"SC2,NVR,Mount NVRAM;",
	"-;",
	"O[3:1],RAM,16 MB,24 MB,48 MB,64 MB,96 MB,6 MB,120 MB;",
	"O[6],UART,Modem port,Debug readout;",
	"-;",
	"O[7],Picture,Mac,Debug readout;",
	"O[16:15],Monitor,16-inch 832x624,13-inch 640x480,12-inch 512x384;",
	"-;",
	"O[13:11],ADB controller (on reset),None,Gravis MouseStick II,Gravis Firebird,Gravis GamePad,SideWinder 3D Pro;",
	"O[14],Stick moves pointer,No,Yes;",
	"-;",
	"O[19:17],Ethernet (on reset),Off,eth0,eth1,wlan0,tap0;",
	"-;",
	"P1,MT32-pi;",
	"P1-;",
	"P1O[20],Use MT32-pi,Yes,No;",
	"P1O[21],Synth,Munt,FluidSynth;",
	"P1O[23:22],Munt ROM,MT-32 v1,MT-32 v2,CM-32L;",
	"P1O[26:24],SoundFont,0,1,2,3,4,5,6,7;",
	"P1O[28:27],Show Info,No,Yes,LCD-On,LCD-Auto;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[10:9],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"O[5],TV Mode,NTSC,PAL;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"J,Trigger,Thumb,Button 3,Button 4,Button 5,Base 1,Base 2,Base 3;",
	"jn,A,B,X,Y,L,R,Select,Start;",
	"jp,B,A,Y,X,L,R,Select,Start;",
	"I,",
	"MT32-pi: SoundFont #0,",
	"MT32-pi: SoundFont #1,",
	"MT32-pi: SoundFont #2,",
	"MT32-pi: SoundFont #3,",
	"MT32-pi: SoundFont #4,",
	"MT32-pi: SoundFont #5,",
	"MT32-pi: SoundFont #6,",
	"MT32-pi: SoundFont #7,",
	"MT32-pi: MT-32 v1,",
	"MT32-pi: MT-32 v2,",
	"MT32-pi: CM-32L,",
	"MT32-pi: Unknown mode;",
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
wire [31:0] joystick_0;
wire [15:0] joystick_l_analog_0, joystick_r_analog_0;
wire  [7:0] uart_mode;                // the Main's UART mode: 3 MIDI
reg         mt32_info_req;
reg   [3:0] mt32_info_disp;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        ioctl_wait;

// the block devices, as the Mac SCSI family's layout has them: SCSI disks 0
// and 1 on slots 0 and 1, the NVRAM image on 2, the Toolbox on 3, the CD-ROM
// on 4, the CD changer on 5; then the floppy disk on 6 (the Main's generic path)
localparam VDNUM = 7;
wire [31:0] fd_lba;
wire        fd_rd;
wire  [5:0] fd_blk_cnt;
wire [31:0] nvs_lba;
wire        nvs_rd, nvs_wr;
wire  [7:0] nvs_din;
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
wire  [5:0] disk_rd, disk_wr, disk_blk_cnt;
assign sd_lba[0] = disk_lba; assign sd_lba[1] = disk_lba; assign sd_lba[2] = nvs_lba;
assign sd_lba[3] = disk_lba; assign sd_lba[4] = disk_lba; assign sd_lba[5] = disk_lba;
assign sd_lba[6] = fd_lba;
assign sd_blk_cnt[0] = disk_blk_cnt; assign sd_blk_cnt[1] = disk_blk_cnt; assign sd_blk_cnt[2] = 0;
assign sd_blk_cnt[3] = disk_blk_cnt; assign sd_blk_cnt[4] = disk_blk_cnt; assign sd_blk_cnt[5] = disk_blk_cnt;
assign sd_blk_cnt[6] = fd_blk_cnt;
assign sd_rd = {fd_rd, disk_rd[5:3], nvs_rd, disk_rd[1:0]};
assign sd_wr = {1'b0, disk_wr[5:3], nvs_wr, disk_wr[1:0]};
assign sd_buff_din[0] = disk_buff_din; assign sd_buff_din[1] = disk_buff_din; assign sd_buff_din[2] = nvs_din;
assign sd_buff_din[3] = disk_buff_din; assign sd_buff_din[4] = disk_buff_din; assign sd_buff_din[5] = disk_buff_din;
assign sd_buff_din[6] = 8'd0;

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
	.joystick_0(joystick_0),
	.joystick_l_analog_0(joystick_l_analog_0),
	.joystick_r_analog_0(joystick_r_analog_0),
	.uart_mode(uart_mode),
	.info_req(mt32_info_req),
	.info({4'd0, mt32_info_disp}),

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
	.ioctl_wait(ioctl_wait),

	.TIMESTAMP(timestamp)
);

// the date and time for Cuda's clock: the HPS's Unix seconds, from 1904 as a
// Mac counts them (as the Quadra 800 core's RTC takes them); 0 until the
// HPS has sent them
wire [32:0] timestamp;
reg  [31:0] mac_secs_m;
always @(posedge clk_mem) mac_secs_m <= (timestamp[31:0] == 32'd0) ? 32'd0 : timestamp[31:0] + 32'd2082844800;

///////////////////////   OPTIONS AND RESET (memory clock)   ///////////////////////////////

reg  [7:0] ram_mb;
always @(posedge clk_mem) begin
	case (status[3:1])
		3'd1:    ram_mb <= 8'd24;
		3'd2:    ram_mb <= 8'd48;
		3'd3:    ram_mb <= 8'd64;
		3'd4:    ram_mb <= 8'd96;
		3'd5:    ram_mb <= 8'd6;
		3'd6:    ram_mb <= 8'd120;          // (124 at most: the ROM has the module's top 4 MB)
		default: ram_mb <= 8'd16;
	endcase
end
wire boot_memtest = 1'b0;                   // the memory-test boot (PPCMac_bootrom): no menu entry since 2026-10-08

// the ROM upload: index 1 from the OSD, index 0 a boot.rom loaded at start
wire rom_index = ioctl_index[7:0] == 8'd0 || ioctl_index[7:0] == 8'd1;
wire rom_wr    = ioctl_download & rom_index & ioctl_wr;
reg  rom_loaded = 0, dl_q = 0, rom_dl = 0;
always @(posedge clk_mem) begin
	dl_q <= ioctl_download;
	if (ioctl_download & ~dl_q & rom_index) begin rom_dl <= 1; rom_loaded <= 0; end
	if (~ioctl_download & dl_q & rom_dl) begin rom_dl <= 0; rom_loaded <= 1; end
end

// Grand Central's NVRAM from this clock: a byte channel to the CPU's clock,
// a toggle each way (the address, data and direction steady from the
// request's toggle until the acknowledge's, the byte read steady from the
// acknowledge's). Two users: the NVRAM image of boot1.rom (index 40), each
// byte written with the machine in reset (the image comes before the ROM),
// hps_io waiting meanwhile; and PPCMac_nvsave, the image on block slot 2.
wire nv_index = ioctl_index[7:0] == 8'h40;
wire nv_dl    = ioctl_download & nv_index;
reg  [12:0] nv_m_addr;
reg  [7:0]  nv_m_data;
reg         nv_m_we;
reg         nv_req = 0, nv_busy = 0;
reg  [2:0]  nv_ack_s;
wire        nv_ack;                   // the CPU's side, toggled when a byte is done
wire [7:0]  nv_c_q;                   // ... the byte read
reg         nv_dl_pend = 0;           // an ioctl byte waiting for the channel
reg  [12:0] nv_dl_addr;
reg  [7:0]  nv_dl_data;
reg         nvs_own = 0, nvs_taken = 0, nvs_done = 0;
reg  [7:0]  nvs_q;
wire        nvs_req, nvs_we;
wire [12:0] nvs_addr;
wire [7:0]  nvs_wdata;
always @(posedge clk_mem) begin
	nv_ack_s <= {nv_ack_s[1:0], nv_ack};
	nvs_done <= 0;
	if (!nvs_req) nvs_taken <= 0;
	if (!nv_busy) begin
		if (nv_dl_pend) begin
			nv_m_addr  <= nv_dl_addr;
			nv_m_data  <= nv_dl_data;
			nv_m_we    <= 1;
			nv_req     <= ~nv_req;
			nv_busy    <= 1;
			nvs_own    <= 0;
			nv_dl_pend <= 0;
		end
		else if (nvs_req & ~nvs_taken) begin
			nv_m_addr  <= nvs_addr;
			nv_m_data  <= nvs_wdata;
			nv_m_we    <= nvs_we;
			nv_req     <= ~nv_req;
			nv_busy    <= 1;
			nvs_own    <= 1;
			nvs_taken  <= 1;
		end
	end
	else if (nv_ack_s[2] == nv_req) begin
		nv_busy <= 0;
		if (nvs_own) begin
			nvs_done <= 1;
			nvs_q    <= nv_c_q;
		end
	end
	// (after the issue: a byte arriving in the clock a pending one is issued stays pending)
	if (nv_dl & ioctl_wr & ioctl_addr[26:13] == 14'd0) begin
		nv_dl_pend <= 1;
		nv_dl_addr <= ioctl_addr[12:0];
		nv_dl_data <= ioctl_dout;
	end
end
wire sd_up_busy;
assign ioctl_wait = sd_up_busy | nv_busy | nv_dl_pend;

// the NVRAM image on block slot 2 (milestone P)
reg         nv_dirty_t = 0;           // toggled in the CPU's clock at each CPU write to the NVRAM
wire        nvs_hold;
PPCMac_nvsave #(.CLK_HZ(100_000_000)) nvsave (
	.clk(clk_mem), .reset(~pll_locked),
	.img_mounted(img_mounted[2]), .img_size, .img_readonly,
	.sd_lba(nvs_lba), .sd_rd(nvs_rd), .sd_wr(nvs_wr), .sd_ack(sd_ack[2]),
	.sd_buff_addr, .sd_buff_dout, .sd_buff_wr(sd_buff_wr & sd_ack[2]), .sd_buff_din(nvs_din),
	.osd_open(OSD_STATUS), .dirty_tog(nv_dirty_t), .hold(nvs_hold),
	.b_req(nvs_req), .b_we(nvs_we), .b_addr(nvs_addr), .b_wdata(nvs_wdata),
	.b_done(nvs_done), .b_rdata(nvs_q)
);

reg  [1:0] locked_m = 0;
always @(posedge clk_mem) locked_m <= {locked_m[0], pll_locked};
wire sdram_init = ~locked_m[1];
wire sdram_ready;

// a change of RAM size, boot option or monitor resets the CPU for a moment
wire [5:0] cfg = {status[16:15], status[4:1]};
reg  [5:0] cfg_q;
reg  [7:0] cfg_hold = 8'hFF;
reg  [2:0] reset_in;
always @(posedge clk_mem) begin
	reset_in <= {reset_in[1:0], RESET | status[0] | buttons[1]};
	cfg_q <= cfg;
	if (cfg_q != cfg) cfg_hold <= 8'hFF;
	else if (cfg_hold != 0) cfg_hold <= cfg_hold - 1'd1;
end

// the monitor's AppleSense codes (dingusppc's displayid.cpp): the 16-inch RGB
// (7, 2D), the 13-inch (6, 2B) or the 12-inch (2, 21)
wire [2:0] mon_std = (status[16:15] == 2'd1) ? 3'd6  : (status[16:15] == 2'd2) ? 3'd2  : 3'd7;
wire [5:0] mon_ext = (status[16:15] == 2'd1) ? 6'h2B : (status[16:15] == 2'd2) ? 6'h21 : 6'h2D;

reg cpu_reset_m = 1;
always @(posedge clk_mem)
	cpu_reset_m <= reset_in[2] | ~sdram_ready | rom_dl | nv_dl | nvs_hold | (~boot_memtest & ~rom_loaded) | (cfg_hold != 0);

// the ADB game controller and the Ethernet bridge, taken under reset (no hot plug); PPCMac_adb
// synchronises the controller's bus
reg  [2:0]  joy_mode = 0;
reg         net_on = 0;
reg         tr_mesh_m = 0;                  // the trace also takes MESH (status[29]: no menu entry)
always @(posedge clk_mem) if (cpu_reset_m) begin
	joy_mode  <= (status[13:11] > 3'd4) ? 3'd0 : status[13:11];
	net_on    <= status[19:17] != 3'd0;     // the Main's mac_eth.cpp takes the interface from it too
	tr_mesh_m <= status[29];
end
wire [51:0] joy = {status[14], joy_mode, joystick_r_analog_0, joystick_l_analog_0, joystick_0[15:0]};

// into the CPU's clock (the options are quasi-static: they change only with the reset held)
reg [2:0] cpu_reset_s = 3'b111;
reg [7:0] ram_mb_c [2];
reg [1:0] boot_memtest_c;
reg [8:0] mon_c [2];
reg [1:0] tr_mesh_c;
always @(posedge clk_cpu) begin
	cpu_reset_s    <= {cpu_reset_s[1:0], cpu_reset_m};
	ram_mb_c[0]    <= ram_mb;
	ram_mb_c[1]    <= ram_mb_c[0];
	boot_memtest_c <= {boot_memtest_c[0], boot_memtest};
	mon_c[0]       <= {mon_std, mon_ext};
	mon_c[1]       <= mon_c[0];
	tr_mesh_c      <= {tr_mesh_c[0], tr_mesh_m};
end
wire cpu_reset = cpu_reset_s[2];

// the clock's seconds, quasi-static: taken once seen the same twice
reg [31:0] mac_secs_s [2];
reg [31:0] clock_secs = 0;
always @(posedge clk_cpu) begin
	mac_secs_s[0] <= mac_secs_m;
	mac_secs_s[1] <= mac_secs_s[0];
	if (mac_secs_s[1] == mac_secs_s[0]) clock_secs <= mac_secs_s[1];
end
wire clock_ok = clock_secs != 32'd0;

// the NVRAM image's bytes, in the CPU's clock (address and data are stable
// from the toggle until the acknowledge returns)
reg  [2:0]  nv_req_s;
reg         nv_ack_c = 0, nv_ld_we = 0, nv_ld_re = 0;
reg  [12:0] nv_ld_addr;
reg  [7:0]  nv_ld_data, nv_q_c;
wire        nv_ld_rack, nv_wr_cpu;
wire [7:0]  nv_ld_q;
always @(posedge clk_cpu) begin
	nv_req_s <= {nv_req_s[1:0], nv_req};
	nv_ld_we <= 0;
	if (nv_ld_re & nv_ld_rack) begin           // a read done: the byte, then the acknowledge
		nv_ld_re <= 0;
		nv_q_c   <= nv_ld_q;
		nv_ack_c <= nv_req_s[2];
	end
	else if (~nv_ld_re & (nv_req_s[2] != nv_ack_c)) begin
		nv_ld_addr <= nv_m_addr;
		if (nv_m_we) begin
			nv_ld_data <= nv_m_data;
			nv_ld_we   <= 1;
			nv_ack_c   <= nv_req_s[2];
		end
		else nv_ld_re <= 1;
	end
	if (nv_wr_cpu) nv_dirty_t <= ~nv_dirty_t;
end
assign nv_ack = nv_ack_c;
assign nv_c_q = nv_q_c;

// the UART: the modem port, or the debug readout (status[6]); the modem port
// also drives the MT32-pi's MIDI in, and in the Main's MIDI mode the user
// port's MIDI joins what it receives (both lines idle high)
wire uart_debug = status[6];
wire modem_txd, dbg_txd;
reg  [1:0] uart_debug_c;
always @(posedge clk_cpu) uart_debug_c <= {uart_debug_c[0], uart_debug};
wire mt32_midi_rx;
wire midi_in   = (uart_mode == 8'd3) ? mt32_midi_rx : 1'b1;
wire modem_rxd = uart_debug_c[1] | (UART_RXD & midi_in);
assign UART_TXD = uart_debug ? dbg_txd : modem_txd;
// the handshake, as the Quadra 800 core's (an ImageWriter through the Main's
// printer daemon, PPP): CTS uninverted, RTS while a received byte waits, the
// other end's DTR back as its DSR
wire modem_rts;
wire modem_cts = ~uart_debug_c[1] & UART_CTS;
assign UART_RTS = ~uart_debug & modem_rts;
assign UART_DTR = UART_DSR;

// the MT32-pi on the user port (sys/mt32pi.sv), as the Quadra 800 core has it
wire [15:0] mt32_i2s_l, mt32_i2s_r;
wire        mt32_available;
wire        mt32_mute = mt32_available & status[20];
wire        mt32_use  = mt32_available & ~status[20];
wire  [1:0] mt32_info = status[28:27];
wire  [7:0] mt32_mode, mt32_rom, mt32_sf;
wire        mt32_newmode, mt32_lcd_en, mt32_lcd_pix, mt32_lcd_update;

mt32pi mt32pi
(
	.CLK_AUDIO(CLK_AUDIO),
	.CLK_VIDEO(clk_mem),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.VGA_DE(VGA_DE),
	.USER_IN(USER_IN),
	.USER_OUT(USER_OUT),
	.reset(cpu_reset_m),
	.midi_tx(modem_txd | mt32_mute),
	.midi_rx(mt32_midi_rx),
	.mt32_i2s_r(mt32_i2s_r),
	.mt32_i2s_l(mt32_i2s_l),
	.mt32_available(mt32_available),
	.mt32_mode_req(status[21]),
	.mt32_rom_req(status[23:22]),
	.mt32_sf_req({5'd0, status[26:24]}),
	.mt32_mode(mt32_mode),
	.mt32_rom(mt32_rom),
	.mt32_sf(mt32_sf),
	.mt32_newmode(mt32_newmode),
	.mt32_lcd_en(mt32_lcd_en),
	.mt32_lcd_pix(mt32_lcd_pix),
	.mt32_lcd_update(mt32_lcd_update)
);

// Show Info: Yes pops the mode up (the I, strings) when the Pi changes it
reg mt32_newmode_q;
always @(posedge clk_mem) begin
	mt32_newmode_q <= mt32_newmode;
	mt32_info_req <= (mt32_newmode_q ^ mt32_newmode) && (mt32_info == 2'd1);
	mt32_info_disp <= (mt32_mode == 8'hA2) ? (4'd1 + mt32_sf[2:0]) :
	                  (mt32_mode == 8'hA1 && mt32_rom == 8'd0) ? 4'd9 :
	                  (mt32_mode == 8'hA1 && mt32_rom == 8'd1) ? 4'd10 :
	                  (mt32_mode == 8'hA1 && mt32_rom == 8'd2) ? 4'd11 : 4'd12;
end

// the Pi's LCD over the picture: LCD-On always, LCD-Auto for 2 s after it changes
reg        mt32_lcd_on;
reg [27:0] mt32_lcd_to;
reg        mt32_lcd_q;
always @(posedge clk_mem) begin
	mt32_lcd_q <= mt32_lcd_update;
	if (mt32_lcd_to != 0) mt32_lcd_to <= mt32_lcd_to - 1'd1;
	if (mt32_info == 2'd2) mt32_lcd_on <= 1;
	else if (mt32_info != 2'd3) mt32_lcd_on <= 0;
	else begin
		if (mt32_lcd_to == 0) mt32_lcd_on <= 0;
		if (mt32_lcd_q ^ mt32_lcd_update) begin
			mt32_lcd_on <= 1;
			mt32_lcd_to <= 28'd200_000_000;
		end
	end
end

// AWACS, the CD and the Pi's synthesiser, saturated
wire signed [17:0] mix_cl = $signed({{2{snd_left[15]}}, snd_left}) + $signed({{2{cd_left[15]}}, cd_left});
wire signed [17:0] mix_cr = $signed({{2{snd_right[15]}}, snd_right}) + $signed({{2{cd_right[15]}}, cd_right});
wire signed [17:0] mix_l  = mix_cl + $signed(mt32_use ? {{2{mt32_i2s_l[15]}}, mt32_i2s_l} : 18'd0);
wire signed [17:0] mix_r  = mix_cr + $signed(mt32_use ? {{2{mt32_i2s_r[15]}}, mt32_i2s_r} : 18'd0);
assign AUDIO_L = (mix_l > 18'sd32767) ? 16'h7FFF : (mix_l < -18'sd32768) ? 16'h8000 : mix_l[15:0];
assign AUDIO_R = (mix_r > 18'sd32767) ? 16'h7FFF : (mix_r < -18'sd32768) ? 16'h8000 : mix_r[15:0];

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
	.modem_txd, .modem_rxd, .modem_cts, .modem_rts, .snd_left, .snd_right,
	.nv_ld_we, .nv_ld_re, .nv_ld_addr, .nv_ld_data, .nv_ld_rack, .nv_ld_q, .nv_wr_cpu,
	.mon_std(mon_c[1][8:6]), .mon_ext(mon_c[1][5:0]),
	.ps2_key, .ps2_mouse, .joy,           // in the memory clock: PPCMac_adb synchronises them
	.clock_ok, .clock_secs,
	.img_mounted(img_mounted[5:0]), .img_size, .img_readonly,   // the targets' side runs in the memory clock
	.sd_lba(disk_lba), .sd_rd(disk_rd), .sd_wr(disk_wr), .sd_blk_cnt(disk_blk_cnt), .sd_ack(sd_ack[5:0]),
	.fd_mounted(img_mounted[6]), .fd_lba, .fd_rd, .fd_blk_cnt, .fd_ack(sd_ack[6]),
	.sd_buff_addr, .sd_buff_dout, .sd_buff_din(disk_buff_din), .sd_buff_wr, .disk_busy,
	.cd_left, .cd_right,
	.net_on, .tr_mesh(tr_mesh_c[1]),
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
wire   pic_de    = show_dbg ? ~(hblank | vblank) : ~(mac_hblank | mac_vblank);
assign VGA_HS    = show_dbg ? hsync : mac_hs;

// Aspect ratio and integer scaling are the framework's, as in the other Mac
// cores: video_freak turns the OSD's Scale choice into the VIDEO_ARX/ARY
// form the scaler takes (V-Integer: every Mac line the same whole number of
// output lines; 640 x 480 becomes 960 lines on a 1080-line output, where
// Normal's 2.25 makes uneven lines). No crop.
video_freak video_freak
(
	.CLK_VIDEO(clk_mem),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(pic_de),
	.ARX((!ar) ? 12'd4 : (ar - 1'd1)),
	.ARY((!ar) ? 12'd3 : 12'd0),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE({1'b0, status[10:9]})
);
assign VGA_VS    = show_dbg ? vsync : mac_vs;
// the MT32-pi's LCD: the picture dimmed in its box, the text pixel on top
wire       mt32_lcd = mt32_lcd_en & mt32_lcd_on;
wire [7:0] pic_r    = show_dbg ? dbg_r : mac_r;
wire [7:0] pic_g    = show_dbg ? dbg_g : mac_g;
wire [7:0] pic_b    = show_dbg ? dbg_b : mac_b;
assign VGA_R     = mt32_lcd ? {{2{mt32_lcd_pix}}, pic_r[7:2]} : pic_r;
assign VGA_G     = mt32_lcd ? {{2{mt32_lcd_pix}}, pic_g[7:2]} : pic_g;
assign VGA_B     = mt32_lcd ? {{2{mt32_lcd_pix}}, pic_b[7:2]} : pic_b;

assign LED_USER  = led_user;

endmodule

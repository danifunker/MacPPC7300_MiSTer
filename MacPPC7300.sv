//============================================================================
//
//  MacPPC7300: a PowerPC Macintosh (the Power Macintosh 7600) for MiSTer
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
//    clk_cpu  70 or    the CPU and the machine (MacPPC7300_system), the OSD's CPU
//             100 MHz  speed: the PLL's CPU counter rewritten under reset
//    clk_mem  100 MHz  the SDRAM controller, hps_io, the ROM upload, the VRAM in
//                      DDR3 and the Control video's scan-out; also the video
//                      clock, the debug readout's picture running on a 20 MHz
//                      enable of it
//  (outclk_0, 20 MHz, is no longer used.)
//
//  The picture (OSD) is the Mac's, Control's scan-out at the mode Mac OS set
//  (the monitor the sense lines report is an OSD choice: Apple's 16-inch RGB,
//  832 x 624, the 13-inch, 640 x 480, the 12-inch, 512 x 384, the 17-inch
//  Multiple Scan, up to 1024 x 768, the 21-inch, 1152 x 870, or the 20-inch
//  Multiple Scan, up to 1152 x 870; it takes effect at the next reset),
//  or the debug readout's rows of squares.
//
//  The machine is held in reset while RESET, the OSD's reset or the button is
//  down, while the SDRAM is not ready, while a ROM is being uploaded, until
//  a ROM has been uploaded (unless the OSD boots the memory test), and for a
//  moment after the RAM size or boot option changes. Then Cuda starts, and
//  holds the CPU in reset until its firmware has powered the machine up
//  (about 1.3 s; the debug readout counts from there). The ROM goes into the
//  top 4 MB of the SDRAM board (32, 64 or 128 MB, as the Main reports it; the
//  RAM sizes offered are those that fit below), written byte by byte from the OSD's
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

// The CPU's speed (syn\build.py sets the macro): by default the OSD's choice of 70 or 100 MHz, the
// build analysed at 70 (at 100 Quartus merges the CPU's counter with the memory clock's, which the
// rewrite would then move too); MACPPC_SPEED_100 or _70 a fixed speed, built and analysed at it
`ifdef MACPPC_SPEED_100
localparam int SPEED = 100;
`elsif MACPPC_SPEED_70
localparam int SPEED = 70;
`else
localparam int SPEED = 0;
`endif
localparam int CPU_MHZ = SPEED == 100 ? 100 : 70;
localparam int L2_KB = 128;             // 0: no L2 cache (its OSD option then does nothing; saves about 800 ALMs)
localparam int TRACE = 0;               // 1: the DDR3 trace (syn\mister.py trace), for debugging builds
localparam int SOUND_IN_DMA = 0;        // 1: DMA channel 9 (sound in, which records silence) a real channel
localparam int PERF = 0;                // 1: the CPU's performance counters, into the trace (syn\perf.py; needs TRACE)
localparam int SND_TRACE = 0;           // 1: the codec's output frames into the trace (syn\sndtrace.py; needs TRACE)

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

wire [127:0] cfg;                       // the OSD's settings as the machine last took them (below)
wire         cfg_pending;               // an OSD setting differs from them
wire [1:0] ar = cfg[122:121];            // the aspect ratio (video_freak, below)

// The OSD follows the computer cores' standard (hp9000-715_MiSTer docs/osd-standard.md):
// media, Memory and Network interface on the top page, then the pages P1 Machine, P2
// Video, P3 Input, P4 Audio, P5 Advanced; a setting waits for "Apply and reset" (Input's
// and the MT32-pi's act at once), and "Changes pending" shows meanwhile (menu mask bit 0;
// bit 1 a 64 MB board or larger, bit 2 a 128 MB board).
`include "build_id.v"
localparam CONF_STR = {
	"MacPPC7300;UART115200:57600:38400:19200:9600,MIDI;",
	"-;",
	// the disks: SC, so the Main remembers the image and mounts it at the
	// next start (as the other Mac cores); slots 2-5 are the Mac SCSI
	// family's (NVRAM, BlueSCSI Toolbox, CD-ROM, CD changer); slot 2 holds
	// Grand Central's NVRAM (an 8 KB .nvr file, MacPPC7300_nvsave); the Toolbox
	// and the changer are the Main's own (no menu entry); the CD-ROM needs
	// the Main's Mac CD layer (MacPPC7300_scsidisk); the floppy (slot 6) is not
	// remembered: a disk left in would be tried at every start
	"SC0,HDAVHD,Pri. disk (ID 0);",
	"SC1,HDAVHD,Disk (ID 1);",
	"SC4,ISOTO*CUEBINCHD,CD-ROM (ID 3);",
	"S6,DSKIMGIMA,Floppy disk;",
	"F1,ROM,Load ROM;",
	"-;",
	// the RAM sizes the board holds besides the ROM, 28 MB (any board's) the default
	// (status[3:1] was the list before 2026-10-15; until 2026-10-21 28, 6, 16, 60, 124)
	"H1O[7:5],Memory,28MB,6MB,16MB;",
	"h1H2O[7:5],Memory,28MB,60MB,6MB,16MB;",
	"h2O[7:5],Memory,28MB,60MB,124MB,6MB,16MB;",
	// the values in the order Main's ring bridge reads (support/mac/mac_eth.cpp: 0 off)
	"O[19:17],Network interface,None,eth0,eth1,wlan0,tap0;",
	"-;",
	"P1,Machine;",
	"P2,Video;",
	"P3,Input;",
	"P4,Audio;",
	"P5,Advanced;",
	"-;",
	"h0-,Changes pending;",
	"R[0],Apply and reset;",

`ifndef MACPPC_SPEED_100
`ifndef MACPPC_SPEED_70
	"P1O[33],CPU speed,70 MHz,100 MHz;",
`endif
`endif
	"P1O[4],L2 cache,On,Off;",

	// (status[16:15] was the list before 2026-10-15, three monitors)
	"P2O[32:30],Monitor,16-inch 832x624,13-inch 640x480,12-inch 512x384,17-inch Multiscan,21-inch 1152x870,20-inch Multiscan;",
	"P2O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P2O[10:9],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",

	"P3O[38],Swap Alt/Win keys,No,Yes;",
	// the controller is ADB hardware Mac OS finds at its start, so it waits for the reset
	"P3O[13:11],Controller,None,MouseStick II,Firebird,GamePad,SideWinder;",
	"P3O[14],Stick moves pointer,No,Yes;",

	"P4O[20],Use MT32-pi,Yes,No;",
	"P4O[21],Synth,Munt,FluidSynth;",
	"P4O[23:22],Munt ROM,MT-32 v1,MT-32 v2,CM-32L;",
	"P4O[26:24],SoundFont,0,1,2,3,4,5,6,7;",
	"P4O[28:27],Show Info,No,Yes,LCD-On,LCD-Auto;",

	"P5SC2,NVR,NVRAM image;",

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
	// 1 since 2026-10-21: the Memory list reordered
	"v,1;",
	"V,v",`BUILD_DATE
};

// the build date, YYMMDD in ASCII, as BCD 20YYMMDD for the debug readout
localparam [47:0] BD = `BUILD_DATE;
localparam [31:0] BUILD = {8'h20, BD[43:40], BD[35:32], BD[27:24], BD[19:16], BD[11:8], BD[3:0]};

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_vid, clk_cpu, clk_mem, pll_locked;
wire [63:0] reconfig_to_pll, reconfig_from_pll;
pll #(.CPU_MHZ(CPU_MHZ)) pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_vid),
	.outclk_1(clk_cpu),
	.outclk_2(clk_mem),
	.locked(pll_locked),
	.reconfig_to_pll,
	.reconfig_from_pll
);

// the CPU's speed: the PLL's CPU counter (C1, of a 700 MHz VCO) rewritten through
// pll_cfg while the machine is held in reset, 10 for 70 MHz and 7 for 100
wire        cfg_waitrequest;
reg         cfg_write = 0;
reg   [5:0] cfg_address = 0;
reg  [31:0] cfg_data = 0;
pll_cfg pll_cfg
(
	.mgmt_clk(CLK_50M),
	.mgmt_reset(0),
	.mgmt_waitrequest(cfg_waitrequest),
	.mgmt_read(0),
	.mgmt_readdata(),
	.mgmt_write(cfg_write),
	.mgmt_address(cfg_address),
	.mgmt_writedata(cfg_data),
	.reconfig_to_pll,
	.reconfig_from_pll
);

reg  [2:0]  spd_want_s, spd_rst_s;
reg         spd_pll = CPU_MHZ == 100;      // the speed the PLL runs (1: 100 MHz)
reg         spd_tgt = 0;
reg  [2:0]  spd_st = 0;
reg  [15:0] spd_wait = 0;
wire        spd_want;                      // the OSD's speed, under reset (below)
wire        spd_rst;                       // the machine held in reset
always @(posedge CLK_50M) begin
	spd_want_s <= {spd_want_s[1:0], spd_want};
	spd_rst_s  <= {spd_rst_s[1:0], spd_rst};
	cfg_write  <= 0;
	if (!cfg_waitrequest && !cfg_write) begin
		case (spd_st)
			3'd0: if (spd_rst_s[2] && spd_want_s[2] != spd_pll) begin
				spd_tgt     <= spd_want_s[2];
				cfg_address <= 6'd0;                // waitrequest mode
				cfg_data    <= 32'd0;
				cfg_write   <= 1;
				spd_st      <= 3'd1;
			end
			3'd1: begin                          // C1: odd-divide duty for 7, high and low counts
				cfg_address <= 6'd5;
				cfg_data    <= spd_tgt ? {9'd0, 5'd1, 1'b1, 1'b0, 8'd4, 8'd3} : {9'd0, 5'd1, 1'b0, 1'b0, 8'd5, 8'd5};
				cfg_write   <= 1;
				spd_st      <= 3'd2;
			end
			3'd2: begin                          // start
				cfg_address <= 6'd2;
				cfg_data    <= 32'd0;
				cfg_write   <= 1;
				spd_wait    <= 16'hFFFF;
				spd_st      <= 3'd3;
			end
			3'd3: if (spd_wait != 0) spd_wait <= spd_wait - 1'd1;   // 1.3 ms for the new clock to settle
			      else begin spd_pll <= spd_tgt; spd_st <= 3'd0; end
			default: spd_st <= 3'd0;
		endcase
	end
end
wire spd_busy = spd_st != 3'd0 || spd_want_s[2] != spd_pll;

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
wire [15:0] sdram_sz;                 // the Main's SDRAM board: [15] known, [1:0] 1 32 MB, 2 64 MB, 3 128 MB
reg   [1:0] sdram_mod = 2'd1;         // the board the ROM went into (an unknown one taken as 32 MB)

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
	.status_menumask({13'd0, sdram_mod == 2'd3, sdram_mod[1], cfg_pending}),
	.sdram_sz(sdram_sz),
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
// Mac counts them (as the Quadra 800 core's RTC takes them), counted on here
// (the HPS sends them at the core's start: a restart wants the time it is then);
// 0 until the HPS has sent them
wire [32:0] timestamp;
reg  [31:0] mac_secs_m = 0;
reg  [26:0] sec_div = 0;                    // clk_mem's 100 MHz
reg         ts_tog = 0;
always @(posedge clk_mem) begin
	sec_div <= (sec_div == 27'd99_999_999) ? 27'd0 : sec_div + 27'd1;
	if (sec_div == 27'd99_999_999 && mac_secs_m != 32'd0) mac_secs_m <= mac_secs_m + 32'd1;
	ts_tog <= timestamp[32];
	if (ts_tog != timestamp[32] && timestamp[31:0] != 32'd0) begin
		mac_secs_m <= timestamp[31:0] + 32'd2082844800;
		sec_div    <= 27'd0;
	end
end

///////////////////////   OPTIONS AND RESET (memory clock)   ///////////////////////////////

// the OSD's RAM size, taken at the next reset (ram_mb): by default 28 MB, which every
// board holds (the user's choice, 2026-10-15); a size the board cannot hold beside the
// ROM (a setting from a larger board) is the board's largest
reg  [7:0] ram_opt;
wire [7:0] ram_max = sdram_mod == 2'd3 ? 8'd124 : sdram_mod == 2'd2 ? 8'd60 : 8'd28;
reg  [7:0] ram_sel;
always @(*) begin
	// each board's list (CONF_STR): the default, the larger sizes it holds, then 6 and 16 MB
	case ({sdram_mod, status[7:5]})
		{2'd3, 3'd1}, {2'd2, 3'd1}: ram_sel = 8'd60;
		{2'd3, 3'd2}:               ram_sel = 8'd124;
		{2'd3, 3'd3}, {2'd2, 3'd2}, {2'd1, 3'd1}, {2'd0, 3'd1}: ram_sel = 8'd6;
		{2'd3, 3'd4}, {2'd2, 3'd3}, {2'd1, 3'd2}, {2'd0, 3'd2}: ram_sel = 8'd16;
		default:                    ram_sel = 8'd28;
	endcase
end
always @(posedge clk_mem) ram_opt <= ram_sel > ram_max ? ram_max : ram_sel;
wire boot_memtest = 1'b0;                   // the memory-test boot (MacPPC7300_bootrom): no menu entry since 2026-10-08

// the ROM upload: index 1 from the OSD, index 0 a boot.rom loaded at start; into the
// board's top 4 MB, the board as the Main reports it when the upload starts (it does
// so as the core starts, before the boot.rom)
wire rom_index = ioctl_index[7:0] == 8'd0 || ioctl_index[7:0] == 8'd1;
wire rom_wr    = ioctl_download & rom_index & ioctl_wr;
reg  rom_loaded = 0, dl_q = 0, rom_dl = 0;
wire [4:0] rom_at = {sdram_mod == 2'd3, sdram_mod[1], 3'b111};   // 4 MB units: 7, 15 or 31
always @(posedge clk_mem) begin
	dl_q <= ioctl_download;
	if (ioctl_download & ~dl_q & rom_index) begin
		rom_dl     <= 1;
		rom_loaded <= 0;
		sdram_mod  <= (sdram_sz[15] && sdram_sz[1:0] != 2'd0) ? sdram_sz[1:0] : 2'd1;
	end
	if (~ioctl_download & dl_q & rom_dl) begin rom_dl <= 0; rom_loaded <= 1; end
end

// Grand Central's NVRAM from this clock: a byte channel to the CPU's clock,
// a toggle each way (the address, data and direction steady from the
// request's toggle until the acknowledge's, the byte read steady from the
// acknowledge's). Two users: the NVRAM image of boot1.rom (index 40), each
// byte written with the machine in reset (the image comes before the ROM),
// hps_io waiting meanwhile; and MacPPC7300_nvsave, the image on block slot 2.
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
MacPPC7300_nvsave #(.CLK_HZ(100_000_000)) nvsave (
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

// after a Shut Down the machine is off (Cuda's power-down) until a reset or the power key
wire       power_wake;
reg  [1:0] wake_m;
always @(posedge clk_mem) wake_m <= {wake_m[0], power_wake};
reg  [2:0] reset_in;
always @(posedge clk_mem) reset_in <= {reset_in[1:0], RESET | status[0] | buttons[1] | wake_m[1]};

// the monitor's AppleSense codes (dingusppc's displayid.cpp): the 16-inch RGB
// (7, 2D), the 13-inch (6, 2B), the 12-inch (2, 21), the 17-inch Multiple Scan
// (6, 0B: 640 x 480 to 1024 x 768, chosen in the Monitors control panel), the
// 21-inch RGB (0, 00: 1152 x 870, a 100 MHz dot clock) or the 20-inch Multiple
// Scan (6, 23: 640 x 480 to 1152 x 870; Mac OS 7.6.1 lists 1280 x 960 and 1280 x
// 1024 too but stays in the mode it had)
reg  [2:0] mon_std;
reg  [5:0] mon_ext;
always @(*) begin
	case (status[32:30])
		3'd1:    {mon_std, mon_ext} = {3'd6, 6'h2B};
		3'd2:    {mon_std, mon_ext} = {3'd2, 6'h21};
		3'd3:    {mon_std, mon_ext} = {3'd6, 6'h0B};
		3'd4:    {mon_std, mon_ext} = {3'd0, 6'h00};
		3'd5:    {mon_std, mon_ext} = {3'd6, 6'h23};
		default: {mon_std, mon_ext} = {3'd7, 6'h2D};
	endcase
end

// the CPU's speed: the OSD's, taken under reset; the reset held while the PLL changes to it
reg       spd_want_m = 0;
reg [2:0] spd_busy_s = 3'b111, spd_pll_s;
always @(posedge clk_mem) begin
	spd_busy_s <= {spd_busy_s[1:0], spd_busy};
	spd_pll_s  <= {spd_pll_s[1:0], spd_pll};
end
assign spd_want = spd_want_m;

reg cpu_reset_m = 1;
always @(posedge clk_mem)
	cpu_reset_m <= reset_in[2] | ~sdram_ready | rom_dl | nv_dl | nvs_hold | (~boot_memtest & ~rom_loaded) | spd_busy_s[2];
assign spd_rst = cpu_reset_m;

// Cuda's reset: a cold start of its firmware only as the machine starts (the core's start, a new
// ROM, a CPU speed change, the power key after a Shut Down: Cuda's power-off is its firmware's
// own state); Apply and reset and an NVRAM image's load leave Cuda running, as a Mac's reset
// leaves it (its battery): Mac OS 9 takes Cuda's cold start for a lost clock
reg cuda_cold_m = 1;
always @(posedge clk_mem) begin
	if (rom_dl | spd_busy_s[2] | wake_m[1]) cuda_cold_m <= 1;
	else if (!cpu_reset_m) cuda_cold_m <= 0;
end

// the options a running Mac cannot follow, taken under reset (a change waits for the next):
// the RAM size, the monitor, the ADB game controller, the Ethernet bridge, the CPU's speed
// (the PLL's, once it runs it); MacPPC7300_adb synchronises the controller's bus
reg  [7:0]  ram_mb = 8'd16;
reg  [8:0]  mon_m = 9'h1ED;                 // the 16-inch's sense codes
reg  [2:0]  joy_mode = 0;
reg         net_on = 0;
reg         tr_mesh_m = 0;                  // the trace also takes MESH (status[29]: no menu entry)
reg         l2_on_m = 1;
reg         cpu_fast_m = 0;
always @(posedge clk_mem) if (cpu_reset_m) begin
	ram_mb     <= ram_opt;
	mon_m      <= {mon_std, mon_ext};
	joy_mode   <= (status[13:11] > 3'd4) ? 3'd0 : status[13:11];
	net_on     <= status[19:17] != 3'd0;    // the Main's mac_eth.cpp takes the interface from it too
	tr_mesh_m  <= status[29];
	l2_on_m    <= ~status[4];
	spd_want_m <= SPEED == 0 ? status[33] : SPEED == 100;
	cpu_fast_m <= spd_pll_s[2];
end
wire [51:0] joy = {status[14], joy_mode, joystick_r_analog_0, joystick_l_analog_0, joystick_0[15:0]};
// "Swap Alt/Win keys": Alt gives Option and the Windows keys Command
wire [8:0]  key_sc = ps2_key[8:0];
wire [10:0] ps2_key_m = {ps2_key[10:9], !status[38] ? key_sc :
                         key_sc == 9'h011 ? 9'h11F : key_sc == 9'h111 ? 9'h127 :
                         key_sc == 9'h11F ? 9'h011 : key_sc == 9'h127 ? 9'h111 : key_sc};

// the whole OSD as the machine took it, and "Changes pending" while a setting differs
// (not Input's [14] and [38], nor the MT32-pi's [28:20], which act at once)
reg  [127:0] cfg_m = 0;
always @(posedge clk_mem) if (cpu_reset_m) cfg_m <= status;
assign cfg = cfg_m;
assign cfg_pending = {status[13:4], status[19:17], status[33:30], status[122:121]}
                  != {cfg[13:4],    cfg[19:17],    cfg[33:30],    cfg[122:121]};

// into the CPU's clock (the options are quasi-static: they change only with the reset held)
reg [2:0] cpu_reset_s = 3'b111;
reg [2:0] cuda_cold_s = 3'b111;
reg [7:0] ram_mb_c [2];
reg [4:0] rom_at_c [2];
reg [1:0] boot_memtest_c;
reg [8:0] mon_c [2];
reg [1:0] tr_mesh_c;
reg [1:0] l2_on_c = 2'b11;
reg [1:0] cpu_fast_c;
always @(posedge clk_cpu) begin
	cpu_reset_s    <= {cpu_reset_s[1:0], cpu_reset_m};
	cuda_cold_s    <= {cuda_cold_s[1:0], cpu_reset_m & cuda_cold_m};
	cpu_fast_c     <= {cpu_fast_c[0], cpu_fast_m};
	ram_mb_c[0]    <= ram_mb;
	ram_mb_c[1]    <= ram_mb_c[0];
	rom_at_c[0]    <= rom_at;
	rom_at_c[1]    <= rom_at_c[0];
	boot_memtest_c <= {boot_memtest_c[0], boot_memtest};
	mon_c[0]       <= mon_m;
	mon_c[1]       <= mon_c[0];
	tr_mesh_c      <= {tr_mesh_c[0], tr_mesh_m};
	l2_on_c        <= {l2_on_c[0], l2_on_m};
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

// the UART: the modem port (Open Firmware's console when it is told so); it
// also drives the MT32-pi's MIDI in, and in the Main's MIDI mode the user
// port's MIDI joins what it receives (both lines idle high)
wire modem_txd;
wire mt32_midi_rx;
wire midi_in   = (uart_mode == 8'd3) ? mt32_midi_rx : 1'b1;
wire modem_rxd = UART_RXD & midi_in;
assign UART_TXD = modem_txd;
// the handshake, as the Quadra 800 core's (an ImageWriter through the Main's
// printer daemon, PPP): CTS uninverted, RTS while a received byte waits, the
// other end's DTR back as its DSR
wire modem_rts;
wire modem_cts = UART_CTS;
assign UART_RTS = modem_rts;
assign UART_DTR = UART_DSR;

// the MT32-pi on the user port (sys/mt32pi.sv), as the Quadra 800 core has it; it
// takes the modem port only while the port runs at MIDI's rate (a console at
// 38,400 baud, Linux's, hung it)
wire        modem_midi;
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
	.midi_tx(modem_txd | mt32_mute | ~modem_midi),
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

MacPPC7300_system #(.CPU_HZ(70000000), .CPU_HZ_FAST(100000000), .L2_KB(L2_KB), .TB_HZ(12500000),
                    .TRACE(TRACE), .SOUND_IN_DMA(SOUND_IN_DMA), .PERF(PERF), .SND_TRACE(SND_TRACE)) system
(
	.clk(clk_cpu),
	.cpu_fast(cpu_fast_c[1]),
	.reset(cpu_reset),
	.cuda_cold(cuda_cold_s[2]),
	.cpu_in_reset(cpu_held),
	.power_wake,
	.reset_pc(32'hFFF00100),
	.ram_mb(ram_mb_c[1]),
	.rom_at(rom_at_c[1]),
	.boot_memtest(boot_memtest_c[1]),
	.l2_on(l2_on_c[1]),

	.clk_b(clk_mem),
	.reset_b(cpu_reset_m),
	.b_req, .b_we, .b_line, .b_addr, .b_be, .b_wdata, .b_ack, .b_rdata,

	.cpu_req, .cpu_we, .cpu_line, .cpu_addr, .cpu_be, .cpu_wdata, .cpu_ack, .cpu_rdata, .cpu_irq, .cpu_tb_tick,
	.modem_txd, .modem_rxd, .modem_cts, .modem_rts, .modem_midi, .snd_left, .snd_right,
	.nv_ld_we, .nv_ld_re, .nv_ld_addr, .nv_ld_data, .nv_ld_rack, .nv_ld_q, .nv_wr_cpu,
	.mon_std(mon_c[1][8:6]), .mon_ext(mon_c[1][5:0]),
	.ps2_key(ps2_key_m), .ps2_mouse, .joy,   // in the memory clock: MacPPC7300_adb synchronises them
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
	.trace_dreq, .trace_dwe, .trace_dkind, .trace_daddr, .trace_dbe, .trace_dwdata,
	.perf_cnt()
);

///////////////////////   SDRAM   ///////////////////////////////

wire [15:0] sd_dq_out;
wire        sd_dq_oe;
assign SDRAM_DQ = sd_dq_oe ? sd_dq_out : 16'hZZZZ;

MacPPC7300_sdram #(.CLK_MHZ(100)) sdram
(
	.clk(clk_mem),
	.init(sdram_init),
	.ready(sdram_ready),

	.req(b_req), .we(b_we), .line(b_line), .addr(b_addr[26:2]), .be(b_be), .wdata(b_wdata),
	.ack(b_ack), .rdata(b_rdata),

	.up_wr(rom_wr),
	.up_addr({rom_at, ioctl_addr[21:0]}),    // the board's top 4 MB
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

///////////////////////   THE LED   ///////////////////////////////

// the CPU's heartbeat: it toggles every 2^20 instructions retired (the debug
// readout, MacPPC7300_debug, left the core 2026-10-08; it stays for the bench)
reg [20:0] retired = 0;
always @(posedge clk_cpu) begin
	if (trace_valid & trace_last) retired <= retired + 1'd1;
	if (cpu_reset) retired <= 0;
end
wire led_user = retired[20];

///////////////////////   THE PICTURE   ///////////////////////////////

// Control's scan-out, in the memory clock
assign CLK_VIDEO = clk_mem;
assign CE_PIXEL  = mac_ce;
wire   pic_de    = ~(mac_hblank | mac_vblank);
assign VGA_HS    = mac_hs;

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
	.SCALE({1'b0, cfg[10:9]})
);
assign VGA_VS    = mac_vs;
// the MT32-pi's LCD: the picture dimmed in its box, the text pixel on top
wire       mt32_lcd = mt32_lcd_en & mt32_lcd_on;
wire [7:0] pic_r    = mac_r;
wire [7:0] pic_g    = mac_g;
wire [7:0] pic_b    = mac_b;
assign VGA_R     = mt32_lcd ? {{2{mt32_lcd_pix}}, pic_r[7:2]} : pic_r;
assign VGA_G     = mt32_lcd ? {{2{mt32_lcd_pix}}, pic_g[7:2]} : pic_g;
assign VGA_B     = mt32_lcd ? {{2{mt32_lcd_pix}}, pic_b[7:2]} : pic_b;

assign LED_USER  = led_user;

endmodule

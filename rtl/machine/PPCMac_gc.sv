//============================================================================
//
//  PPCMac - the machine around the CPU
//  Grand Central, the 7600's I/O controller, as register stubs
//
//  The 128 KB register window (the ROM puts it at F3000000) as dingusppc's
//  devices/ioctrl/grandcentral.cpp decodes it (GrandCentral::read and
//  ::write, lines 176-450), each sub-device answering what dingusppc's
//  device answers from reset, and no more, until the ROM's progress asks
//  for more:
//
//    00000-07FFF  interrupt registers: events, mask, clear, levels
//                 (grandcentral.cpp:296-307, 432-449, 525-589; MAME's
//                 heathrow.cpp macio_device::set_irq_line): each source's
//                 line sets its event bit on a rising edge, or on either
//                 edge when the mask's top bit selects 68k mode (Mac OS's
//                 NanoKernel runs it so, and reads the levels to follow the
//                 line both ways); the CPU's interrupt is any event that is
//                 unmasked. Sources so far: the DMA channels 8, 9, A, Curio
//                 (0C), MESH (0D), MACE (0E), the ESCC's channels A and B
//                 (0F, 10), the VIA (12), SWIM3 (13), Cuda's NMI (14, the
//                 keyboard's Command-power; AppleGrandCentral's nmiSource),
//                 the Control video's VBL (1A, through Chaos)
//    08000-0FFFF  DMA channel registers, 256 bytes per channel
//                 (grandcentral.cpp:250-305; dbdma.cpp:307-380): channels
//                 2, 3 (Ethernet out, in), 8, 9 (sound out, in) and A
//                 (MESH's) are DBDMA engines (PPCMac_dbdma) sharing the DMA
//                 port (dm_*), one access at a time, the sound channels
//                 first; each one's interrupt, sources 02, 03, 08, 09, 0A,
//                 a level that the clear register drops (dingusppc's
//                 ack_dma_int, clear_dma_int); channels 0 and 1 (Curio,
//                 floppy) are stored and read back and never run
//    10000        Curio SCSI             PPCMac_sc53c94: the external bus's
//                                        53CF94, with no target
//    11000        MACE Ethernet          PPCMac_mace: mace.cpp's registers
//                                        (chip ID 0941), the cable
//                                        unplugged: frames from channel 2
//                                        end in loss of carrier
//    12000-13FFF  ESCC serial            PPCMac_escc: channel A, the modem
//                                        port, on modem_txd/modem_rxd at
//                                        the rate software sets; channel B
//                                        without a line; their interrupts
//    14000        AWACS sound            PPCMac_awacs: awacs.cpp's registers,
//                                        the frames to and from channels 8
//                                        and 9 at the sample rate, the
//                                        samples out on snd_left/snd_right
//    15000        SWIM3 floppy           PPCMac_swim3: the chip with an
//                                        empty Superdrive (swim3.cpp,
//                                        superdrive.cpp)
//    16000-17FFF  VIA                    viacuda.cpp:142-322, the timers
//                                        counting at 783,360 Hz; port B and
//                                        the shift register wired to Cuda
//                                        (below); PPCMac_machine paces the
//                                        accesses to the VIA's clock
//    18000        MESH SCSI              PPCMac_mesh: the internal bus's
//                                        controller; the bus's lines are
//                                        ports (the disks are outside)
//    19000        Ethernet address ROM   08 00 07 44 55 66 00 00
//    1A000        board register 1       E13F (machinetnt.cpp:98-106)
//    1B000        RaDACal (the Control   PPCMac_radacal (control.cpp:156,
//                 video's RAMDAC)        appleramdac.cpp); its colour table
//                                        has a read port in the video clock
//    1C000        no device              reads 0
//    1D000        NVRAM address, high    (macio.h:94-107)
//    1E000        no device on a 7600    reads 0 (board register 2 needs Bandit 2)
//    1F000        NVRAM data, 8 KB       (macio.h:109-125; nvram.cpp:41-60);
//                                        nv_ld_* writes it from outside (an
//                                        image loaded while the machine is
//                                        held in reset); reset leaves it be
//
//  An access is presented for one cycle (sel); the read data is valid in
//  the next cycle.
//
//============================================================================

module PPCMac_gc
#(
	parameter int unsigned SCSI_HZ = 25_000_000
)
(
	input  logic        clk,
	input  logic        reset,
	input  logic        via_tick,      // one clock at 783,360 Hz
	input  logic        rtxc_tick,     // one clock at 3,686,400 Hz, the ESCC's RTxC
	input  logic        scsi_tick,     // one clock at SCSI_HZ: MESH's time, Curio's chip clock
	input  logic        us_tick,       // one clock a microsecond: the SWIM3's timer and steps
	input  logic        snd_tick,      // one clock at 88,200 Hz: AWACS's frames
	input  logic        sel,
	input  logic        we,
	input  logic [16:2] addr,          // offset in the 128 KB window
	input  logic [3:0]  be,
	input  logic [31:0] wdata,
	output logic [31:0] rdata,
	output logic        irq,           // to the CPU's external interrupt

	// the VIA's lines to Cuda (PPCMac_cuda): port B and the shift register
	input  logic        cuda_treq,     // PB3 in: 0 when Cuda asks for a transaction
	input  logic        cuda_cb1,      // CB1: Cuda's shift clock
	input  logic        cb2,           // CB2: the data line, whoever drives it
	output logic        via_tip,       // PB5 out: 0 while a transaction is in progress
	output logic        via_byteack,   // PB4 out
	output logic        via_cb2_oe,    // the VIA drives CB2 (shifting out)
	output logic        via_cb2_out,

	// the modem port (the ESCC's channel A): 1 when idle
	output logic        modem_txd,
	input  logic        modem_rxd,

	// the NVRAM written from outside, a byte a cycle (with the machine held in
	// reset), or read from outside (nv_ld_re held until nv_ld_rack, the byte
	// in nv_ld_q in that clock; taken in a clock the CPU does not use it);
	// nv_wr_cpu marks each write by the CPU (milestone P: the save)
	input  logic        nv_ld_we,
	input  logic        nv_ld_re,
	input  logic [12:0] nv_ld_addr,
	input  logic [7:0]  nv_ld_data,
	output logic        nv_ld_rack,
	output logic [7:0]  nv_ld_q,
	output logic        nv_wr_cpu,

	// the Control video's VBL interrupt (source 1A); Cuda's NMI (14)
	input  logic         ctl_irq,
	input  logic         nmi,

	// the internal SCSI bus: what MESH drives, and the lines (1 = asserted)
	output logic         mesh_rst, mesh_bsy, mesh_sel, mesh_atn, mesh_ack, mesh_req, mesh_msg, mesh_cd, mesh_io,
	output logic [7:0]   mesh_db,
	input  logic         scsi_rst, scsi_bsy, scsi_sel, scsi_atn, scsi_ack, scsi_req, scsi_msg, scsi_cd, scsi_io,
	input  logic [7:0]   scsi_db,

	// the DMA channels' way to memory (the CPU port's protocol; PPCMac_machine
	// takes it through the CPU's snoop port)
	output logic         dm_req,
	output logic         dm_we,
	output logic         dm_line,
	output logic [31:2]  dm_addr,
	output logic [3:0]   dm_be,
	output logic [255:0] dm_wdata,
	input  logic         dm_ack,
	input  logic [255:0] dm_rdata,

	// the sound AWACS plays, signed, at its frame rate
	output logic [15:0]  snd_left,
	output logic [15:0]  snd_right,

	// RaDACal to the scan-out: its state, and its colour table in the video clock
	output logic [7:0]   dac_cr,
	output logic [7:0]   dbl_buf_cr,
	output logic [15:0]  cursor_x,
	output logic [191:0] cursor_clut,
	input  logic         clk_v,
	input  logic [7:0]   clut_index,
	output logic [23:0]  clut_rgb
);

import PPCMac_pkg::*;

wire [16:0] off    = {addr, first_lane(be)};    // the byte offset dingusppc sees
wire [7:0]  wb     = byte_reg_wdata(be, wdata); // what a byte-wide register stores
wire        devs   = addr[16];                  // device register space
wire        dma    = ~addr[16] & addr[15];      // DMA register space
wire        ints   = ~addr[16] & ~addr[15];     // interrupt registers
wire [3:0]  sub    = addr[15:12];               // device number in device space
wire        single = (be == 4'b1000) | (be == 4'b0100) | (be == 4'b0010) | (be == 4'b0001);

// ---- interrupt registers (little-endian inside, as dingusppc keeps them) ------------
// The sources' lines, numbered as Grand Central numbers them
// (grandcentral.cpp:467-523): 0C Curio, 0D MESH, 0E MACE, 0F/10 SCC A/B,
// 11 AWACS, 12 the VIA, 13 SWIM3; 00-0A the DMA channels. int_lines_q is
// each line as last seen: the levels register, and the edge detector.
logic [31:0] int_mask, int_events, int_lines_q;
logic        via_irq;                           // the VIA's IRQ: an enabled flag is set
logic        curio_irq, mesh_irq, swim_irq, mace_irq, scc_a_irq, scc_b_irq;
logic [10:0] dma_lvl;                           // the DMA channels' interrupts, until cleared
wire  [31:0] int_lines  = {5'h0, ctl_irq, 5'h0, nmi, swim_irq, via_irq, 1'b0, scc_b_irq, scc_a_irq, mace_irq, mesh_irq, curio_irq, 1'b0, dma_lvl};
wire  [31:0] int_levels = int_lines_q | 32'h0000_0800;   // dingusppc ORs in bit 11 (grandcentral.cpp:306)
wire         int_68k    = int_mask[31];         // MACIO_INT_MODE: an event at either edge
wire  [31:0] int_chg    = int_lines ^ int_lines_q;
assign irq = |(int_events & int_mask & 32'h7FFF_FFFF);

// ---- DMA channels: 0-3 Curio, floppy, Ethernet out and in; 8, 9 sound out and in; A MESH ----
// (4-7, the serial channels, read 0 and ignore writes, as in dingusppc).
// Channels 2, 3, 8, 9 and A are PPCMac_dbdma (below); 0's and 1's
// registers are kept here.
localparam int NCH = 2;
logic [15:0] ch_stat [NCH];
logic [31:0] ch_cmd  [NCH];
logic [31:0] ch_isel [NCH];
logic [31:0] ch_bsel [NCH];
logic [31:0] ch_wsel [NCH];
wire         ch    = addr[8];
wire         ch_ok = addr[14:9] == 6'd0;
wire [31:0] wle = bswap32(wdata);               // dingusppc swaps a written word (dbdma.cpp:348)

// ---- ESCC (PPCMac_escc) ----------------------------------------------------------------
// MacRISC addressing numbers the registers by (offset >> 4): 0 B command,
// 1 B data, 2 A command, 3 A data, 4 and 5 the enhancement registers; the
// compatible addressing (offset < 0C) has them by (offset >> 1) in the
// order B command, A command, B data, A data, B and A enhancement
// (escc.cpp:38-42, grandcentral.cpp:191-201)
wire       scc_compat = sub == 4'h2 && off[7:0] < 8'h0C;
wire       scc_risc   = sub == 4'h3 || (sub == 4'h2 && off[7:0] >= 8'h60);
logic [3:0] scc_rn;
always_comb begin
	case (off[3:1])
		3'd0:    scc_rn = 4'd0;
		3'd1:    scc_rn = 4'd2;
		3'd2:    scc_rn = 4'd1;
		3'd3:    scc_rn = 4'd3;
		3'd4:    scc_rn = 4'd4;
		default: scc_rn = 4'd5;
	endcase
	if (!scc_compat) scc_rn = off[7:4];
end
logic [7:0] scc_rq;

PPCMac_escc escc (
	.clk, .reset, .rtxc_tick,
	.sel(sel & devs & (scc_compat | scc_risc)), .we, .rn(scc_rn), .wdata(wb),
	.rq(scc_rq), .txd_a(modem_txd), .rxd_a(modem_rxd), .irq_a(scc_a_irq), .irq_b(scc_b_irq)
);

// ---- the SCSI controllers: byte registers at (offset >> 4) & F (grandcentral.cpp:188, 211) ----
logic [7:0] curio_rq, mesh_rq;

PPCMac_sc53c94 #(.TICK_HZ(SCSI_HZ)) curio (
	.clk, .reset, .tick(scsi_tick),
	.sel(sel & devs & (sub == 4'h0)), .we, .rn(off[7:4]), .wdata(wb),
	.rq(curio_rq), .irq(curio_irq)
);

logic       mi_valid, mi_take, mi_flush, mo_ready, mo_put, dma_drained, dma_a_irq;
logic [7:0] mi_data, mo_data;
logic [31:0] dma_a_rle;
wire        dma_a_sel = sel & dma & (addr[14:8] == 7'd10) & (addr[7:5] == 3'd0);   // its first 32 bytes

// ---- the DBDMA engines' way to memory: one access at a time ---------------------------------
// Each engine holds its request until acknowledged; the port is granted to
// one (sound out, sound in, MESH, Ethernet out, Ethernet in, in that order:
// the sound channels stream in real time and move little) and released in
// the cycle of its acknowledge.
logic         a_req, a_we, a_line, s8_req, s8_we, s8_line, s9_req, s9_we, s9_line;
logic         e2_req, e2_we, e2_line, e3_req, e3_we, e3_line;
logic [31:2]  a_addr, s8_addr, s9_addr, e2_addr, e3_addr;
logic [3:0]   a_be, s8_be, s9_be, e2_be, e3_be;
logic [255:0] a_wdata, s8_wdata, s9_wdata, e2_wdata, e3_wdata;
logic         g_busy;
logic [2:0]   g_own;                           // 0 MESH (A), 1 sound out (8), 2 sound in (9), 3 Ethernet out (2), 4 in (3)
always_comb begin
	case (g_own)
		3'd1:    begin dm_req = g_busy & s8_req; dm_we = s8_we; dm_line = s8_line; dm_addr = s8_addr; dm_be = s8_be; dm_wdata = s8_wdata; end
		3'd2:    begin dm_req = g_busy & s9_req; dm_we = s9_we; dm_line = s9_line; dm_addr = s9_addr; dm_be = s9_be; dm_wdata = s9_wdata; end
		3'd3:    begin dm_req = g_busy & e2_req; dm_we = e2_we; dm_line = e2_line; dm_addr = e2_addr; dm_be = e2_be; dm_wdata = e2_wdata; end
		3'd4:    begin dm_req = g_busy & e3_req; dm_we = e3_we; dm_line = e3_line; dm_addr = e3_addr; dm_be = e3_be; dm_wdata = e3_wdata; end
		default: begin dm_req = g_busy & a_req;  dm_we = a_we;  dm_line = a_line;  dm_addr = a_addr;  dm_be = a_be;  dm_wdata = a_wdata;  end
	endcase
end
wire a_ack  = dm_ack & g_busy & (g_own == 3'd0);
wire s8_ack = dm_ack & g_busy & (g_own == 3'd1);
wire s9_ack = dm_ack & g_busy & (g_own == 3'd2);
wire e2_ack = dm_ack & g_busy & (g_own == 3'd3);
wire e3_ack = dm_ack & g_busy & (g_own == 3'd4);
always_ff @(posedge clk) begin
	if (dm_ack) g_busy <= 1'b0;
	else if (!g_busy) begin
		if (s8_req)      begin g_busy <= 1'b1; g_own <= 3'd1; end
		else if (s9_req) begin g_busy <= 1'b1; g_own <= 3'd2; end
		else if (a_req)  begin g_busy <= 1'b1; g_own <= 3'd0; end
		else if (e2_req) begin g_busy <= 1'b1; g_own <= 3'd3; end
		else if (e3_req) begin g_busy <= 1'b1; g_own <= 3'd4; end
	end
	if (reset) begin
		g_busy <= 1'b0;
		g_own  <= 3'd0;
	end
end

PPCMac_mesh #(.TICK_HZ(SCSI_HZ)) mesh (
	.clk, .reset, .tick(scsi_tick),
	.sel(sel & devs & (sub == 4'h8)), .we, .rn(off[7:4]), .wdata(wb),
	.rq(mesh_rq), .irq(mesh_irq),
	.o_rst(mesh_rst), .o_bsy(mesh_bsy), .o_sel(mesh_sel), .o_atn(mesh_atn), .o_ack(mesh_ack),
	.o_req(mesh_req), .o_msg(mesh_msg), .o_cd(mesh_cd), .o_io(mesh_io), .o_db(mesh_db),
	.b_rst(scsi_rst), .b_bsy(scsi_bsy), .b_sel(scsi_sel), .b_atn(scsi_atn), .b_ack(scsi_ack),
	.b_req(scsi_req), .b_msg(scsi_msg), .b_cd(scsi_cd), .b_io(scsi_io), .b_db(scsi_db),
	.di_valid(mi_valid), .di_data(mi_data), .di_take(mi_take), .di_flush(mi_flush),
	.do_ready(mo_ready), .do_data(mo_data), .do_put(mo_put), .dma_drained
);

// MESH's DMA channel (A); its registers' values are little-endian, as the
// others' are kept (wle, bswap32 on the way out)
PPCMac_dbdma dma_a (
	.clk, .reset,
	.sel(dma_a_sel), .we, .rn(addr[4:2]), .wle, .rle(dma_a_rle),
	.dm_req(a_req), .dm_we(a_we), .dm_line(a_line), .dm_addr(a_addr), .dm_be(a_be), .dm_wdata(a_wdata),
	.dm_ack(a_ack), .dm_rdata,
	.di_valid(mi_valid), .di_data(mi_data), .di_take(mi_take), .di_flush(mi_flush),
	.do_ready(mo_ready), .do_data(mo_data), .do_put(mo_put),
	/* verilator lint_off PINCONNECTEMPTY */
	.do_last(), .xfer_in(), .xfer_out(), .active(),
	/* verilator lint_on PINCONNECTEMPTY */
	.drained(dma_drained),
	.irq(dma_a_irq)
);

// ---- AWACS (PPCMac_awacs) and its DMA channels, 8 out and 9 in -------------------------------
logic [31:0] awacs_rq, dma_8_rle, dma_9_rle;
logic        s8_ready, s8_put, s8_active, s8_irq, s9_valid, s9_take, s9_active, s9_irq;
logic [7:0]  s8_data, s9_data;
wire         dma_8_sel = sel & dma & (addr[14:8] == 7'd8) & (addr[7:5] == 3'd0);
wire         dma_9_sel = sel & dma & (addr[14:8] == 7'd9) & (addr[7:5] == 3'd0);

PPCMac_awacs awacs (
	.clk, .reset, .snd_tick,
	.sel(sel & devs & (sub == 4'h4) & (off[3:0] == 4'h0)), .we, .rn(off[7:4]), .wdata, .rq(awacs_rq),
	.out_active(s8_active), .do_ready(s8_ready), .do_data(s8_data), .do_put(s8_put),
	.in_active(s9_active), .di_valid(s9_valid), .di_data(s9_data), .di_take(s9_take),
	.left(snd_left), .right(snd_right)
);

PPCMac_dbdma dma_8 (
	.clk, .reset,
	.sel(dma_8_sel), .we, .rn(addr[4:2]), .wle, .rle(dma_8_rle),
	.dm_req(s8_req), .dm_we(s8_we), .dm_line(s8_line), .dm_addr(s8_addr), .dm_be(s8_be), .dm_wdata(s8_wdata),
	.dm_ack(s8_ack), .dm_rdata,
	.di_valid(1'b0), .di_data(8'h00), .di_flush(1'b0),
	.do_ready(s8_ready), .do_data(s8_data), .do_put(s8_put),
	/* verilator lint_off PINCONNECTEMPTY */
	.do_last(), .di_take(), .xfer_in(), .xfer_out(), .drained(),
	/* verilator lint_on PINCONNECTEMPTY */
	.active(s8_active),
	.irq(s8_irq)
);

PPCMac_dbdma dma_9 (
	.clk, .reset,
	.sel(dma_9_sel), .we, .rn(addr[4:2]), .wle, .rle(dma_9_rle),
	.dm_req(s9_req), .dm_we(s9_we), .dm_line(s9_line), .dm_addr(s9_addr), .dm_be(s9_be), .dm_wdata(s9_wdata),
	.dm_ack(s9_ack), .dm_rdata,
	.di_valid(s9_valid), .di_data(s9_data), .di_take(s9_take), .di_flush(1'b0),
	.do_ready(1'b0),
	/* verilator lint_off PINCONNECTEMPTY */
	.do_data(), .do_put(), .do_last(), .xfer_in(), .xfer_out(), .drained(),
	/* verilator lint_on PINCONNECTEMPTY */
	.active(s9_active),
	.irq(s9_irq)
);

// ---- MACE (PPCMac_mace): byte registers at (offset >> 4) & 1F (grandcentral.cpp:190), ----
// ---- and its DMA channels, 2 out and 3 in ----
logic [7:0]  mace_rq;
logic [31:0] dma_2_rle, dma_3_rle;
logic        e2_ready, e2_put, e2_last, e2_irq, e3_irq;
wire         dma_2_sel = sel & dma & (addr[14:8] == 7'd2) & (addr[7:5] == 3'd0);
wire         dma_3_sel = sel & dma & (addr[14:8] == 7'd3) & (addr[7:5] == 3'd0);

PPCMac_mace mace (
	.clk, .reset, .us_tick,
	.sel(sel & devs & (sub == 4'h1)), .we, .rn(off[8:4]), .wdata(wb),
	.rq(mace_rq),
	.do_ready(e2_ready), .do_put(e2_put), .do_last(e2_last),
	.irq(mace_irq)
);

PPCMac_dbdma dma_2 (
	.clk, .reset,
	.sel(dma_2_sel), .we, .rn(addr[4:2]), .wle, .rle(dma_2_rle),
	.dm_req(e2_req), .dm_we(e2_we), .dm_line(e2_line), .dm_addr(e2_addr), .dm_be(e2_be), .dm_wdata(e2_wdata),
	.dm_ack(e2_ack), .dm_rdata,
	.di_valid(1'b0), .di_data(8'h00), .di_flush(1'b0),
	.do_ready(e2_ready), .do_put(e2_put), .do_last(e2_last),
	/* verilator lint_off PINCONNECTEMPTY */
	.do_data(), .di_take(), .xfer_in(), .xfer_out(), .drained(), .active(),
	/* verilator lint_on PINCONNECTEMPTY */
	.irq(e2_irq)
);

PPCMac_dbdma dma_3 (
	.clk, .reset,
	.sel(dma_3_sel), .we, .rn(addr[4:2]), .wle, .rle(dma_3_rle),
	.dm_req(e3_req), .dm_we(e3_we), .dm_line(e3_line), .dm_addr(e3_addr), .dm_be(e3_be), .dm_wdata(e3_wdata),
	.dm_ack(e3_ack), .dm_rdata,
	.di_valid(1'b0), .di_data(8'h00), .di_flush(1'b0),
	.do_ready(1'b0),
	/* verilator lint_off PINCONNECTEMPTY */
	.do_data(), .do_put(), .do_last(), .di_take(), .xfer_in(), .xfer_out(), .drained(), .active(),
	/* verilator lint_on PINCONNECTEMPTY */
	.irq(e3_irq)
);

// ---- SWIM3 (PPCMac_swim3): byte registers at (offset >> 4) & F (grandcentral.cpp:205) ----
logic [7:0] swim_rq;

PPCMac_swim3 swim3 (
	.clk, .reset, .us_tick,
	.sel(sel & devs & (sub == 4'h5)), .we, .rn(off[7:4]), .wdata(wb),
	.rq(swim_rq), .irq(swim_irq)
);

// ---- VIA (viacuda.cpp; port B and the shift register as a 6522 and Cuda have them) -------
// Port B is a 6522's: the output register holds all eight bits and a read
// gives it where DDRB is 1 and the pins elsewhere; the pins Cuda drives
// are PB3 (TREQ), the others read 0. PB5 (TIP) and PB4 (BYTEACK) go to
// Cuda, high where they are inputs. The shift register works in the modes
// Cuda's protocol uses, both clocked by Cuda on CB1, as MAME's 6522 does
// them (6522via.cpp shift_in, shift_out, write_cb1): every CB1 edge counts;
// shifting out (ACR SR bits 111) the VIA puts SR bit 7 on CB2 and rotates on
// a falling edge, the flag at the eighth; shifting in (011, and 000) it
// takes CB2 in on a rising edge, the flag at the eighth (not in 000). A
// read or write of SR clears the flag and starts the count again.
logic [7:0]  via_orb, via_porta, via_ddrb, via_ddra, via_sr, via_acr, via_pcr, via_ifr, via_ier;
logic [7:0]  t1ll, t1lh, t2ll;
logic [15:0] t1, t2;                 // the counters
logic [17:0] t1_left, t2_left;       // VIA clocks until the flag
logic        t1_run, t2_run;
logic [4:0]  sr_cnt;                 // CB1 edges until the flag (MAME's m_shift_counter)
logic        cb1_q;                  // CB1 as last seen
logic        cb2_q;                  // what the VIA drives on CB2
wire  [3:0]  via_reg    = addr[12:9];
wire  [7:0]  via_ifr_rd = {|(via_ifr[6:0] & via_ier[6:0]), via_ifr[6:0]};
assign via_irq = via_ifr_rd[7];
wire  [7:0]  via_pb_rd  = (via_orb & via_ddrb) | ({4'b0000, cuda_treq, 3'b000} & ~via_ddrb);

assign via_tip     = ~via_ddrb[5] | via_orb[5];
assign via_byteack = ~via_ddrb[4] | via_orb[4];
assign via_cb2_oe  = via_acr[4];
assign via_cb2_out = cb2_q;

// ---- NVRAM -----------------------------------------------------------------------------
logic [15:0] nv_hi;
logic [7:0]  nvram [0:8191];
logic [7:0]  nv_q;
logic        nv_rd_q;
wire  [12:0] nv_addr = 13'((nv_hi << 5) + 16'(off[8:4]));
// what an IOBus device is written: a single byte as it is, else the
// halfword byte-swapped (grandcentral.cpp:358-365)
wire  [15:0] io_w  = single ? {8'h00, wb} : (be[3] ? {wdata[23:16], wdata[31:24]} : {wdata[7:0], wdata[15:8]});
wire         nv_wr = sel & we & devs & (sub == 4'hF);
wire         nv_ext_rd = nv_ld_re & ~nv_ld_we & ~(sel & devs & (sub == 4'hF));
// one port: the load's address while it writes (only with the machine in
// reset), an outside read's in a clock the CPU leaves it free
wire  [12:0] nv_a  = (nv_ld_we | nv_ext_rd) ? nv_ld_addr : nv_addr;
assign nv_ld_q   = nv_q;
assign nv_wr_cpu = nv_wr;

always_ff @(posedge clk) begin
	if (nv_wr | nv_ld_we) nvram[nv_a] <= nv_ld_we ? nv_ld_data : io_w[7:0];
	nv_q <= nvram[nv_a];
	nv_ld_rack <= nv_ext_rd;
end

// ---- RaDACal: IOBus device 2, registers (offset >> 4) & 1F, the first four its own ---------
logic [7:0] rad_rq;
logic       rad_rd_q;
wire        rad_sel = sel & devs & (sub == 4'hB) & (off[8:6] == 3'd0);

PPCMac_radacal radacal (
	.clk, .reset, .sel(rad_sel), .we, .rn(off[5:4]), .wdata(io_w[7:0]), .rq(rad_rq),
	.dac_cr, .dbl_buf_cr, .cursor_x, .cursor_clut,
	.clk_v, .v_index(clut_index), .v_rgb(clut_rgb)
);

// an IOBus device's 16-bit value as a CPU word (grandcentral.cpp:224-233)
function automatic logic [31:0] iobus_rdata(input logic [15:0] v);
	iobus_rdata = {v[7:0], v[15:8], 16'h0};
endfunction

// ---- what a read returns ---------------------------------------------------------------
logic [31:0] rq;
always_comb begin
	rq = 32'h0;
	if (ints) begin
		case (off[7:0])
			8'h20:   rq = bswap32(int_events & int_mask);
			8'h24:   rq = bswap32(int_mask);
			8'h2C:   rq = bswap32(int_levels);
			default: rq = 32'h0;
		endcase
	end
	else if (dma) begin
		if (addr[14:8] == 7'd10) rq = (off[7:5] == 3'd0) ? bswap32(dma_a_rle) : 32'h0;
		else if (addr[14:8] == 7'd8) rq = (off[7:5] == 3'd0) ? bswap32(dma_8_rle) : 32'h0;
		else if (addr[14:8] == 7'd9) rq = (off[7:5] == 3'd0) ? bswap32(dma_9_rle) : 32'h0;
		else if (addr[14:8] == 7'd2) rq = (off[7:5] == 3'd0) ? bswap32(dma_2_rle) : 32'h0;
		else if (addr[14:8] == 7'd3) rq = (off[7:5] == 3'd0) ? bswap32(dma_3_rle) : 32'h0;
		else if (ch_ok) begin
			case (off[7:2])
				6'd1:    rq = bswap32({16'h0, ch_stat[ch]});
				6'd3:    rq = bswap32(ch_cmd[ch]);
				6'd4:    rq = bswap32(ch_isel[ch]);
				6'd5:    rq = bswap32(ch_bsel[ch]);
				6'd6:    rq = bswap32(ch_wsel[ch]);
				default: rq = 32'h0;          // ChannelControl reads 0
			endcase
		end
	end
	else begin
		case (sub)
			4'h0:       rq = byte_reg_rdata(be, curio_rq);
			4'h1:       rq = byte_reg_rdata(be, mace_rq);
			4'h8:       rq = byte_reg_rdata(be, mesh_rq);
			4'h5:       rq = byte_reg_rdata(be, swim_rq);
			4'h2, 4'h3: if (scc_compat | scc_risc) rq = byte_reg_rdata(be, scc_rq);
			4'h4:    rq = (off[3:0] == 4'h0) ? awacs_rq : 32'h0;
			4'h6, 4'h7: begin
				case (via_reg)
					4'd0:        rq = byte_reg_rdata(be, via_pb_rd);
					4'd1, 4'd15: rq = byte_reg_rdata(be, via_porta);
					4'd2:        rq = byte_reg_rdata(be, via_ddrb);
					4'd3:        rq = byte_reg_rdata(be, via_ddra);
					4'd4:        rq = byte_reg_rdata(be, t1[7:0]);
					4'd5:        rq = byte_reg_rdata(be, t1[15:8]);
					4'd6:        rq = byte_reg_rdata(be, t1ll);
					4'd7:        rq = byte_reg_rdata(be, t1lh);
					4'd8:        rq = byte_reg_rdata(be, t2[7:0]);
					4'd9:        rq = byte_reg_rdata(be, t2[15:8]);
					4'd10:       rq = byte_reg_rdata(be, via_sr);
					4'd11:       rq = byte_reg_rdata(be, via_acr);
					4'd12:       rq = byte_reg_rdata(be, via_pcr);
					4'd13:       rq = byte_reg_rdata(be, via_ifr_rd);
					default:     rq = byte_reg_rdata(be, via_ier | 8'h80);
				endcase
			end
			4'h9: begin
				case (off[6:4])
					3'd0:    rq = byte_reg_rdata(be, 8'h08);
					3'd2:    rq = byte_reg_rdata(be, 8'h07);
					3'd3:    rq = byte_reg_rdata(be, 8'h44);
					3'd4:    rq = byte_reg_rdata(be, 8'h55);
					3'd5:    rq = byte_reg_rdata(be, 8'h66);
					default: rq = byte_reg_rdata(be, 8'h00);
				endcase
			end
			4'hA:    rq = iobus_rdata(16'hE13F);
			4'hD:    rq = iobus_rdata(nv_hi);
			default: rq = 32'h0;              // 4'hF, the NVRAM, answers from its RAM
		endcase
	end
end

logic [31:0] rdata_q;
assign rdata = nv_rd_q  ? iobus_rdata({8'h00, nv_q}) :
               rad_rd_q ? iobus_rdata({8'h00, rad_rq}) : rdata_q;

// ---- the shift register: the CPU's access to it, then a CB1 edge in the same clock --------
wire       sr_acc = sel & devs & (sub == 4'h6 || sub == 4'h7) & (via_reg == 4'd10);
wire [4:0] cnt_a  = sr_acc ? (cb1_q ? 5'd15 : 5'd16) : sr_cnt;
wire [7:0] sr_a   = (sr_acc & we) ? wb : via_sr;
wire [2:0] sr_m   = via_acr[4:2];
logic [7:0] sr_n;
logic [4:0] cnt_n;
logic       cb2_n, sr_flag;
always_comb begin
	sr_n    = sr_a;
	cnt_n   = cnt_a;
	cb2_n   = cb2_q;
	sr_flag = 1'b0;
	if (cuda_cb1 != cb1_q) begin
		if (sr_m == 3'b111) begin
			if (cnt_a[0]) begin
				cb2_n = sr_a[7];
				sr_n  = {sr_a[6:0], sr_a[7]};
				if (cnt_a == 5'd1) sr_flag = 1'b1;
			end
		end
		else if (sr_m == 3'b011 || sr_m == 3'b000) begin
			if (!cnt_a[0]) begin
				sr_n = {sr_a[6:0], cb2};
				if (cnt_a == 5'd0 && sr_m != 3'b000) sr_flag = 1'b1;
			end
		end
		cnt_n = {1'b0, cnt_a[3:0] - 4'd1};
	end
end

// ---- writes, and the reads that change something --------------------------------------
always_ff @(posedge clk) begin
	// the VIA's timers count all the time
	if (via_tick) begin
		t1 <= t1 - 16'd1;
		t2 <= t2 - 16'd1;
		if (t1_run) begin
			if (t1_left == 18'd1) begin
				via_ifr[6] <= 1'b1;                            // T1
				t1 <= {t1lh, t1ll};
				t1_left <= 18'({t1lh, t1ll}) + 18'd3;
				t1_run <= via_acr[6];                          // free-running, or once
			end
			else t1_left <= t1_left - 18'd1;
		end
		if (t2_run) begin
			if (t2_left == 18'd1) begin
				via_ifr[5] <= 1'b1;                            // T2
				t2_run <= 1'b0;
			end
			else t2_left <= t2_left - 18'd1;
		end
	end

	nv_rd_q  <= sel & ~we & devs & (sub == 4'hF);
	rad_rd_q <= rad_sel & ~we;
	if (sel) rdata_q <= rq;

	// the DMA channels' interrupts: each a level until the clear register
	// drops it (clear_dma_int; its falling edge is a new event in 68k mode)
	if (s8_irq)    dma_lvl[8]  <= 1'b1;
	if (s9_irq)    dma_lvl[9]  <= 1'b1;
	if (dma_a_irq) dma_lvl[10] <= 1'b1;
	if (e2_irq)    dma_lvl[2]  <= 1'b1;
	if (e3_irq)    dma_lvl[3]  <= 1'b1;

	if (sel & ints & we) begin
		case (off[7:0])
			8'h24: int_mask <= bswap32(merge_be(bswap32(int_mask), wdata, be));
			8'h28: begin
				// with MACIO_INT_MODE in the mask, MACIO_INT_CLR clears everything
				if (int_mask[31] & wle[31]) int_events <= 32'h0;
				else int_events <= int_events & ~(wle & 32'h7FFF_FFFF);
				dma_lvl <= dma_lvl & ~wle[10:0];
			end
			default: ;
		endcase
	end

	// the sources' lines: an event at a rising edge, or at either edge in
	// 68k mode; in native mode a falling edge takes the event away
	// (set_irq_line, which MAME's devices call when a line changes). An edge
	// in the cycle of a clear is a new event and stays.
	for (int i = 0; i < 32; i++)
		if (int_chg[i]) int_events[i] <= int_68k | int_lines[i];
	int_lines_q <= int_lines;

	if (sel & dma & we & ch_ok) begin
		case (off[7:2])
			6'd0: begin
				// ChannelControl: the top half masks the bottom half
				// (dbdma.cpp:351-380): s0-s7, RUN and PAUSE as written; the
				// channel never runs, so ACTIVE stays clear
				ch_stat[ch][7:0] <= (ch_stat[ch][7:0] & ~wle[23:16]) | (wle[7:0] & wle[23:16]);
				if (wle[31]) ch_stat[ch][15] <= wle[15];
				if (wle[30]) ch_stat[ch][14] <= wle[14];
			end
			6'd3: ch_cmd[ch]  <= wle;
			6'd4: ch_isel[ch] <= wle;
			6'd5: ch_bsel[ch] <= wle;
			6'd6: ch_wsel[ch] <= wle;
			default: ;
		endcase
	end

	if (sel & devs) begin
		case (sub)
			4'h6, 4'h7: begin
				case (via_reg)
					4'd0:        if (we) via_orb <= wb;
					4'd1, 4'd15: if (we) via_porta <= wb;
					4'd2:        if (we) via_ddrb <= wb;
					4'd3:        if (we) via_ddra <= wb;
					4'd4:        if (we) t1ll <= wb; else via_ifr[6] <= 1'b0;
					4'd5: if (we) begin
						t1lh <= wb;
						t1 <= {wb, t1ll};
						t1_left <= 18'({wb, t1ll}) + 18'd3;
						t1_run <= 1'b1;
						via_ifr[6] <= 1'b0;
					end
					4'd6:        if (we) t1ll <= wb;
					4'd7:        if (we) begin t1lh <= wb; via_ifr[6] <= 1'b0; end
					4'd8:        if (we) t2ll <= wb; else via_ifr[5] <= 1'b0;
					4'd9: if (we) begin
						t2 <= {wb, t2ll};
						t2_left <= 18'({wb, t2ll}) + 18'd3;
						t2_run <= 1'b1;
						via_ifr[5] <= 1'b0;
					end
					4'd10:       via_ifr[2] <= 1'b0;      // the register itself: sr_n

					4'd11: if (we) via_acr <= wb & 8'h5C;
					4'd12: if (we) via_pcr <= wb;
					4'd13: if (we) via_ifr[6:0] <= via_ifr[6:0] & ~wb[6:0];
					default: if (we) via_ier <= wb[7] ? (via_ier | {1'b0, wb[6:0]}) : (via_ier & ~wb);
				endcase
			end
			4'hD: if (we) nv_hi <= io_w;
			default: ;
		endcase
	end

	// the shift register, clocked by Cuda
	via_sr <= sr_n;
	sr_cnt <= cnt_n;
	cb2_q  <= cb2_n;
	cb1_q  <= cuda_cb1;
	if (sr_flag) via_ifr[2] <= 1'b1;

	if (reset) begin
		int_mask    <= 32'h0;
		int_events  <= 32'h0;
		int_lines_q <= 32'h0;
		dma_lvl     <= 11'h0;
		for (int i = 0; i < NCH; i++) begin
			ch_stat[i] <= 16'h0;
			ch_cmd[i]  <= 32'h0;
			ch_isel[i] <= 32'h0;
			ch_bsel[i] <= 32'h0;
			ch_wsel[i] <= 32'h0;
		end
		via_orb     <= 8'h0;
		via_porta   <= 8'h0;
		sr_cnt      <= 5'd15;
		cb1_q       <= 1'b1;
		cb2_q       <= 1'b1;
		via_ddrb    <= 8'h0;
		via_ddra    <= 8'h0;
		via_sr      <= 8'h0;
		via_acr     <= 8'h0;
		via_pcr     <= 8'h0;
		via_ifr     <= 8'h0;
		via_ier     <= 8'h0;
		t1ll        <= 8'h0;
		t1lh        <= 8'h0;
		t2ll        <= 8'h0;
		t1          <= 16'h0;
		t2          <= 16'h0;
		t1_left     <= 18'h0;
		t2_left     <= 18'h0;
		t1_run      <= 1'b0;
		t2_run      <= 1'b0;
		nv_hi       <= 16'h0;
		nv_rd_q     <= 1'b0;
		rad_rd_q    <= 1'b0;
	end
end

endmodule

//============================================================================
//
//  PPCMac - the machine around the CPU
//  A Bandit or Chaos PCI host bridge: its configuration mechanism and the
//  configuration headers of the devices behind it
//
//  Follows dingusppc's devices/common/pci/bandit.cpp (BanditHost::read and
//  ::write, lines 141-260; cfg_setup, 262-290), pcibase.cpp (the header's
//  first four words and the BAR rules, 34-94 and 186-216) and pcidevice.cpp
//  (BARs, 34-77). The registers are little-endian on the PCI side; a word
//  the CPU reads is the byte-swapped register, as in dingusppc.
//
//  BRIDGE = 1: Bandit 1 at F2000000 (machinetnt.cpp:73-80): device 11 is
//              Bandit's own header (bandit.cpp:41-64), device 16 is Grand
//              Central's (grandcentral.cpp:43-52).
//  BRIDGE = 0: Chaos, the video bus, at F0000000 (bandit.cpp:308-322,
//              machinetnt.cpp:89-96): device 11 is the Control video
//              controller's header (control.cpp:96-104).
//
//  The base address registers are stored and read back with their masks;
//  the machine's decoder does not follow them. The 7600's ROM puts Grand
//  Central at F3000000 and the machine maps it there.
//
//  An access is presented for one cycle (sel); the read data is valid in
//  the next cycle.
//
//============================================================================

module PPCMac_pcicfg
#(
	parameter int BRIDGE = 1
)
(
	input  logic        clk,
	input  logic        reset,
	input  logic        sel,
	input  logic        we,
	input  logic [23:2] addr,        // offset in the bridge's 16 MB region
	input  logic [3:0]  be,
	input  logic [31:0] wdata,
	output logic [31:0] rdata
);

import PPCMac_pkg::*;

logic [31:0] config_addr;          // as the CPU wrote it (dingusppc keeps it swapped and swaps it back)

// ---- the device addressed by CONFIG_ADDR (bandit.cpp:262-290) ----------------
wire [31:0] cfg   = bswap32(config_addr);
wire [20:0] idsel = cfg[31:11];
wire [5:0]  reg_n = cfg[7:2];
wire        fun0  = cfg[10:8] == 3'd0;
wire        type0 = ~cfg[0];
// type 0 with exactly one IDSEL bit: device 11 + its position
wire        idsel_one = (idsel != 21'd0) && ((idsel & (idsel - 21'd1)) == 21'd0);
wire        dev11 = type0 & fun0 & idsel_one & idsel[0];
wire        dev16 = type0 & fun0 & idsel_one & idsel[5];

// ---- the headers' writable parts -------------------------------------------------
// Bandit (bandit.cpp:41-64, 66-111)
logic [7:0]  bd_lat;
logic [31:0] bd_addr_mask, bd_mode, bd_hold;
// Grand Central (grandcentral.cpp:43-52; pcibase.cpp:38-57)
logic [15:0] gc_cmd, gc_stat;
logic [7:0]  gc_lat, gc_cache;
logic [31:0] gc_bar0;
// Control (control.cpp:96-104)
logic [15:0] cv_cmd, cv_stat;
logic [7:0]  cv_lat, cv_cache;
logic [31:0] cv_bar0, cv_bar1, cv_bar2;

// the register addressed, little-endian, as the device reads it
logic [31:0] hdr;
logic        present;
always_comb begin
	hdr = 32'h0;
	present = 1'b0;
	if (BRIDGE == 1 && dev11) begin
		present = 1'b1;
		case (reg_n)
			6'h00: hdr = 32'h0001_106B;                       // device 1, Apple
			6'h01: hdr = {16'h0000, 16'h0016};                 // status 0, command 16 (read-only)
			6'h02: hdr = 32'h0600_0003;                       // host bridge, revision 3
			6'h03: hdr = {8'h00, 8'h00, bd_lat, 8'h08};        // cache line size 8 (read-only)
			6'h12: hdr = bd_addr_mask;                         // 0x48
			6'h14: hdr = bd_mode;                              // 0x50
			6'h16: hdr = bd_hold;                              // 0x58
			default: hdr = 32'h0;
		endcase
	end
	else if (BRIDGE == 1 && dev16) begin
		present = 1'b1;
		case (reg_n)
			6'h00: hdr = 32'h0002_106B;                       // Grand Central, Apple
			6'h01: hdr = {gc_stat, gc_cmd};
			6'h02: hdr = 32'hFF00_0002;
			6'h03: hdr = {8'h00, 8'h00, gc_lat, gc_cache};
			6'h04: hdr = gc_bar0;
			default: hdr = 32'h0;
		endcase
	end
	else if (BRIDGE == 0 && dev11) begin
		present = 1'b1;
		case (reg_n)
			6'h00: hdr = 32'h0003_106B;                       // Control, Apple
			6'h01: hdr = {cv_stat, cv_cmd};
			6'h02: hdr = 32'h0000_0000;
			6'h03: hdr = {8'h00, 8'h00, cv_lat, cv_cache};
			6'h04: hdr = cv_bar0;
			6'h05: hdr = cv_bar1;
			6'h06: hdr = cv_bar2;
			default: hdr = 32'h0;
		endcase
	end
end

// a CONFIG_DATA write, little-endian (only whole aligned words are modelled,
// which is all the ROM does; dingusppc's fast path, bandit.cpp:224-227)
wire [31:0] wle = bswap32(wdata);
wire        cfg_wr = sel & we & (addr[23:21] == 3'd6) & (be == 4'hF);

always_ff @(posedge clk) begin
	if (sel & we & (addr[23:22] == 2'b10))                 // CONFIG_ADDR (offset >> 21 = 4 or 5)
		config_addr <= merge_be(config_addr, wdata, be);
	if (cfg_wr) begin
		if (BRIDGE == 1 && dev11) begin
			case (reg_n)
				6'h03: bd_lat <= wle[15:8];
				6'h12: bd_addr_mask <= wle;
				6'h14: bd_mode <= wle;
				6'h16: bd_hold <= {27'h0, wle[4:0]};
				default: ;
			endcase
		end
		if (BRIDGE == 1 && dev16) begin
			case (reg_n)
				6'h01: begin gc_stat <= gc_stat & ~(wle[31:16] & 16'hF900); gc_cmd <= wle[15:0] & 16'hFF77; end
				6'h03: begin gc_lat <= wle[15:8]; gc_cache <= wle[7:0]; end
				6'h04: gc_bar0 <= wle & 32'hFFFE_0000;            // 128 KB of memory space
				default: ;
			endcase
		end
		if (BRIDGE == 0 && dev11) begin
			case (reg_n)
				6'h01: begin cv_stat <= cv_stat & ~(wle[31:16] & 16'hF900); cv_cmd <= wle[15:0] & 16'hFF77; end
				6'h03: begin cv_lat <= wle[15:8]; cv_cache <= wle[7:0]; end
				6'h04: cv_bar0 <= {wle[31:2], 2'b11};              // I/O, configured as FFFFFFFF
				6'h05: cv_bar1 <= {wle[31:12], 12'h0};             // registers, 4 KB
				6'h06: cv_bar2 <= {wle[31:26], 26'h0};             // VRAM, 64 MB
				default: ;
			endcase
		end
	end

	// the answer, in the next cycle
	case (addr[23:21])
		3'd4, 3'd5: rdata <= config_addr;
		3'd6:       rdata <= present ? bswap32(hdr) : 32'hFFFF_FFFF;   // PCI spec 6.1
		default:    rdata <= 32'h0;   // I/O space (dingusppc: a machine check), interrupt acknowledge
	endcase

	if (reset) begin
		config_addr  <= 32'h0;
		bd_lat       <= 8'h0;
		bd_addr_mask <= 32'h0000_000C;    // 3 << (bridge 1 * 2)
		bd_mode      <= 32'h0000_0007;    // (bridge 1 << 2) | 3
		bd_hold      <= 32'h0000_0008;
		gc_cmd       <= 16'h0;
		gc_stat      <= 16'h0200;          // DEVSEL timing
		gc_lat       <= 8'h0;
		gc_cache     <= 8'h08;
		gc_bar0      <= 32'h0;
		cv_cmd       <= 16'h0;
		cv_stat      <= 16'h0;
		cv_lat       <= 8'h0;
		cv_cache     <= 8'h0;
		cv_bar0      <= 32'h0000_0003;
		cv_bar1      <= 32'h0;
		cv_bar2      <= 32'h0;
	end
end

endmodule

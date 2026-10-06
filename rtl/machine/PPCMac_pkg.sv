//============================================================================
//
//  PPCMac - the machine around the CPU
//  Shared helpers: how a device access's byte enables map to the sizes and
//  byte lanes dingusppc's devices see
//
//  The CPU's memory port carries a device access as one word with four byte
//  enables; the byte at the lowest address is be[3] and bits 31-24. A device
//  in dingusppc is called with an offset and a size (1, 2 or 4) and returns a
//  number of that size. These helpers convert between the two, so that each
//  device stub can be written exactly as the dingusppc device it follows.
//
//============================================================================

package PPCMac_pkg;

	// a byte-wide register (VIA, SCC, NVRAM, ...) read with any size: dingusppc
	// returns the byte as a number of the access's size, so a word read sees
	// it in bits 7-0, a halfword read in the low byte of its halfword, and a
	// byte read in its own lane
	function automatic logic [31:0] byte_reg_rdata(input logic [3:0] be, input logic [7:0] b);
		case (be)
			4'b1111:          byte_reg_rdata = {24'h0, b};
			4'b1100, 4'b0011: byte_reg_rdata = {8'h0, b, 8'h0, b};
			default:          byte_reg_rdata = {b, b, b, b};
		endcase
	endfunction

	// the byte a write to a byte-wide register stores: dingusppc truncates the
	// value to its low byte, which is the access's last lane
	function automatic logic [7:0] byte_reg_wdata(input logic [3:0] be, input logic [31:0] w);
		if (be[0])      byte_reg_wdata = w[7:0];
		else if (be[1]) byte_reg_wdata = w[15:8];
		else if (be[2]) byte_reg_wdata = w[23:16];
		else            byte_reg_wdata = w[31:24];
	endfunction

	// the byte lane of a single-byte access, 0 for the lowest address
	function automatic logic [1:0] first_lane(input logic [3:0] be);
		if (be[3])      first_lane = 2'd0;
		else if (be[2]) first_lane = 2'd1;
		else if (be[1]) first_lane = 2'd2;
		else            first_lane = 2'd3;
	endfunction

	function automatic logic [31:0] bswap32(input logic [31:0] w);
		bswap32 = {w[7:0], w[15:8], w[23:16], w[31:24]};
	endfunction

	// a word register written with byte enables
	function automatic logic [31:0] merge_be(input logic [31:0] old, input logic [31:0] w, input logic [3:0] be);
		merge_be = {be[3] ? w[31:24] : old[31:24], be[2] ? w[23:16] : old[23:16],
		            be[1] ? w[15:8]  : old[15:8],  be[0] ? w[7:0]   : old[7:0]};
	endfunction

endpackage

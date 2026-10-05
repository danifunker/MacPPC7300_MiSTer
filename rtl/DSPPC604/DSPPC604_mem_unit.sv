//============================================================================
//
//  DSPPC604 - PowerPC 604-class CPU core
//  Data memory access unit
//
//  Turns one load or store of 1 to 4 bytes at any address into one or two
//  word-aligned bus accesses, and converts between register values and bytes
//  in memory (big-endian, byte-reversed, sign-extended, or the left-justified
//  bytes of the string instructions).
//
//  Handshake: the requester holds req_valid and the request steady until
//  resp_valid, which is high for one cycle. A store has been written, and a
//  load's rdata is valid, in that cycle.
//
//  Bus: word-aligned address, four byte enables. be[3] and bits 31:24 are the
//  byte at the lowest address. req is held with a stable request until a
//  cycle with gnt; one rvalid follows each granted request, at least one
//  cycle later.
//
//============================================================================

module DSPPC604_mem_unit
(
	input  logic        clk,
	input  logic        reset,

	input  logic        req_valid,
	input  logic        we,
	input  logic [31:0] addr,
	input  logic [2:0]  nbytes,      // 1 to 4
	input  logic        sext,        // load: sign-extend a halfword
	input  logic        brev,        // byte-reversed
	input  logic        ljust,       // string: bytes at the top of the register
	input  logic [31:0] wdata,       // register value to store

	output logic        resp_valid,
	output logic [31:0] rdata,       // register value loaded

	output logic        dbus_req,
	output logic        dbus_we,
	output logic [29:0] dbus_addr,
	output logic [3:0]  dbus_be,
	output logic [31:0] dbus_wdata,
	input  logic        dbus_gnt,
	input  logic        dbus_rvalid,
	input  logic [31:0] dbus_rdata
);

typedef enum logic [1:0] {
	S_REQ0,      // first (or only) word: waiting for the grant
	S_RSP0,
	S_REQ1,      // second word of an access that crosses a word boundary
	S_RSP1
} state_t;

state_t      state;
logic [31:0] word0_q;

wire [1:0] offset = addr[1:0];
wire [2:0] last   = {1'b0, offset} + nbytes - 3'd1;   // offset of the last byte
wire       two_words  = last[2];                          // it is in the next word

// ---- store: register value to bytes, first byte in bits 31:24 --------------
logic [31:0] sbytes;

always_comb begin
	if (brev)             sbytes = (nbytes == 3'd4) ? {wdata[7:0], wdata[15:8], wdata[23:16], wdata[31:24]}
	                                               : {wdata[7:0], wdata[15:8], 16'd0};
	else if (ljust)       sbytes = wdata;
	else if (nbytes == 3'd1) sbytes = {wdata[7:0], 24'd0};
	else if (nbytes == 3'd2) sbytes = {wdata[15:0], 16'd0};
	else                  sbytes = wdata;
end

// the bytes placed in a two-word window
wire [63:0] wwin  = {sbytes, 32'd0} >> {offset, 3'b000};
wire [7:0]  ones  = ~(8'hFF >> nbytes);
wire [7:0]  bewin = ones >> offset;

wire second = (state == S_REQ1) | (state == S_RSP1);

assign dbus_req   = (req_valid & (state == S_REQ0)) | (state == S_REQ1);
assign dbus_we    = we;
assign dbus_addr  = addr[31:2] + {29'd0, second};
assign dbus_be    = second ? bewin[3:0] : bewin[7:4];
assign dbus_wdata = second ? wwin[31:0] : wwin[63:32];

// ---- load: bytes to register value ------------------------------------------
wire [63:0] rwin   = (state == S_RSP1) ? {word0_q, dbus_rdata} : {dbus_rdata, 32'd0};
wire [63:0] rshift = rwin << {offset, 3'b000};
wire [31:0] lmask  = ~(32'hFFFFFFFF >> {nbytes, 3'b000});
wire [31:0] lbytes = rshift[63:32] & lmask;

always_comb begin
	if (brev)                rdata = (nbytes == 3'd4) ? {lbytes[7:0], lbytes[15:8], lbytes[23:16], lbytes[31:24]}
	                                                  : {16'd0, lbytes[23:16], lbytes[31:24]};
	else if (ljust)          rdata = lbytes;
	else if (nbytes == 3'd1) rdata = {24'd0, lbytes[31:24]};
	else if (nbytes == 3'd2) rdata = {{16{sext & lbytes[31]}}, lbytes[31:16]};
	else                     rdata = lbytes;
end

assign resp_valid = dbus_rvalid & (((state == S_RSP0) & ~two_words) | (state == S_RSP1));

always_ff @(posedge clk) begin
	case (state)
		S_REQ0: if (req_valid & dbus_gnt) state <= S_RSP0;
		S_RSP0: if (dbus_rvalid) begin
			word0_q <= dbus_rdata;
			state   <= two_words ? S_REQ1 : S_REQ0;
		end
		S_REQ1: if (dbus_gnt) state <= S_RSP1;
		default: if (dbus_rvalid) state <= S_REQ0;
	endcase

	if (reset) state <= S_REQ0;
end

endmodule

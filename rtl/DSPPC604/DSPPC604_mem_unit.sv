//============================================================================
//
//  DSPPC604 - PowerPC 604-class CPU core
//  Data memory access unit
//
//  Turns one load or store into one or two word-aligned bus accesses, and
//  converts between register values and bytes in memory (big-endian,
//  byte-reversed, sign-extended, or the left-justified bytes of the string
//  instructions).
//
//    1 to 4 bytes   at any address; two bus accesses if a word boundary is
//                   crossed
//    8 bytes        a double, at a word-aligned address only (the 604 takes
//                   an alignment exception otherwise); always two accesses
//    kind           other than a load or store (the cache instructions): one
//                   request, which the cache carries out; no data moves
//
//  Handshake: the requester holds req_valid and the request steady until
//  resp_valid, which is high for one cycle. A store has been written, and a
//  load's rdata is valid, in that cycle. With resp_fault the access was not
//  made (or only its first word was) and the requester takes a DSI.
//
//  Bus: word-aligned address, four byte enables. be[3] and bits 31:24 are the
//  byte at the lowest address. req is held with a stable request until a
//  cycle with gnt; one rvalid follows each granted request, at least one
//  cycle later. rvalid with fault means the word could not be translated.
//
//============================================================================

module DSPPC604_mem_unit
(
	input  logic        clk,
	input  logic        reset,

	input  logic        req_valid,
	input  logic        we,
	input  DSPPC604_pkg::ck_t kind,
	input  logic [31:0] addr,
	input  logic [3:0]  nbytes,      // 1 to 4, or 8
	input  logic        sext,        // load: sign-extend a halfword
	input  logic        brev,        // byte-reversed
	input  logic        ljust,       // string: bytes at the top of the register
	input  logic [63:0] wdata,       // value to store (low word unless 8 bytes)

	output logic        resp_valid,
	output logic        resp_fault,
	output logic [63:0] rdata,       // value loaded (low word unless 8 bytes)

	output logic        dbus_req,
	output logic        dbus_we,
	output DSPPC604_pkg::ck_t dbus_kind,
	output logic [29:0] dbus_addr,
	output logic [3:0]  dbus_be,
	output logic [31:0] dbus_wdata,
	input  logic        dbus_gnt,
	input  logic        dbus_rvalid,
	input  logic        dbus_fault,
	input  logic [31:0] dbus_rdata
);

import DSPPC604_pkg::*;

typedef enum logic [1:0] {
	S_REQ0,      // first (or only) word: waiting for the grant
	S_RSP0,
	S_REQ1,      // second word
	S_RSP1
} state_t;

state_t      state;
logic [31:0] word0_q;

wire       dword     = nbytes[3];
wire [2:0] n         = nbytes[2:0];
wire [1:0] offset    = addr[1:0];
wire       touch     = (kind != CK_WORD);
wire [2:0] last      = {1'b0, offset} + n - 3'd1;      // offset of the last byte
wire       two_words = ~touch & (dword | last[2]);
wire [31:0] w        = wdata[31:0];

// ---- store: register value to bytes, first byte in bits 31:24 --------------
logic [31:0] sbytes;

always_comb begin
	if (brev)           sbytes = (n == 3'd4) ? {w[7:0], w[15:8], w[23:16], w[31:24]}
	                                         : {w[7:0], w[15:8], 16'd0};
	else if (ljust)     sbytes = w;
	else if (n == 3'd1) sbytes = {w[7:0], 24'd0};
	else if (n == 3'd2) sbytes = {w[15:0], 16'd0};
	else                sbytes = w;
end

// the bytes placed in a two-word window
wire [63:0] wwin  = dword ? wdata : ({sbytes, 32'd0} >> {offset, 3'b000});
wire [7:0]  ones  = ~(8'hFF >> n);
wire [7:0]  bewin = dword ? 8'hFF : (ones >> offset);

wire second = (state == S_REQ1) | (state == S_RSP1);

assign dbus_req   = (req_valid & (state == S_REQ0)) | (state == S_REQ1);
assign dbus_we    = we;
assign dbus_kind  = kind;
assign dbus_addr  = addr[31:2] + {29'd0, second};
assign dbus_be    = touch ? 4'b0000 : second ? bewin[3:0] : bewin[7:4];
assign dbus_wdata = second ? wwin[31:0] : wwin[63:32];

// ---- load: bytes to register value ------------------------------------------
wire [63:0] rwin   = (state == S_RSP1) ? {word0_q, dbus_rdata} : {dbus_rdata, 32'd0};
wire [63:0] rshift = rwin << {offset, 3'b000};
wire [31:0] lmask  = ~(32'hFFFFFFFF >> {n, 3'b000});
wire [31:0] lbytes = rshift[63:32] & lmask;

logic [31:0] lword;

always_comb begin
	if (brev)           lword = (n == 3'd4) ? {lbytes[7:0], lbytes[15:8], lbytes[23:16], lbytes[31:24]}
	                                        : {16'd0, lbytes[23:16], lbytes[31:24]};
	else if (ljust)     lword = lbytes;
	else if (n == 3'd1) lword = {24'd0, lbytes[31:24]};
	else if (n == 3'd2) lword = {{16{sext & lbytes[31]}}, lbytes[31:16]};
	else                lword = lbytes;
end

assign rdata      = dword ? rwin : {32'd0, lword};
assign resp_fault = dbus_rvalid & dbus_fault;
assign resp_valid = dbus_rvalid & (dbus_fault | ((state == S_RSP0) & ~two_words) | (state == S_RSP1));

always_ff @(posedge clk) begin
	case (state)
		S_REQ0: if (req_valid & dbus_gnt) state <= S_RSP0;
		S_RSP0: if (dbus_rvalid) begin
			word0_q <= dbus_rdata;
			state   <= (two_words & ~dbus_fault) ? S_REQ1 : S_REQ0;
		end
		S_REQ1: if (dbus_gnt) state <= S_RSP1;
		default: if (dbus_rvalid) state <= S_REQ0;
	endcase

	if (reset) state <= S_REQ0;
end

endmodule

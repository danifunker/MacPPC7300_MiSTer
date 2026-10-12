//============================================================================
//
//  DSPPC604 - PowerPC 604-class CPU core
//  Half of one way of a cache's data: four of each line's eight words (the
//  even ones, or the odd ones), written a line's half at a time, read a
//  word at a time
//
//  The write port is a row of four words, one row per set, with a write
//  enable per word (a fill writes all four, a store one). The read port
//  is one word: address {set, word slot}; slot s is bits 32s+31 downward
//  of the row. The RAM then picks the word, so that a read does not bring
//  the whole line out to be chosen from by multiplexers (the slowest part
//  of a load's answer). A read of the row being written gives the old
//  data; DSPPC604_cache forwards the written words itself.
//
//  Quartus 17 does not infer a mixed-width RAM with write enables, so the
//  FPGA build instantiates altsyncram (M10K: 128-bit write with byte
//  enables, 32-bit read); Verilator uses the equivalent model.
//
//============================================================================

module DSPPC604_cache_ram
#(
	parameter int IDXW = 7                   // 128 sets; 8 for 256
)
(
	input  logic            clk,
	input  logic [IDXW+1:0] raddr,           // {set, word slot}
	output logic [31:0]     q,
	input  logic [3:0]      we,              // one per word slot
	input  logic [IDXW-1:0] waddr,
	input  logic [127:0]    d                // slot s in bits 32s+31 downward
);

`ifdef VERILATOR
logic [127:0] ram [1 << IDXW];
always_ff @(posedge clk) begin
	q <= ram[raddr[IDXW+1:2]][32*raddr[1:0] +: 32];
	for (int s = 0; s < 4; s++)
		if (we[s]) ram[waddr][32*s +: 32] <= d[32*s +: 32];
end
`else
altsyncram #(
	.operation_mode ("DUAL_PORT"),
	.width_a (128), .widthad_a (IDXW), .numwords_a (1 << IDXW),
	.width_b (32), .widthad_b (IDXW + 2), .numwords_b (4 << IDXW),
	.width_byteena_a (16), .byte_size (8),
	.outdata_reg_b ("UNREGISTERED"),
	.address_reg_b ("CLOCK0"),
	.rdcontrol_reg_b ("CLOCK0"),
	.read_during_write_mode_mixed_ports ("OLD_DATA"),
	.ram_block_type ("M10K"),
	.intended_device_family ("Cyclone V"),
	.lpm_type ("altsyncram")
) ram (
	.clock0 (clk),
	.address_a (waddr), .data_a (d), .wren_a (|we),
	.byteena_a ({{4{we[3]}}, {4{we[2]}}, {4{we[1]}}, {4{we[0]}}}),
	.address_b (raddr), .q_b (q),
	.aclr0 (1'b0), .aclr1 (1'b0), .addressstall_a (1'b0), .addressstall_b (1'b0),
	.byteena_b (1'b1), .clock1 (1'b1), .clocken0 (1'b1), .clocken1 (1'b1),
	.clocken2 (1'b1), .clocken3 (1'b1), .data_b ({32{1'b1}}), .eccstatus (),
	.q_a (), .rden_a (1'b1), .rden_b (1'b1), .wren_b (1'b0)
);
`endif

endmodule

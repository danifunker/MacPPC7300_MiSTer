//============================================================================
//
//  DSPPC604 - PowerPC 604-class CPU core
//  One way of a cache's data: 128 lines of 32 bytes, as eight word RAMs
//
//  Each word of the line is a RAM of its own with its own write enable, so
//  that a store writes one whole word and a fill all eight: Quartus 17
//  infers these, and not a byte-enabled write to a wide array. Word j of
//  the line is bits 32j+31 downward; the cache puts the lowest address in
//  word 7. Read and write addresses never coincide in the same cycle
//  (DSPPC604_cache sees to that), so no read-during-write logic is asked
//  for.
//
//============================================================================

module DSPPC604_cache_ram
(
	input  logic         clk,
	input  logic [6:0]   raddr,
	output logic [255:0] q,
	input  logic [7:0]   we,                 // one per word
	input  logic [6:0]   waddr,
	input  logic [255:0] d
);

genvar gj;
generate
	for (gj = 0; gj < 8; gj++) begin : word
		(* ramstyle = "no_rw_check" *) logic [31:0] ram [128];
		always_ff @(posedge clk) begin
			if (we[gj]) ram[waddr] <= d[32*gj +: 32];
			q[32*gj +: 32] <= ram[raddr];
		end
	end
endgenerate

endmodule

//============================================================================
//
//  DSPPC604 - PowerPC 604-class CPU core
//  Leading zero counter
//
//  Counts the zero bits above the most significant one. An all-zero input
//  gives WIDTH. Built from 16-bit groups so the logic stays shallow for wide
//  inputs.
//
//============================================================================

module DSPPC604_lzc
#(
	parameter int WIDTH = 64
)
(
	input  logic [WIDTH-1:0]           in,
	output logic [$clog2(WIDTH+1)-1:0] count
);

localparam int GROUPS = (WIDTH + 15) / 16;
localparam int TOTAL  = GROUPS * 16;

// pad below with ones: the count then never runs past the real bits
logic [TOTAL-1:0] padded;

always_comb begin
	padded = '1;
	padded[TOTAL-1 -: WIDTH] = in;
end

function automatic logic [3:0] lzc16(input logic [15:0] v);
	begin
		lzc16 = 4'd0;
		for (int i = 0; i < 16; i++)
			if (v[i]) lzc16 = 4'd15 - i[3:0];
	end
endfunction

logic [GROUPS-1:0] nonzero;
logic [3:0]        grp_lz [GROUPS];

always_comb begin
	for (int g = 0; g < GROUPS; g++) begin
		// group 0 is the most significant
		nonzero[g] = |padded[TOTAL-1-16*g -: 16];
		grp_lz[g]  = lzc16(padded[TOTAL-1-16*g -: 16]);
	end
end

// integer arithmetic on purpose: the result always fits in count
/* verilator lint_off WIDTH */
always_comb begin
	count = WIDTH;
	for (int g = GROUPS - 1; g >= 0; g--)
		if (nonzero[g]) count = 16 * g + grp_lz[g];
end
/* verilator lint_on WIDTH */

endmodule

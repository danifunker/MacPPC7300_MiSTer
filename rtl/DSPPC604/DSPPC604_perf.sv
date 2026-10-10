//============================================================================
//
//  DSPPC604 - PowerPC 604-class CPU core
//  Performance counters: one 32-bit counter per event, free running, for the
//  cycle accounting (DSPPC604's PERF parameter names the events)
//
//============================================================================

module DSPPC604_perf
#(
	parameter int N = 28
)
(
	input  logic             clk,
	input  logic             reset,
	input  logic [N-1:0]     ev,
	output logic [N-1:0][31:0] cnt
);

always_ff @(posedge clk) begin
	for (int i = 0; i < N; i++)
		if (ev[i]) cnt[i] <= cnt[i] + 32'd1;
	if (reset) cnt <= '0;
end

endmodule

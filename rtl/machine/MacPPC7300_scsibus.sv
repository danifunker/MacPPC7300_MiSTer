//============================================================================
//
//  MacPPC7300 - the machine around the CPU
//  The internal SCSI bus: MESH's lines and the targets', wired together
//
//  Each side sees its own lines at once and the other side's a clock later,
//  as a cable would: at 100 MHz a target's state reached MESH's FIFO, and
//  MESH's data byte the targets' selection, through the wired OR in one
//  clock (-2.3 and -3.5 ns). The protocol does not notice: REQ and ACK are
//  interlocked and every line takes the same clock, so data still comes
//  with its strobe; a byte's handshake is two clocks longer.
//
//============================================================================

module MacPPC7300_scsibus
(
	input  logic       clk,

	// MESH's drive and the targets', 1 asserted
	input  logic       mesh_rst, mesh_bsy, mesh_sel, mesh_atn, mesh_ack, mesh_req, mesh_msg, mesh_cd, mesh_io,
	input  logic [7:0] mesh_db,
	input  logic       t_bsy, t_req, t_msg, t_cd, t_io,
	input  logic [7:0] t_db,

	// the bus as MESH sees it
	output logic       scsi_rst, scsi_bsy, scsi_sel, scsi_atn, scsi_ack, scsi_req, scsi_msg, scsi_cd, scsi_io,
	output logic [7:0] scsi_db,

	// the bus as the targets see it
	output logic       b_rst, b_bsy, b_sel, b_atn, b_ack,
	output logic [7:0] b_db
);

logic       m_rst, m_bsy, m_sel, m_atn, m_ack;
logic [7:0] m_db;
logic       q_bsy, q_req, q_msg, q_cd, q_io;
logic [7:0] q_db;
always_ff @(posedge clk) begin
	{m_rst, m_bsy, m_sel, m_atn, m_ack, m_db} <= {mesh_rst, mesh_bsy, mesh_sel, mesh_atn, mesh_ack, mesh_db};
	{q_bsy, q_req, q_msg, q_cd, q_io, q_db}   <= {t_bsy, t_req, t_msg, t_cd, t_io, t_db};
end

assign scsi_rst = mesh_rst;
assign scsi_bsy = mesh_bsy | q_bsy;
assign scsi_sel = mesh_sel;
assign scsi_atn = mesh_atn;
assign scsi_ack = mesh_ack;
assign scsi_req = mesh_req | q_req;
assign scsi_msg = mesh_msg | q_msg;
assign scsi_cd  = mesh_cd  | q_cd;
assign scsi_io  = mesh_io  | q_io;
assign scsi_db  = mesh_db  | q_db;

assign b_rst = m_rst;
assign b_bsy = m_bsy | t_bsy;
assign b_sel = m_sel;
assign b_atn = m_atn;
assign b_ack = m_ack;
assign b_db  = m_db | t_db;

endmodule

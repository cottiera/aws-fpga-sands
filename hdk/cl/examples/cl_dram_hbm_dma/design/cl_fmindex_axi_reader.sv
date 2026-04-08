// ============================================================================
// cl_fmindex_axi_reader.sv — Response-driven AXI4 read bridge for cl_fmindex
//
// Translates cl_fmindex's word-addressed RAM interface into 512-bit AXI4 reads
// against HBM via the existing crossbar.  Data is delivered as soon as the AXI
// response arrives (ram_data_valid pulses high for one cycle), eliminating the
// fixed-latency shift registers that caused timing violations.
//
// Architecture:
//   ram_req ──> addr_fifo ──> AXI AR channel (64-byte reads, ARID=0)
//   ram_req ──> offset_fifo (4-bit DWORD selector, small depth)
//
//   AXI R channel ──> extract DWORD using offset_fifo head
//                 ──> ram_data + ram_data_valid
// ============================================================================

module cl_fmindex_axi_reader #(
    parameter int RAM_FIFO_DEPTH = 4
) (
    input  logic        clk,
    input  logic        rst_n,

    // cl_fmindex RAM interface
    input  logic        ram_req,
    input  logic [31:0] ram_addr,
    output logic [31:0] ram_data,
    output logic        ram_data_valid,

    // HBM base address (byte address in crossbar space)
    input  logic [63:0] hbm_base_addr,

    // AXI4 master toward crossbar (512-bit data)
    axi_bus_t.slave     cl_axi_mstr_bus
);

// -------------------------------------------------------------------------
// Address FIFO — buffers read requests when AXI AR backpressures
// -------------------------------------------------------------------------

localparam int ADDR_FIFO_SLOTS = (RAM_FIFO_DEPTH < 2) ? 2 : RAM_FIFO_DEPTH;
localparam int AF_PTR_W = $clog2(ADDR_FIFO_SLOTS);

logic [63:0] addr_fifo [ADDR_FIFO_SLOTS];
logic [AF_PTR_W:0] af_wr, af_rd;

wire [AF_PTR_W:0] af_count = af_wr - af_rd;
wire af_empty = (af_wr == af_rd);
wire af_full  = (af_count >= (AF_PTR_W+1)'(ADDR_FIFO_SLOTS));

logic [63:0] byte_addr;
assign byte_addr = hbm_base_addr + ({32'b0, ram_addr} << 2);

always_ff @(posedge clk) begin
    if (!rst_n) begin
        af_wr <= '0;
        af_rd <= '0;
    end else begin
        if (ram_req && !af_full) begin
            addr_fifo[af_wr[AF_PTR_W-1:0]] <= byte_addr & ~64'h3F;
            af_wr <= af_wr + 1'b1;
        end
        if (!af_empty && cl_axi_mstr_bus.arready && cl_axi_mstr_bus.arvalid) begin
            af_rd <= af_rd + 1'b1;
        end
    end
end

// -------------------------------------------------------------------------
// AXI AR channel — drain from address FIFO
// -------------------------------------------------------------------------

assign cl_axi_mstr_bus.arid    = 16'b0;
assign cl_axi_mstr_bus.araddr  = addr_fifo[af_rd[AF_PTR_W-1:0]];
assign cl_axi_mstr_bus.arlen   = 8'h00;
assign cl_axi_mstr_bus.arsize  = 3'b110;  // 64 bytes
assign cl_axi_mstr_bus.arvalid = !af_empty;
assign cl_axi_mstr_bus.arburst = 2'b01;   // INCR

// -------------------------------------------------------------------------
// Offset FIFO — which 32-bit word to extract from 512b cache line
//
// Pushed when ram_req fires, popped when AXI R response arrives.
// AXI in-order guarantee (single ARID=0) ensures 1:1 correspondence.
// -------------------------------------------------------------------------

localparam int OF_SLOTS = (RAM_FIFO_DEPTH < 2) ? 2 : RAM_FIFO_DEPTH;
localparam int OF_PTR_W = $clog2(OF_SLOTS);

logic [3:0] offset_fifo [OF_SLOTS];
logic [OF_PTR_W:0] of_wr, of_rd;

wire of_empty = (of_wr == of_rd);

wire axi_resp_fire = cl_axi_mstr_bus.rvalid && cl_axi_mstr_bus.rready;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        of_wr <= '0;
        of_rd <= '0;
    end else begin
        if (ram_req) begin
            offset_fifo[of_wr[OF_PTR_W-1:0]] <= byte_addr[5:2];
            of_wr <= of_wr + 1'b1;
        end
        if (axi_resp_fire && !of_empty) begin
            of_rd <= of_rd + 1'b1;
        end
    end
end

wire [3:0] of_head = offset_fifo[of_rd[OF_PTR_W-1:0]];

// -------------------------------------------------------------------------
// Response delivery — extract DWORD directly from AXI R data
//
// No buffering FIFO needed: we are always ready to accept (rready=1)
// and process the response in the same cycle it arrives.
// -------------------------------------------------------------------------

assign cl_axi_mstr_bus.rready = 1'b1;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        ram_data       <= 32'd0;
        ram_data_valid <= 1'b0;
    end else begin
        ram_data_valid <= 1'b0;
        if (axi_resp_fire && !of_empty) begin
            ram_data       <= cl_axi_mstr_bus.rdata[of_head*32 +: 32];
            ram_data_valid <= 1'b1;
        end
    end
end

// -------------------------------------------------------------------------
// Tie off AXI write channels (read-only master)
// -------------------------------------------------------------------------

assign cl_axi_mstr_bus.awid    = 16'b0;
assign cl_axi_mstr_bus.awaddr  = 64'b0;
assign cl_axi_mstr_bus.awlen   = 8'b0;
assign cl_axi_mstr_bus.awsize  = 3'b0;
assign cl_axi_mstr_bus.awvalid = 1'b0;
assign cl_axi_mstr_bus.awburst = 2'b0;

assign cl_axi_mstr_bus.wid     = 16'b0;
assign cl_axi_mstr_bus.wdata   = 512'b0;
assign cl_axi_mstr_bus.wstrb   = 64'b0;
assign cl_axi_mstr_bus.wlast   = 1'b0;
assign cl_axi_mstr_bus.wvalid  = 1'b0;

assign cl_axi_mstr_bus.bready  = 1'b1;

endmodule

// ============================================================================
// cl_fmindex_axi_reader.sv — Fixed-latency AXI4 read bridge for cl_fmindex
//
// Translates cl_fmindex's word-addressed RAM interface into 512-bit AXI4 reads
// against HBM via the existing crossbar.  The bridge guarantees that ram_data
// is valid exactly PIPE_DEPTH = RAM_DELAY_CYCLES + 1 clock edges after ram_req,
// matching the shift-register timing inside cl_fmindex.
//
// Architecture:
//   ram_req ──> addr_fifo ──> AXI AR channel (64-byte reads, ARID=0)
//
//   ram_req ──> delivery shift register [RAM_DELAY_CYCLES stages]
//                   + registered ram_data output = PIPE_DEPTH total
//
//   AXI R channel ──> response FIFO (in-order via ARID=0)
//
//   When delivery shift register output fires:
//       ram_data <= extract_dword(resp_fifo.pop(), saved_byte_offset)
// ============================================================================

module cl_fmindex_axi_reader #(
    parameter int RAM_DELAY_CYCLES = 64,
    parameter int RAM_FIFO_DEPTH   = 4
) (
    input  logic        clk,
    input  logic        rst_n,

    // cl_fmindex RAM interface
    input  logic        ram_req,
    input  logic [31:0] ram_addr,
    output logic [31:0] ram_data,

    // HBM base address (byte address in crossbar space)
    input  logic [63:0] hbm_base_addr,

    // AXI4 master toward crossbar (512-bit data)
    axi_bus_t.slave     cl_axi_mstr_bus
);

localparam int PIPE_DEPTH  = (RAM_DELAY_CYCLES < 1) ? 1 : (RAM_DELAY_CYCLES + 1);
localparam int DEL_DEPTH   = (RAM_DELAY_CYCLES < 1) ? 1 : RAM_DELAY_CYCLES;

// -------------------------------------------------------------------------
// Address FIFO — buffers read requests when AXI AR backpressures
//
// Depth matches the max outstanding requests FM_Index will issue.
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
// Delivery shift register — DEL_DEPTH = RAM_DELAY_CYCLES stages
//
// Together with the registered ram_data output, this gives exactly
// PIPE_DEPTH = RAM_DELAY_CYCLES + 1 cycles of total latency.
// -------------------------------------------------------------------------

logic del_pipe [DEL_DEPTH];

always_ff @(posedge clk) begin
    if (!rst_n) begin
        for (int i = 0; i < DEL_DEPTH; i++)
            del_pipe[i] <= 1'b0;
    end else begin
        del_pipe[0] <= ram_req;
        for (int i = 1; i < DEL_DEPTH; i++)
            del_pipe[i] <= del_pipe[i-1];
    end
end

wire deliver_now = del_pipe[DEL_DEPTH-1];

// -------------------------------------------------------------------------
// DWORD offset shift register — which 32-bit word to extract from 512b line
// -------------------------------------------------------------------------

logic [3:0] offset_pipe [DEL_DEPTH];

always_ff @(posedge clk) begin
    if (!rst_n) begin
        for (int i = 0; i < DEL_DEPTH; i++)
            offset_pipe[i] <= 4'd0;
    end else begin
        offset_pipe[0] <= byte_addr[5:2];
        for (int i = 1; i < DEL_DEPTH; i++)
            offset_pipe[i] <= offset_pipe[i-1];
    end
end

wire [3:0] deliver_offset = offset_pipe[DEL_DEPTH-1];

// -------------------------------------------------------------------------
// Response FIFO — buffers AXI read data until delivery time
// -------------------------------------------------------------------------

localparam int RESP_FIFO_SLOTS = PIPE_DEPTH + 2;
localparam int RF_PTR_W = $clog2(RESP_FIFO_SLOTS);

logic [511:0] resp_fifo [RESP_FIFO_SLOTS];
logic [RF_PTR_W:0] rf_wr, rf_rd;

wire [RF_PTR_W:0] rf_count = rf_wr - rf_rd;
wire rf_full  = (rf_count >= (RF_PTR_W+1)'(RESP_FIFO_SLOTS));
wire rf_empty = (rf_wr == rf_rd);

assign cl_axi_mstr_bus.rready = !rf_full;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        rf_wr <= '0;
        rf_rd <= '0;
    end else begin
        if (cl_axi_mstr_bus.rvalid && cl_axi_mstr_bus.rready) begin
            resp_fifo[rf_wr[RF_PTR_W-1:0]] <= cl_axi_mstr_bus.rdata;
            rf_wr <= rf_wr + 1'b1;
        end
        if (deliver_now && !rf_empty) begin
            rf_rd <= rf_rd + 1'b1;
        end
    end
end

// -------------------------------------------------------------------------
// Output mux — extract the correct DWORD from the response FIFO head
// -------------------------------------------------------------------------

wire [511:0] head_data = resp_fifo[rf_rd[RF_PTR_W-1:0]];

always_ff @(posedge clk) begin
    if (!rst_n) begin
        ram_data <= 32'd0;
    end else if (deliver_now && !rf_empty) begin
        ram_data <= head_data[deliver_offset*32 +: 32];
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

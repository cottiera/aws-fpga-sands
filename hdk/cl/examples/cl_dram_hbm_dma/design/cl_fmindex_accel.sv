// ============================================================================
// cl_fmindex_accel.sv — FM-index accelerator wrapper
//
// Bridges the OCL cfg_bus register interface to the pipelined cl_fmindex core
// and its cl_fmindex_axi_reader HBM bridge.
//
// Register map (256-byte OCL slot, byte offsets):
//   0x00  CTRL         RW  bit 0: submit (W1-auto-clear)
//                          bit 1: result_pending (R; W1C)
//                          bit 2: boot_done (R)
//                          bit 3: fmindex_reset (RW; 1=hold reset)
//   0x04  PAT_LEN      RW  pattern length (max PAT_MAX_LEN)
//   0x08  QUERY_ID     RW  32-bit query id
//   0x0C  RESULT_STATUS R   bit 0: done, bit 1: fail
//   0x10  RESULT_L      R   l_out
//   0x14  RESULT_R      R   r_out
//   0x18  RESULT_QID    R   result query_id
//   0x1C  HBM_BASE_LO   RW  lower 32 bits of HBM base byte address
//   0x20  HBM_BASE_HI   RW  upper 32 bits of HBM base byte address
//   0x40-0x9C PATTERN[0..23] RW  pattern data (24 x 32-bit words)
// ============================================================================

module cl_fmindex_accel #(
    parameter int PAT_MAX_LEN     = 150,
    parameter int NUM_SLOTS       = 4,
    parameter int RAM_FIFO_DEPTH  = 4,
    parameter int RAM_DELAY_CYCLES = 64
) (
    input  logic       clk,
    input  logic       rst_n,

    cfg_bus_t.slave    cfg_bus,
    axi_bus_t.slave    cl_axi_mstr_bus
);

localparam int CHAR_WIDTH = 3;
localparam int PAT_BITS   = CHAR_WIDTH * PAT_MAX_LEN;
localparam int PAT_WORDS  = (PAT_BITS + 31) / 32;
localparam int PAT_LEN_W  = $clog2(PAT_MAX_LEN + 1);

// -------------------------------------------------------------------------
// cfg_bus handshake
// -------------------------------------------------------------------------

logic        cfg_wr_stretch;
logic        cfg_rd_stretch;
logic [7:0]  cfg_addr_q;
logic [31:0] cfg_wdata_q;

always_ff @(posedge clk)
    if (!rst_n) begin
        cfg_wr_stretch <= 1'b0;
        cfg_rd_stretch <= 1'b0;
        cfg_addr_q     <= 8'd0;
        cfg_wdata_q    <= 32'd0;
    end else begin
        cfg_wr_stretch <= cfg_bus.wr || (cfg_wr_stretch && !cfg_bus.ack);
        cfg_rd_stretch <= cfg_bus.rd || (cfg_rd_stretch && !cfg_bus.ack);
        if (cfg_bus.wr || cfg_bus.rd) begin
            cfg_addr_q  <= cfg_bus.addr[7:0];
            cfg_wdata_q <= cfg_bus.wdata[31:0];
        end
    end

always_ff @(posedge clk)
    if (!rst_n)
        cfg_bus.ack <= 1'b0;
    else
        cfg_bus.ack <= ((cfg_wr_stretch || cfg_rd_stretch) && !cfg_bus.ack);

wire cfg_wr_fire = cfg_wr_stretch & ~cfg_bus.ack;

// -------------------------------------------------------------------------
// Registers
// -------------------------------------------------------------------------

logic                fmindex_reset_q;
logic                submit_q;
logic                result_pending_q;
logic                boot_done_q;
logic [PAT_LEN_W-1:0] pat_len_q;
logic [31:0]         query_id_q;
logic [31:0]         hbm_base_lo_q;
logic [31:0]         hbm_base_hi_q;
logic [31:0]         pattern_regs [PAT_WORDS];

logic                res_done_q;
logic                res_fail_q;
logic [31:0]         res_l_q;
logic [31:0]         res_r_q;
logic [31:0]         res_qid_q;

// -------------------------------------------------------------------------
// cl_fmindex instance
// -------------------------------------------------------------------------

logic                     fm_reset;
logic                     fm_query_valid;
logic                     fm_query_ready;
logic [31:0]              fm_query_id;
logic [PAT_BITS-1:0]      fm_query_pattern;
logic [PAT_LEN_W-1:0]    fm_query_pat_len;

logic                     fm_ram_req;
logic [31:0]              fm_ram_addr;
logic [31:0]              fm_ram_data;

logic                     fm_result_valid;
logic                     fm_result_done;
logic                     fm_result_fail;
logic [31:0]              fm_result_query_id;
logic [31:0]              fm_l_out;
logic [31:0]              fm_r_out;

assign fm_reset = fmindex_reset_q | ~rst_n;

// Pack pattern registers into a wide vector, then truncate to PAT_BITS
localparam int PAT_VEC_BITS = PAT_WORDS * 32;
logic [PAT_VEC_BITS-1:0] pat_wide;

always_comb begin
    pat_wide = '0;
    for (int i = 0; i < PAT_WORDS; i++)
        pat_wide[i*32 +: 32] = pattern_regs[i];
end

assign fm_query_pattern = pat_wide[PAT_BITS-1:0];

assign fm_query_pat_len = pat_len_q;
assign fm_query_id      = query_id_q;

cl_fmindex #(
    .PAT_MAX_LEN     (PAT_MAX_LEN),
    .NUM_SLOTS        (NUM_SLOTS),
    .RAM_FIFO_DEPTH   (RAM_FIFO_DEPTH),
    .RAM_DELAY_CYCLES (RAM_DELAY_CYCLES)
) FMINDEX (
    .clk              (clk),
    .reset            (fm_reset),
    .query_valid      (fm_query_valid),
    .query_id         (fm_query_id),
    .query_pattern    (fm_query_pattern),
    .query_pat_len    (fm_query_pat_len),
    .query_ready      (fm_query_ready),
    .ram_req          (fm_ram_req),
    .ram_data         (fm_ram_data),
    .ram_addr         (fm_ram_addr),
    .result_valid     (fm_result_valid),
    .result_done      (fm_result_done),
    .result_fail      (fm_result_fail),
    .result_query_id  (fm_result_query_id),
    .l_out            (fm_l_out),
    .r_out            (fm_r_out),
    .done             (),
    .fail             ()
);

// -------------------------------------------------------------------------
// cl_fmindex_axi_reader instance
// -------------------------------------------------------------------------

cl_fmindex_axi_reader #(
    .RAM_DELAY_CYCLES (RAM_DELAY_CYCLES),
    .RAM_FIFO_DEPTH   (RAM_FIFO_DEPTH)
) AXI_READER (
    .clk              (clk),
    .rst_n            (rst_n & ~fmindex_reset_q),
    .ram_req          (fm_ram_req),
    .ram_addr         (fm_ram_addr),
    .ram_data         (fm_ram_data),
    .hbm_base_addr    ({hbm_base_hi_q, hbm_base_lo_q}),
    .cl_axi_mstr_bus  (cl_axi_mstr_bus)
);

// -------------------------------------------------------------------------
// Submit pulse generation
// -------------------------------------------------------------------------

assign fm_query_valid = submit_q && fm_query_ready;

// -------------------------------------------------------------------------
// Register write logic
// -------------------------------------------------------------------------

always_ff @(posedge clk) begin
    if (!rst_n) begin
        fmindex_reset_q  <= 1'b1;
        submit_q         <= 1'b0;
        result_pending_q <= 1'b0;
        boot_done_q      <= 1'b0;
        pat_len_q        <= '0;
        query_id_q       <= 32'd0;
        hbm_base_lo_q    <= 32'h0000_0000;
        hbm_base_hi_q    <= 32'h0000_0010;
        res_done_q       <= 1'b0;
        res_fail_q       <= 1'b0;
        res_l_q          <= 32'd0;
        res_r_q          <= 32'd0;
        res_qid_q        <= 32'd0;
        for (int i = 0; i < PAT_WORDS; i++)
            pattern_regs[i] <= 32'd0;
    end else begin
        // Auto-clear submit after one cycle
        if (submit_q && fm_query_ready)
            submit_q <= 1'b0;

        // Track boot_done
        if (fm_query_ready && !fmindex_reset_q)
            boot_done_q <= 1'b1;
        if (fmindex_reset_q)
            boot_done_q <= 1'b0;

        // Latch results
        if (fm_result_valid) begin
            result_pending_q <= 1'b1;
            res_done_q       <= fm_result_done;
            res_fail_q       <= fm_result_fail;
            res_l_q          <= fm_l_out;
            res_r_q          <= fm_r_out;
            res_qid_q        <= fm_result_query_id;
        end

        // Register writes
        if (cfg_wr_fire) begin
            case (cfg_addr_q)
                8'h00: begin // CTRL
                    if (cfg_wdata_q[0]) submit_q         <= 1'b1;
                    if (cfg_wdata_q[1]) result_pending_q <= 1'b0;
                    fmindex_reset_q <= cfg_wdata_q[3];
                end
                8'h04: pat_len_q   <= cfg_wdata_q[PAT_LEN_W-1:0];
                8'h08: query_id_q  <= cfg_wdata_q;
                8'h1C: hbm_base_lo_q <= cfg_wdata_q;
                8'h20: hbm_base_hi_q <= cfg_wdata_q;
                default: begin
                    for (int i = 0; i < PAT_WORDS; i++) begin
                        if (cfg_addr_q == 8'(8'h40 + i * 4))
                            pattern_regs[i] <= cfg_wdata_q;
                    end
                end
            endcase
        end
    end
end

// -------------------------------------------------------------------------
// Register read logic
// -------------------------------------------------------------------------

// Combinational mux for pattern register reads (avoids dynamic array index)
logic [31:0] pat_rdata;
always_comb begin
    pat_rdata = 32'hdead_beef;
    for (int i = 0; i < PAT_WORDS; i++) begin
        if (cfg_addr_q == 8'(8'h40 + i * 4))
            pat_rdata = pattern_regs[i];
    end
end

always_ff @(posedge clk) begin
    case (cfg_addr_q)
        8'h00:   cfg_bus.rdata <= {28'd0, fmindex_reset_q, boot_done_q, result_pending_q, submit_q};
        8'h04:   cfg_bus.rdata <= {{(32-PAT_LEN_W){1'b0}}, pat_len_q};
        8'h08:   cfg_bus.rdata <= query_id_q;
        8'h0C:   cfg_bus.rdata <= {30'd0, res_fail_q, res_done_q};
        8'h10:   cfg_bus.rdata <= res_l_q;
        8'h14:   cfg_bus.rdata <= res_r_q;
        8'h18:   cfg_bus.rdata <= res_qid_q;
        8'h1C:   cfg_bus.rdata <= hbm_base_lo_q;
        8'h20:   cfg_bus.rdata <= hbm_base_hi_q;
        default: cfg_bus.rdata <= pat_rdata;
    endcase
end

endmodule

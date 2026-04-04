// ============================================================================
// cl_fmindex.sv — FM-index backward-search engine (multi-slot, pipelined)
//
// Copied from sands/fmindex_sv/FM_Index.sv with `define macros converted to
// localparam to avoid collisions with the HDK global include namespace.
// No algorithmic or interface changes.
// ============================================================================

module cl_fmindex #(
    parameter int PAT_MAX_LEN = 150,
    parameter int NUM_SLOTS = 4,
    parameter int RAM_FIFO_DEPTH = 4,
    parameter int RAM_DELAY_CYCLES = 64
) (
    input logic clk,
    input logic reset,

    input logic query_valid,
    input logic [31:0] query_id,
    input logic [CHAR_WIDTH*PAT_MAX_LEN-1:0] query_pattern,
    input logic [$clog2(PAT_MAX_LEN+1)-1:0] query_pat_len,
    output logic query_ready,

    output logic ram_req,
    input logic [IDX_WIDTH-1:0] ram_data,
    output logic [31:0] ram_addr,

    output logic result_valid,
    output logic result_done,
    output logic result_fail,
    output logic [31:0] result_query_id,
    output logic [IDX_WIDTH-1:0] l_out,
    output logic [IDX_WIDTH-1:0] r_out,

    output logic done,
    output logic fail
);

localparam int CHAR_WIDTH = 3;
localparam int IDX_WIDTH = 32;
localparam int HEADER_WORDS = 3;
localparam logic [31:0] INDEX_MAGIC = 32'h3144_4946; // "FID1" in little-endian bytes

localparam int PAT_IDX_W = (PAT_MAX_LEN <= 1) ? 1 : $clog2(PAT_MAX_LEN);
localparam int LOOP_COUNT_W = $clog2(PAT_MAX_LEN + 1);
localparam int SLOT_W = (NUM_SLOTS <= 1) ? 1 : $clog2(NUM_SLOTS);
localparam int REQ_FIFO_DEPTH = (RAM_FIFO_DEPTH < 1) ? 1 : RAM_FIFO_DEPTH;
localparam int PIPE_DEPTH = (RAM_DELAY_CYCLES < 1) ? 1 : (RAM_DELAY_CYCLES + 1);
localparam int FIFO_W = $clog2(REQ_FIFO_DEPTH + 1);

typedef enum logic [2:0] {
    BOOT_MAGIC_REQ,
    BOOT_MAGIC_WAIT,
    BOOT_LEN_REQ,
    BOOT_LEN_WAIT,
    BOOT_ALPHA_REQ,
    BOOT_ALPHA_WAIT,
    BOOT_FAIL,
    BOOT_DONE
} boot_state_t;

typedef enum logic [3:0] {
    SLOT_FREE,
    SLOT_READ_CHAR,
    SLOT_WAIT_OCC_L,
    SLOT_READY_OCC_R,
    SLOT_WAIT_OCC_R,
    SLOT_READY_C_BASE,
    SLOT_WAIT_C_BASE,
    SLOT_DONE,
    SLOT_FAIL
} slot_state_t;

typedef enum logic [2:0] {
    REQ_BOOT_MAGIC,
    REQ_BOOT_LEN,
    REQ_BOOT_ALPHA,
    REQ_OCC_L,
    REQ_OCC_R,
    REQ_C_BASE
} req_kind_t;

typedef struct packed {
    logic valid;
    req_kind_t kind;
    logic [SLOT_W-1:0] slot;
} req_t;

typedef struct packed {
    logic [31:0] query_id;
    logic [CHAR_WIDTH*PAT_MAX_LEN-1:0] pattern;
    logic [$clog2(PAT_MAX_LEN+1)-1:0] pat_len;
    logic [PAT_IDX_W-1:0] pat_idx;
    logic [LOOP_COUNT_W-1:0] loop_count;
    logic [CHAR_WIDTH-1:0] cur_char;
    logic [31:0] l;
    logic [31:0] r;
    logic [31:0] rank_l;
    logic [31:0] rank_r;
    logic [31:0] c_base;
    slot_state_t state;
} slot_t;

function automatic logic [31:0] occ_addr(
    input logic [CHAR_WIDTH-1:0] char,
    input logic [31:0] row,
    input logic [31:0] sigma_m1
);
    begin
        occ_addr = HEADER_WORDS + sigma_m1 + (row * sigma_m1) + ({29'd0, char} - 32'd1);
    end
endfunction

function automatic logic [31:0] c_arr_addr(
    input logic [CHAR_WIDTH-1:0] char
);
    begin
        c_arr_addr = HEADER_WORDS + ({29'd0, char} - 32'd1);
    end
endfunction

function automatic logic [CHAR_WIDTH-1:0] slot_char(
    input logic [CHAR_WIDTH*PAT_MAX_LEN-1:0] pattern,
    input logic [PAT_IDX_W-1:0] pat_idx
);
    begin
        slot_char = pattern[pat_idx*CHAR_WIDTH +: CHAR_WIDTH];
    end
endfunction

function automatic logic is_terminal(input slot_state_t state);
    begin
        is_terminal = (state == SLOT_DONE) || (state == SLOT_FAIL);
    end
endfunction

function automatic logic slot_can_issue(input slot_state_t state);
    begin
        slot_can_issue = (state == SLOT_READ_CHAR)
            || (state == SLOT_READY_OCC_R)
            || (state == SLOT_READY_C_BASE);
    end
endfunction

function automatic int wrap_idx(
    input int base,
    input int offset
);
    int idx;
    begin
        idx = base + offset;
        if (idx >= NUM_SLOTS) begin
            idx -= NUM_SLOTS;
        end
        wrap_idx = idx;
    end
endfunction

boot_state_t boot_state, boot_state_n;
logic [31:0] seq_len, seq_len_n;
logic [31:0] sigma_m1, sigma_m1_n;
logic [SLOT_W-1:0] alloc_ptr, alloc_ptr_n;
logic [SLOT_W-1:0] rr_ptr, rr_ptr_n;
logic [SLOT_W-1:0] emit_ptr, emit_ptr_n;
logic [FIFO_W-1:0] pending_count, pending_count_n;

slot_t slots [NUM_SLOTS];
slot_t slots_n [NUM_SLOTS];

req_t req_pipe [PIPE_DEPTH];
req_t req_pipe_n [PIPE_DEPTH];

logic query_ready_n;
logic result_valid_n;
logic result_done_n;
logic result_fail_n;
logic [31:0] result_query_id_n;
logic [IDX_WIDTH-1:0] result_l_n;
logic [IDX_WIDTH-1:0] result_r_n;
logic [SLOT_W-1:0] issue_slot;
req_kind_t issue_kind;
logic issue_valid;
logic [31:0] issue_addr;
logic [SLOT_W-1:0] resp_slot;
req_kind_t resp_kind;
logic resp_valid;

always_comb begin
    boot_state_n = boot_state;
    seq_len_n = seq_len;
    sigma_m1_n = sigma_m1;
    alloc_ptr_n = alloc_ptr;
    rr_ptr_n = rr_ptr;
    emit_ptr_n = emit_ptr;
    pending_count_n = pending_count;

    for (int i = 0; i < NUM_SLOTS; i++) begin
        slots_n[i] = slots[i];
    end

    for (int i = 0; i < PIPE_DEPTH; i++) begin
        req_pipe_n[i].valid = 1'b0;
        req_pipe_n[i].kind = REQ_BOOT_MAGIC;
        req_pipe_n[i].slot = '0;
    end

    query_ready_n = 1'b0;
    result_valid_n = 1'b0;
    result_done_n = 1'b0;
    result_fail_n = 1'b0;
    result_query_id_n = 32'd0;
    result_l_n = '0;
    result_r_n = '0;
    ram_req = 1'b0;
    ram_addr = 32'd0;
    issue_valid = 1'b0;
    issue_kind = REQ_BOOT_MAGIC;
    issue_slot = '0;
    issue_addr = 32'd0;
    resp_valid = 1'b0;
    resp_kind = REQ_BOOT_MAGIC;
    resp_slot = '0;

    if (req_pipe[PIPE_DEPTH-1].valid) begin
        resp_valid = 1'b1;
        resp_kind = req_pipe[PIPE_DEPTH-1].kind;
        resp_slot = req_pipe[PIPE_DEPTH-1].slot;
        pending_count_n = pending_count_n - 1'b1;
    end

    for (int i = PIPE_DEPTH - 1; i > 0; i--) begin
        req_pipe_n[i] = req_pipe[i-1];
    end

    if (resp_valid) begin
        case (resp_kind)
        REQ_BOOT_MAGIC: begin
            if (ram_data != INDEX_MAGIC) begin
                boot_state_n = BOOT_FAIL;
            end else begin
                boot_state_n = BOOT_LEN_REQ;
            end
        end

        REQ_BOOT_LEN: begin
            seq_len_n = ram_data;
            boot_state_n = BOOT_ALPHA_REQ;
        end

        REQ_BOOT_ALPHA: begin
            sigma_m1_n = ram_data;
            boot_state_n = BOOT_DONE;
        end

        REQ_OCC_L: begin
            slots_n[resp_slot].rank_l = ram_data;
            slots_n[resp_slot].state = SLOT_READY_OCC_R;
        end

        REQ_OCC_R: begin
            slots_n[resp_slot].rank_r = ram_data;
            slots_n[resp_slot].state = SLOT_READY_C_BASE;
        end

        REQ_C_BASE: begin
            logic [31:0] new_l;
            logic [31:0] new_r;
            new_l = ram_data + slots_n[resp_slot].rank_l;
            new_r = ram_data + slots_n[resp_slot].rank_r;
            slots_n[resp_slot].c_base = ram_data;
            slots_n[resp_slot].l = new_l;
            slots_n[resp_slot].r = new_r;
            if (new_l >= new_r) begin
                slots_n[resp_slot].state = SLOT_FAIL;
            end else if (slots_n[resp_slot].loop_count == 0) begin
                slots_n[resp_slot].state = SLOT_DONE;
            end else begin
                slots_n[resp_slot].state = SLOT_READ_CHAR;
            end
        end

        default: begin
        end
        endcase
    end

    for (int i = 0; i < NUM_SLOTS; i++) begin
        if (slots_n[i].state == SLOT_READ_CHAR) begin
            logic [CHAR_WIDTH-1:0] ch;
            ch = slot_char(slots_n[i].pattern, slots_n[i].pat_idx);
            if (ch == 0) begin
                if (slots_n[i].loop_count == 0) begin
                    slots_n[i].state = SLOT_DONE;
                end else begin
                    slots_n[i].state = SLOT_FAIL;
                end
            end
        end
    end

    if (boot_state_n != BOOT_DONE && pending_count_n < FIFO_W'(REQ_FIFO_DEPTH)) begin
        unique case (boot_state_n)
        BOOT_MAGIC_REQ: begin
            issue_valid = 1'b1;
            issue_kind = REQ_BOOT_MAGIC;
            issue_addr = 32'd0;
            boot_state_n = BOOT_MAGIC_WAIT;
        end

        BOOT_LEN_REQ: begin
            issue_valid = 1'b1;
            issue_kind = REQ_BOOT_LEN;
            issue_addr = 32'd1;
            boot_state_n = BOOT_LEN_WAIT;
        end

        BOOT_ALPHA_REQ: begin
            issue_valid = 1'b1;
            issue_kind = REQ_BOOT_ALPHA;
            issue_addr = 32'd2;
            boot_state_n = BOOT_ALPHA_WAIT;
        end

        BOOT_FAIL: begin
        end

        default: begin
        end
        endcase
    end

    if (!issue_valid && boot_state_n == BOOT_DONE && pending_count_n < FIFO_W'(REQ_FIFO_DEPTH)) begin
        for (int offset = 0; offset < NUM_SLOTS; offset++) begin
            int idx;
            idx = wrap_idx(int'(rr_ptr), offset);
            if (!issue_valid && slot_can_issue(slots_n[idx].state)) begin
                logic [CHAR_WIDTH-1:0] ch;
                ch = slot_char(slots_n[idx].pattern, slots_n[idx].pat_idx);
                if (slots_n[idx].state == SLOT_READ_CHAR) begin
                    if (ch != 0) begin
                        issue_valid = 1'b1;
                        issue_kind = REQ_OCC_L;
                        issue_slot = idx[SLOT_W-1:0];
                        issue_addr = occ_addr(ch, slots_n[idx].l, sigma_m1_n);
                        slots_n[idx].cur_char = ch;
                        slots_n[idx].state = SLOT_WAIT_OCC_L;
                        slots_n[idx].loop_count = slots_n[idx].loop_count - 1'b1;
                        slots_n[idx].pat_idx = slots_n[idx].pat_idx - 1'b1;
                        rr_ptr_n = (idx == NUM_SLOTS - 1) ? SLOT_W'(0) : SLOT_W'(idx + 1);
                    end
                end else if (slots_n[idx].state == SLOT_READY_OCC_R) begin
                    issue_valid = 1'b1;
                    issue_kind = REQ_OCC_R;
                    issue_slot = idx[SLOT_W-1:0];
                    issue_addr = occ_addr(slots_n[idx].cur_char, slots_n[idx].r, sigma_m1_n);
                    slots_n[idx].state = SLOT_WAIT_OCC_R;
                    rr_ptr_n = (idx == NUM_SLOTS - 1) ? SLOT_W'(0) : SLOT_W'(idx + 1);
                end else if (slots_n[idx].state == SLOT_READY_C_BASE) begin
                    issue_valid = 1'b1;
                    issue_kind = REQ_C_BASE;
                    issue_slot = idx[SLOT_W-1:0];
                    issue_addr = c_arr_addr(slots_n[idx].cur_char);
                    slots_n[idx].state = SLOT_WAIT_C_BASE;
                    rr_ptr_n = (idx == NUM_SLOTS - 1) ? SLOT_W'(0) : SLOT_W'(idx + 1);
                end
            end
        end
    end

    query_ready_n = 1'b0;
    if (boot_state_n == BOOT_DONE) begin
        for (int offset = 0; offset < NUM_SLOTS; offset++) begin
            int idx;
            idx = wrap_idx(int'(alloc_ptr), offset);
            if (!query_ready_n && slots[idx].state == SLOT_FREE) begin
                query_ready_n = 1'b1;
                if (query_valid) begin
                    slots_n[idx].query_id = query_id;
                    slots_n[idx].pattern = query_pattern;
                    slots_n[idx].pat_len = query_pat_len;
                    slots_n[idx].pat_idx = PAT_IDX_W'(PAT_MAX_LEN - 1);
                    slots_n[idx].loop_count = query_pat_len;
                    slots_n[idx].cur_char = '0;
                    slots_n[idx].l = 32'd0;
                    slots_n[idx].r = seq_len_n;
                    slots_n[idx].rank_l = 32'd0;
                    slots_n[idx].rank_r = 32'd0;
                    slots_n[idx].c_base = 32'd0;
                    slots_n[idx].state = SLOT_READ_CHAR;
                    alloc_ptr_n = (idx == NUM_SLOTS - 1) ? SLOT_W'(0) : SLOT_W'(idx + 1);
                end
            end
        end
    end

    for (int offset = 0; offset < NUM_SLOTS; offset++) begin
        int idx;
        idx = wrap_idx(int'(emit_ptr), offset);
        if (!result_valid_n && is_terminal(slots_n[idx].state)) begin
            result_valid_n = 1'b1;
            result_done_n = (slots_n[idx].state == SLOT_DONE);
            result_fail_n = (slots_n[idx].state == SLOT_FAIL);
            result_query_id_n = slots_n[idx].query_id;
            result_l_n = slots_n[idx].l;
            result_r_n = slots_n[idx].r;
            slots_n[idx].state = SLOT_FREE;
            emit_ptr_n = (idx == NUM_SLOTS - 1) ? SLOT_W'(0) : SLOT_W'(idx + 1);
        end
    end

    if (boot_state_n != BOOT_DONE) begin
        query_ready_n = 1'b0;
    end

    if (issue_valid) begin
        ram_req = 1'b1;
        ram_addr = issue_addr;
        req_pipe_n[0].valid = 1'b1;
        req_pipe_n[0].kind = issue_kind;
        req_pipe_n[0].slot = issue_slot;
        pending_count_n = pending_count_n + 1'b1;
    end
end

assign query_ready = query_ready_n;
assign result_valid = result_valid_n;
assign result_done = result_done_n;
assign result_fail = result_fail_n;
assign result_query_id = result_query_id_n;
assign l_out = result_l_n;
assign r_out = result_r_n;
assign done = result_valid_n && result_done_n;
assign fail = result_valid_n && result_fail_n;

always_ff @(posedge clk) begin
    if (reset) begin
        boot_state <= BOOT_MAGIC_REQ;
        seq_len <= 32'd0;
        sigma_m1 <= 32'd0;
        alloc_ptr <= '0;
        rr_ptr <= '0;
        emit_ptr <= '0;
        pending_count <= '0;
        for (int i = 0; i < NUM_SLOTS; i++) begin
            slots[i].query_id <= 32'd0;
            slots[i].pattern <= '0;
            slots[i].pat_len <= '0;
            slots[i].pat_idx <= '0;
            slots[i].loop_count <= '0;
            slots[i].cur_char <= '0;
            slots[i].l <= '0;
            slots[i].r <= '0;
            slots[i].rank_l <= '0;
            slots[i].rank_r <= '0;
            slots[i].c_base <= '0;
            slots[i].state <= SLOT_FREE;
        end
        for (int i = 0; i < PIPE_DEPTH; i++) begin
            req_pipe[i].valid <= 1'b0;
            req_pipe[i].kind <= REQ_BOOT_MAGIC;
            req_pipe[i].slot <= '0;
        end
    end else begin
        boot_state <= boot_state_n;
        seq_len <= seq_len_n;
        sigma_m1 <= sigma_m1_n;
        alloc_ptr <= alloc_ptr_n;
        rr_ptr <= rr_ptr_n;
        emit_ptr <= emit_ptr_n;
        pending_count <= pending_count_n;
        for (int i = 0; i < NUM_SLOTS; i++) begin
            slots[i] <= slots_n[i];
        end
        for (int i = 0; i < PIPE_DEPTH; i++) begin
            req_pipe[i] <= req_pipe_n[i];
        end
    end
end

endmodule

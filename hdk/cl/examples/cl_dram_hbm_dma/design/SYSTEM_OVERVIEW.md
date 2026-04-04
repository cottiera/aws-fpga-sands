# FM-Index Hardware Accelerator — System Overview

## SystemVerilog at a High Level

In C or Python, you write instructions that execute one-after-another, like a recipe. In SystemVerilog, you're describing **physical circuits** — wires, flip-flops, and logic gates that all operate **simultaneously**, every single clock tick. It's less like writing a recipe and more like **designing a factory floor** — every machine runs at the same time, and you're wiring them together.

Two fundamental building blocks:

1. **`always_comb`** (combinational logic) — Think of these as **pipes and valves**. The output changes *instantly* when the input changes. No memory, no clock. Like how water pressure at the end of a hose changes the instant you turn the faucet.

2. **`always_ff @(posedge clk)`** (sequential logic / flip-flops) — Think of these as **a row of lockers that only open at the bell**. Every clock tick (the bell), each locker grabs whatever value is sitting on its input wire and locks it in. This is how circuits *remember* things.

The **`_n` naming convention** used throughout: `foo` is the current value stored in a flip-flop (the locker), and `foo_n` is the "next" value — the wire leading to that locker. Every clock tick, `foo` gets updated to `foo_n`.

---

## What This System Does

These three files implement an **FM-index backward search** in hardware — a genomics algorithm for finding where a short DNA pattern (like `ACGT`) occurs in a massive reference genome.

**Analogy: Think of it like a library card catalog system.**

Imagine you want to find every page in a huge book where the word "SAND" appears. Instead of reading the whole book, you have a clever pre-built index (the FM-index). You look up one letter at a time, *backwards* (D, then N, then A, then S), and each lookup narrows down the range of possible locations until you either find all matches or determine there are none.

The three files form three layers of a machine:

| File | Role | Analogy |
|------|------|---------|
| `cl_fmindex.sv` | The search algorithm | The **librarian** who knows how to use the card catalog |
| `cl_fmindex_accel.sv` | The control/register interface | The **front desk** where you submit your search request and pick up results |
| `cl_fmindex_axi_reader.sv` | The memory bridge | The **book runner** who fetches pages from the stacks when the librarian asks |

---

## File 1: `cl_fmindex.sv` — The Librarian (Core Search Engine)

This is the heart of the system. It performs the FM-index backward search algorithm.

### The Interface (What goes in, what comes out)

```systemverilog
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
```

"Give me a pattern and its length, and I'll tell you either a range `[l_out, r_out)` of positions where it matches, or that it failed."

- **`query_valid` / `query_ready`** — A handshake. Like raising your hand ("I have a query!") and the librarian nodding ("I'm ready to take it"). The transfer only happens when *both* are high.
- **`ram_req` / `ram_addr` / `ram_data`** — The librarian asking the book runner: "Fetch me the word at address X." The data comes back some cycles later.
- **`result_valid` / `result_done` / `result_fail`** — "I have an answer for you: either it was found (done) or not (fail)."

### Boot Sequence — Checking the Index Header

Before accepting any queries, the module boots up by reading 3 words from the index header:

```systemverilog
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
```

Before the librarian starts taking requests, they first check that the card catalog is actually installed correctly:

1. Read word 0: Is it the magic number `"FID1"`? (Like checking the cover says "Card Catalog" and not "Cookbook")
2. Read word 1: How long is the reference sequence? (`seq_len`)
3. Read word 2: How big is the alphabet? (`sigma_m1`, i.e. number of distinct characters minus 1)

Only after all three checks pass does the state reach `BOOT_DONE`, and the librarian starts accepting queries.

### Slots — Handling Multiple Queries at Once

The module has **4 "slots"** (configurable via `NUM_SLOTS`) that can each work on a different query simultaneously, like a librarian who juggles 4 different lookups at once.

```systemverilog
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
```

Each slot is like a bookmark tracking one search in progress. It remembers:
- The pattern being searched and how far through it we are (`pat_idx`, `loop_count`)
- The current narrowed-down range `[l, r)` — starts as the entire genome and gets smaller with each letter
- Intermediate values (`rank_l`, `rank_r`, `c_base`) needed for each step of the algorithm

### The Slot State Machine — One Letter at a Time

Each slot walks through these states for *every character* in the pattern:

```systemverilog
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
```

Looking up one letter in the card catalog:

1. **`SLOT_READ_CHAR`** — The librarian reads the next letter from the pattern (going backwards)
2. **`SLOT_WAIT_OCC_L`** — "Fetch me Occ(char, l)" from the table — waiting for the book runner
3. **`SLOT_READY_OCC_R`** — Got rank_l back, now request "Fetch me Occ(char, r)"
4. **`SLOT_WAIT_OCC_R`** — Waiting for rank_r
5. **`SLOT_READY_C_BASE`** — Got rank_r, now request "Fetch me C[char]" (the base offset for this character)
6. **`SLOT_WAIT_C_BASE`** — Waiting for c_base

Then the math happens:

```systemverilog
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
```

This is the FM-index formula: `new_l = C[char] + Occ(char, l)`, `new_r = C[char] + Occ(char, r)`. If the range becomes empty (`new_l >= new_r`), the pattern doesn't exist. If we've processed all characters (`loop_count == 0`), we found matches. Otherwise, go back to `SLOT_READ_CHAR` for the next letter.

### The Pipeline — Hiding Memory Latency

Reading from HBM memory takes ~64 clock cycles. Rather than sitting idle, the module uses a **shift register pipeline**:

```systemverilog
req_t req_pipe [PIPE_DEPTH];
req_t req_pipe_n [PIPE_DEPTH];
```

Imagine the librarian sends a runner to fetch a page. Rather than staring at the door waiting for them to come back, the librarian starts working on a *different* query. When the runner returns 64 ticks later, a tag on the request tells the librarian which query it was for.

The round-robin pointer `rr_ptr` cycles through slots, giving each one a fair turn to issue memory requests.

### The Flip-Flop Update — Where State Actually Changes

All the logic in `always_comb` just computes *what should happen next*. The actual state update happens on the clock edge:

```systemverilog
always_ff @(posedge clk) begin
    if (reset) begin
        boot_state <= BOOT_MAGIC_REQ;
        // ... reset everything to initial values ...
    end else begin
        boot_state <= boot_state_n;
        seq_len <= seq_len_n;
        // ... copy all _n values into the real registers ...
        for (int i = 0; i < NUM_SLOTS; i++) begin
            slots[i] <= slots_n[i];
        end
    end
end
```

The lockers all swing open at the bell, grab whatever is on their input wire, and slam shut. Every. Single. Clock. Tick. This is how digital circuits "step forward in time."

---

## File 2: `cl_fmindex_accel.sv` — The Front Desk (Register Interface)

This module is the **bridge between software (the CPU) and the hardware engine**. Software can't directly talk to the FM-index core — it communicates through memory-mapped registers, like filling out forms at a front desk.

### The Register Map

```
Offset  Name           Access  Description
------  ----           ------  -----------
0x00    CTRL           RW      bit 0: submit (W1-auto-clear)
                                bit 1: result_pending (R; W1C)
                                bit 2: boot_done (R)
                                bit 3: fmindex_reset (RW; 1=hold reset)
0x04    PAT_LEN        RW      pattern length (max PAT_MAX_LEN)
0x08    QUERY_ID       RW      32-bit query id
0x0C    RESULT_STATUS  R       bit 0: done, bit 1: fail
0x10    RESULT_L       R       l_out
0x14    RESULT_R       R       r_out
0x18    RESULT_QID     R       result query_id
0x1C    HBM_BASE_LO    RW      lower 32 bits of HBM base byte address
0x20    HBM_BASE_HI    RW      upper 32 bits of HBM base byte address
0x40-0x9C PATTERN[0..23] RW    pattern data (24 x 32-bit words)
```

Think of these registers as numbered boxes at the front desk:
- Box 0x00 (CTRL): The "Submit" button and status lights
- Box 0x04: Write the length of your search pattern here
- Box 0x08: Write your query ticket number
- Box 0x40–0x9C: Write your actual pattern here, 4 bytes at a time
- Box 0x0C–0x18: Read-only result boxes where answers appear

### How Software Submits a Query

The workflow from software's perspective:
1. Write the pattern into registers at `0x40`+
2. Write the pattern length to `0x04`
3. Write a query ID to `0x08`
4. Write `1` to `0x00` (set the submit bit)

The hardware then triggers:

```systemverilog
assign fm_query_valid = submit_q && fm_query_ready;
```

The submit bit fires for exactly one cycle (auto-clears), and if the FM-index core is ready, the query gets accepted.

### Latching Results

When the FM-index core finishes:

```systemverilog
if (fm_result_valid) begin
    result_pending_q <= 1'b1;
    res_done_q       <= fm_result_done;
    res_fail_q       <= fm_result_fail;
    res_l_q          <= fm_l_out;
    res_r_q          <= fm_r_out;
    res_qid_q        <= fm_result_query_id;
end
```

The result gets latched into registers that software can read. The `result_pending` flag lights up, telling software "your answer is ready in boxes 0x0C–0x18."

### Wiring It All Together

This module instantiates both the core and the memory bridge:

```systemverilog
cl_fmindex #( ... ) FMINDEX ( ... );

cl_fmindex_axi_reader #( ... ) AXI_READER ( ... );
```

The front desk manager hires the librarian (`FMINDEX`) and the book runner (`AXI_READER`), and wires them together. The librarian says "fetch address X," the book runner goes to HBM memory and brings back the data.

---

## File 3: `cl_fmindex_axi_reader.sv` — The Book Runner (Memory Bridge)

This module translates the simple `ram_req` / `ram_addr` / `ram_data` interface into AXI4 bus transactions that read from HBM (High Bandwidth Memory) on the FPGA.

**The core problem it solves:** The FM-index core thinks it's talking to a simple RAM with fixed latency. But HBM speaks AXI4, a complex handshake protocol with variable latency. This module makes HBM *look like* a simple fixed-latency RAM.

### Address Translation

```systemverilog
logic [63:0] byte_addr;
assign byte_addr = hbm_base_addr + ({32'b0, ram_addr} << 2);
```

The FM-index core uses word addresses (word 0, word 1, word 2...). This converts to byte addresses (`<< 2` means multiply by 4) and adds the HBM base address. Like converting "page 5" to "byte offset 20 from the start of the book."

### The Address FIFO

```systemverilog
logic [63:0] addr_fifo [ADDR_FIFO_SLOTS];
```

The book runner has a small notepad (FIFO queue). When the librarian says "fetch address X," it gets written on the notepad. The runner works through the notepad one request at a time, sending each to the AXI bus. The `& ~64'h3F` masks the address to 64-byte alignment because HBM reads whole 64-byte cache lines.

### The Delivery Shift Register — The Timing Trick

This is the most clever part:

```systemverilog
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
```

Imagine a conveyor belt with exactly 64 slots. When the librarian makes a request, a token is placed on the belt. Exactly 64 ticks later, the token falls off the end and triggers "deliver now!" This guarantees the FM-index core gets its data at *exactly* the cycle it expects — no sooner, no later.

A parallel conveyor belt (`offset_pipe`) carries the byte offset so the module knows *which 32-bit word* to extract from the 512-bit (64-byte) cache line:

```systemverilog
wire [511:0] head_data = resp_fifo[rf_rd[RF_PTR_W-1:0]];

always_ff @(posedge clk) begin
    if (!rst_n) begin
        ram_data <= 32'd0;
    end else if (deliver_now && !rf_empty) begin
        ram_data <= head_data[deliver_offset*32 +: 32];
    end
end
```

The `[deliver_offset*32 +: 32]` syntax means "starting at bit position `deliver_offset * 32`, grab 32 bits." It's extracting one 4-byte word out of a 64-byte cache line.

### AXI Write Tie-Offs

Since this module only *reads* from memory, all the write channels are tied to zero/inactive. This is standard practice — if you don't use a bus channel, you still have to drive the wires to valid values so they don't float.

---

## Full Data Flow Summary

Here's the end-to-end journey of a query:

1. **Software** writes a DNA pattern (e.g., "ACGT") into the registers of `cl_fmindex_accel` and hits "submit"
2. **`cl_fmindex_accel`** packs the pattern into a wide bit vector and presents it to `cl_fmindex` with `query_valid=1`
3. **`cl_fmindex`** accepts the query into a free slot, then starts the backward search — for each character (right to left), it needs 3 memory lookups: `Occ(char, l)`, `Occ(char, r)`, `C[char]`
4. **`cl_fmindex`** issues `ram_req` + `ram_addr` for each lookup
5. **`cl_fmindex_axi_reader`** translates that into an AXI4 read to HBM, fetches a 64-byte cache line, and delivers the correct 4-byte word back exactly 65 cycles later
6. **`cl_fmindex`** uses the returned data to narrow the range `[l, r)`, then repeats for the next character
7. When all characters are processed, the slot reaches `SLOT_DONE` (match found) or `SLOT_FAIL` (no match)
8. **`cl_fmindex_accel`** latches the result into readable registers and sets `result_pending`
9. **Software** polls the CTRL register, sees the result is ready, and reads out `l` and `r`

The multi-slot design means steps 3–7 can be happening for up to 4 different queries simultaneously, keeping the memory pipeline busy and maximizing throughput.

# HBM Data Pipeline — Project Overview

## 1. Objective

Build a minimal, validated data path that moves data from a **file on disk** into **host memory**, then from **host memory** into **HBM on an AWS F2 FPGA**. This is the foundational data movement layer for a future FM-Index DNA alignment accelerator.

### What This Phase Delivers

- Host software that reads a file into a host-side buffer.
- A working DMA/PCIS transfer from host memory to FPGA HBM.
- A read-back verification step proving data integrity (write-read-compare).
- Throughput measurements at each stage.

### What This Phase Does NOT Include

- DDR usage (disabled via `EN_DDR=0`).
- A processing kernel on the FPGA (no stub kernel yet).
- PCIM result return path (FPGA → host).
- Multi-FPGA distribution.
- Ring buffers or streaming architecture.

---

## 2. Platform

| Property | Detail |
|---|---|
| Instance | `f2.6xlarge` (1 FPGA) |
| FPGA | AMD/Xilinx Virtex UltraScale+ VU47P |
| Target memory | **16 GB HBM2** (dual-stack, AXI3 @ 450 MHz) |
| Shell | **Small Shell** (no built-in XDMA engine) |
| PCIe | Gen3 x16 |

### Critical Constraint: No Shell XDMA on F2

The F2 Small Shell does **not** include a DMA engine. The `fpga_dma_burst_read/write` API (which wraps `/dev/xdma*`) **cannot be used on F2**. All data movement must use:

- **PCIS (BAR4 MMIO):** Host CPU-initiated AXI4 writes/reads via `fpga_pci_write_burst` / `fpga_pci_get_address` with write-combining.
- **PCIM (CL-initiated):** Not used in this phase.

> **Note:** The `cl_dram_hbm_dma` example's `test_dram_hbm_dma.c` uses the XDMA API (`fpga_dma_burst_write/read`). This code path works in simulation and on XDMA-shell instances but **will not work on F2 hardware**. The software must be adapted to use PCIS (BAR4) writes instead.

---

## 3. Starting Point: `cl_dram_hbm_dma` (HBM-Only Configuration)

We are basing this work on the `hdk/cl/examples/cl_dram_hbm_dma/` example with DDR disabled.

### RTL Configuration

The design uses two parameters to control memory controller presence:

```systemverilog
module cl_dram_hbm_dma
#(
  parameter EN_DDR = 0,   // CHANGED: disabled for HBM-only
  parameter EN_HBM = 1
)
```

With `EN_DDR=0`:
- `sh_ddr` ties off all DDR AXI signals and physical pins internally.
- The AXI crossbar still exists with two output ports, but traffic to the DDR address range (0x00–0x0F_FFFF_FFFF) goes to a dead-end tie-off. This is harmless.
- DDR scrubber buses remain instantiated but inactive.

### HBM Address Range

| Region | Address Range | Size |
|---|---|---|
| DDR (disabled) | `0x00_0000_0000` – `0x0F_FFFF_FFFF` | 64 GB (tie-off) |
| **HBM** | **`0x10_0000_0000`** – **`0x1C_FFFF_FFFF`** | **16 GB** |

All DMA / PCIS traffic targeting HBM must use addresses in the `0x10_0000_0000`+ range.

### Data Path (What We're Validating)

```
File on disk
    │
    ▼  (fread / mmap)
Host Memory Buffer
    │
    ▼  (PCIS: fpga_pci_write_burst via BAR4)
AXI4 Crossbar (cl_dma_pcis_slv.sv)
    │
    ▼  (address decode → DDRB port → HBM path)
cl_hbm_axi4.sv  (AXI4 → AXI3 conversion, 250→450 MHz CDC)
    │
    ▼
cl_hbm_wrapper.sv  (HBM IP)
    │
    ▼
Physical HBM2 (16 GB)
```

### Validation Method

1. Write known data (random bytes) from host to HBM at address `0x10_0000_0000`.
2. Read back from the same HBM address into a separate host buffer.
3. Byte-compare the write buffer and read buffer.
4. If all bytes match → data path is validated end-to-end.

---

## 4. Repository Structure

The actual code modifications will be made in a **fork** of the aws-fpga repository (to be cloned onto the F2 instance). This repo contains planning and reference materials.

| Path | Purpose |
|---|---|
| `docs/` | Project overview, architecture notes |
| `logs/` | Task checklists, build logs, test results |
| `FM_INDEX_ACCELERATOR_PROJECT.md` | Full-scope project requirements (future phases) |
| `hdk/cl/examples/cl_dram_hbm_dma/` | Reference example (unmodified in this repo) |

---

## 5. Broader Context

This HBM data pipeline is **Phase 1** of a larger FM-Index accelerator project:

- **Phase 1 (current):** File → host memory → HBM. Validate the data path.
- **Phase 2:** Add a stub kernel that reads from HBM, processes data, writes back.
- **Phase 3:** Add PCIM result return (FPGA pushes results to host memory).
- **Phase 4:** Replace stub kernel with the FM-Index backward-search core.
- **Phase 5:** Multi-channel HBM, multi-FPGA, performance optimization.

See `FM_INDEX_ACCELERATOR_PROJECT.md` for the full architecture.

---

## 6. Key Files to Study

| File | Why |
|---|---|
| `hdk/cl/examples/cl_dram_hbm_dma/design/cl_dram_hbm_dma.sv` | Top-level CL; `EN_DDR`/`EN_HBM` parameters |
| `hdk/cl/examples/cl_dram_hbm_dma/design/cl_dma_pcis_slv.sv` | AXI crossbar routing PCIS to DDR vs HBM |
| `hdk/cl/examples/cl_dram_hbm_dma/design/cl_hbm_axi4.sv` | AXI4→AXI3 bridge + clock domain crossing |
| `hdk/cl/examples/cl_dram_hbm_dma/design/cl_hbm_wrapper.sv` | HBM IP instantiation |
| `hdk/cl/examples/cl_dram_hbm_dma/design/cl_dram_dma_defines.vh` | Macros, DDR presence flags |
| `hdk/cl/examples/cl_dram_hbm_dma/software/runtime/test_dram_hbm_dma.c` | Reference host software (uses XDMA — must adapt for PCIS) |
| `hdk/cl/examples/cl_dram_hbm_dma/build/scripts/synth_cl_dram_hbm_dma.tcl` | Synthesis script (reads DDR + HBM IP) |
| `sdk/userspace/include/fpga_pci.h` | PCIS API: `fpga_pci_write_burst`, `fpga_pci_peek`, `fpga_pci_poke` |
| `ERRATA.md` | F2 known issues (XDMA unsupported, HBM address aliasing) |

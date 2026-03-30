# TODO: Focused HBM Data Pipeline

Goal: File on disk → host memory → HBM on FPGA, with read-back validation.

---

## RTL Changes (in the fork)

All changes target files under `hdk/cl/examples/cl_dram_hbm_dma/`.

- [ ] **Set `EN_DDR=0` in the top-level module**
  - File: `design/cl_dram_hbm_dma.sv`, line 25
  - Change `parameter EN_DDR = 1` → `parameter EN_DDR = 0`
  - This makes `sh_ddr` tie off all DDR AXI signals and physical pins.

- [ ] **Define `DDR_A_ABSENT` in the defines file**
  - File: `design/cl_dram_dma_defines.vh`
  - Add `\`define DDR_A_ABSENT` before the `\`ifndef DDR_A_ABSENT` block
  - This ensures the ILA debug probes don't attempt to hook up DDR signals.
  - Also consider adding `\`define DDR_B_ABSENT` and `\`define DDR_D_ABSENT` for completeness.

- [ ] **Remove DDR IP from synthesis script (optional, saves build time)**
  - File: `build/scripts/synth_cl_dram_hbm_dma.tcl`
  - Comment out or remove the `cl_ddr4` IP read (lines 45-47):
    ```tcl
    ## DDR IP
    # read_ip [ list \
    #   ${HDK_IP_SRC_DIR}/cl_ddr4/cl_ddr4.xci
    # ]
    ```
  - Not strictly required — with `EN_DDR=0`, `sh_ddr` won't instantiate the IP. But removing it avoids unnecessary IP synthesis time.
  - **Caution:** Verify `sh_ddr` (a shell module) doesn't reference the DDR4 IP when `DDR_PRESENT=0`. If it does, leave the IP in.

- [ ] **Verify ILA/debug section handles DDR absence**
  - File: `build/scripts/synth_cl_dram_hbm_dma.tcl`, lines 138-143
  - The `get_cells` for `CL_DDRA_ILA_0` should return empty and the `if` guard should handle it. Confirm this doesn't cause a Vivado error.

- [ ] **Verify `ddr_ready` / `hbm_ready` status outputs are acceptable**
  - File: `design/cl_dram_hbm_dma.sv`, line 161
  - `cl_sh_status_vled = 16'({ddr_ready, hbm_ready})` — with DDR disabled, bit 1 stays 0. This is expected, not an error.

---

## Software Changes (in the fork)

### Adapt `test_dram_hbm_dma.c` for HBM-Only

- [ ] **Remove DDR iterations from `dma_example()`**
  - File: `software/runtime/test_dram_hbm_dma.c`
  - The loop `for (iter = 0; iter < 5; iter++)` runs iterations 0–3 against DDR and iteration 4 against HBM.
  - Change to target only HBM:
    - Set `dma_addr = 0x10_0000_0000` (the HBM base address, equivalent to `4 * MEM_16G`).
    - Remove the 5-iteration loop or reduce to a single HBM iteration.

- [ ] **Remove DDR access from `axi_mstr_example()`**
  - File: `software/runtime/test_dram_hbm_dma.c`, lines 496-502
  - Remove or skip the DDR address access (`addr_hi_addr = 0x00000001`).
  - Keep only the HBM access (`addr_hi_addr = 0x00000008`).

- [ ] **Add file-read stage**
  - Before the DMA transfer, read data from a file into the write buffer (instead of random data).
  - Use `fread()` or `mmap()` to load a test file from disk into `write_buffer`.
  - Log the file size and read duration.

- [ ] **Add throughput logging**
  - Measure and print wall-clock time and GB/s for each stage:
    - File read → host memory
    - Host memory → HBM (write)
    - HBM → host memory (read-back)
    - Byte comparison

### Adapt for F2 Small Shell (no XDMA)

- [ ] **Replace XDMA API with PCIS API**
  - The current code uses `fpga_dma_open_queue` / `fpga_dma_burst_write` / `fpga_dma_burst_read` — these require the XDMA driver which is **not available on F2**.
  - Replace with PCIS (BAR4) access:
    - `fpga_pci_attach()` to open BAR4
    - `fpga_pci_write_burst()` for host → FPGA writes
    - `fpga_pci_read_burst()` for FPGA → host reads
    - Or use `fpga_pci_get_address()` for a direct mapped pointer with write-combining
  - Reference: `sdk/userspace/include/fpga_pci.h`

- [ ] **Test with PCIS-based transfer on simulation first**
  - The simulation testbench supports both XDMA and PCIS paths.
  - Verify the PCIS path works in simulation before targeting F2 hardware.

---

## Build & Deployment Checklist

- [ ] **Set up the F2 development environment**
  - Launch an `f2.6xlarge` with the F2 Developer AMI.
  - `source hdk_setup.sh && source sdk_setup.sh`
  - Verify Vivado version matches `supported_vivado_versions.txt`.
  - Run `fpga-describe-local-image-slots` to confirm FPGA slot is visible.

- [ ] **Clone the fork onto the F2 instance**
  - All modifications are in the fork — the main repo stays clean.

- [ ] **Build the modified CL**
  - Run the Vivado build flow from `build/scripts/`.
  - Monitor for synthesis/implementation errors related to DDR removal.
  - Expected build time: 2-4 hours.

- [ ] **Create and load the AFI**
  - Run `create_afi.py` to generate the AFI from the DCP.
  - Wait for AFI to reach "available" state (`aws ec2 describe-fpga-images`).
  - Load with `fpga-load-local-image`.

- [ ] **Compile and run the host software**
  - `cd software/runtime && make`
  - Run the test, targeting only HBM addresses.
  - Verify the write-read-compare passes.

---

## Validation Criteria

- [ ] **RTL builds without errors** — Vivado synthesis and implementation complete with no critical errors/warnings related to DDR removal.
- [ ] **Simulation passes** — A testbench test writes data to HBM (address `0x10_0000_0000`+), reads it back, and all bytes match.
- [ ] **Hardware passes** — On the F2 instance, host software writes a buffer to HBM via PCIS, reads it back via PCIS, and byte comparison shows 0 differences.
- [ ] **Throughput is logged** — Console output shows MB/s or GB/s for each transfer stage.

---

## Open Questions

- [ ] Does `sh_ddr` with `DDR_PRESENT=0` still require the `cl_ddr4` IP to be present in the project, or can we safely remove it from the synth script?
- [ ] What is the maximum single-transfer size for `fpga_pci_write_burst` on F2? Need to determine optimal chunk size.
- [ ] Does the AXI crossbar (`cl_axi_sc_2x2_wrapper`) need any address map reconfiguration when DDR is disabled, or does it gracefully handle traffic to the DDR range hitting a tie-off?
- [ ] Are there any ERRATA items beyond the XDMA limitation that affect HBM access via PCIS on F2?

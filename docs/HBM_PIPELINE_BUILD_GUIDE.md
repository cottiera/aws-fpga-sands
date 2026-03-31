# HBM Data Pipeline — Build & Validation Guide

## Overview

This guide covers building, deploying, and validating the HBM-only `cl_dram_hbm_dma` design on an AWS F2 instance. The design writes data from host memory to HBM via DMA, reads it back, and verifies byte-level integrity.

---

## 1. RTL Changes (Already Applied)

Three modifications were made to the stock `cl_dram_hbm_dma` example:

| File | Change |
|------|--------|
| `design/cl_dram_hbm_dma.sv` line 25 | `EN_DDR = 1` → `EN_DDR = 0` |
| `design/cl_dram_dma_defines.vh` | Added `DDR_A_ABSENT`, `DDR_B_ABSENT`, `DDR_D_ABSENT` defines |
| `build/scripts/synth_cl_dram_hbm_dma.tcl` lines 44-47 | Commented out `cl_ddr4.xci` IP read |

**What stays intact:** `sh_ddr`, crossbar, register slices, scrubbers, and all pblock constraints remain in the design. They are instantiated but inactive (tied off internally by `DDR_PRESENT=0`). This avoids constraint/pblock errors during implementation.

**VLED status:** With DDR disabled, `cl_sh_status_vled` bit 1 (`ddr_ready`) will always be 0. Bit 0 (`hbm_ready`) going high confirms HBM initialization succeeded.

---

## 2. Building the DCP

### Prerequisites

- F2 Developer AMI (or equivalent with Vivado installed)
- Vivado version matching `$HDK_DIR/supported_vivado_versions.txt`
- HDK and SDK environment sourced

### Build Commands

```bash
source hdk_setup.sh
source sdk_setup.sh
export CL_DIR=$HDK_DIR/cl/examples/cl_dram_hbm_dma
cd $CL_DIR/build/scripts
python3 aws_build_dcp_from_cl.py --cl cl_dram_hbm_dma --mode small_shell --flow BuildAll
```

Build time: approximately 2-4 hours. Monitor the Vivado log in `build/scripts/`.

### Key Build Parameters

| Parameter | Default | Notes |
|-----------|---------|-------|
| `--mode` | — | Must be `small_shell` for F2 |
| `--clock_recipe_hbm` | H2 (450 MHz) | HBM AXI clock recipe |
| `--flow` | — | `BuildAll` runs synthesis + implementation |

### Output

On success, the DCP and manifest are placed in:
```
$CL_DIR/build/checkpoints/to_aws/
```

### Troubleshooting

- **DDR4 IP error during synthesis:** If `sh_ddr` references `cl_ddr4` in a non-gated path, uncomment lines 44-47 in `synth_cl_dram_hbm_dma.tcl` to restore the IP read. It will be elaborated but unused.
- **Pblock cell-not-found:** Should not happen since all DDR infrastructure remains instantiated. If it does, check that `EN_DDR` is 0 (not removed entirely).

---

## 3. Creating and Loading the AFI

```bash
# From the build output directory
cd $CL_DIR/build/checkpoints/to_aws/

# Create AFI (substitute your S3 bucket and key prefix)
aws ec2 create-fpga-image \
    --name "cl_dram_hbm_dma_hbm_only" \
    --input-storage-location Bucket=<your-bucket>,Key=<dcp-tarball-key>

# Check AFI status (wait for "available")
aws ec2 describe-fpga-images --fpga-image-ids <afi-id>

# Load onto FPGA slot 0
sudo fpga-load-local-image -S 0 -I <afi-id>

# Verify loaded
sudo fpga-describe-local-image -S 0 -H
```

---

## 4. Compiling the Host Test

```bash
source sdk_setup.sh
cd $CL_DIR/software/runtime
make test_hbm_dma
```

This produces the `test_hbm_dma` binary, which targets only HBM (no DDR iterations).

---

## 5. Running the Validation Test

### Basic (16 MB, random data)

```bash
sudo ./test_hbm_dma --slot 0
```

### Custom size

```bash
sudo ./test_hbm_dma --slot 0 --size 67108864    # 64 MB
sudo ./test_hbm_dma --slot 0 --gb 1             # 1 GB
```

### With file input

```bash
sudo ./test_hbm_dma --slot 0 --size 1048576 --file /path/to/test_data.bin
```

If the file is smaller than `--size`, the remainder is zero-padded.

---

## 6. Interpreting Output

### Expected Output (PASS)

```
=== HBM Data Pipeline Test ===
Slot: 0   Buffer: 16777216 bytes (16.00 MB)
VLED status: 0x0001  (bit0=hbm_ready, bit1=ddr_ready)
HBM is ready.
AXI Master HBM test PASSED: read 0xDEADBEEF == expected 0xDEADBEEF
Fill buffer               16.00 MB  in   0.0012 s  =  12.800 GB/s
HBM write                 16.00 MB  in   0.0500 s  =  0.312 GB/s
HBM read-back             16.00 MB  in   0.0800 s  =  0.195 GB/s
Compare                   16.00 MB  in   0.0010 s  =  15.625 GB/s
VERIFICATION PASSED: all 16777216 bytes match
=== TEST PASSED ===
```

### What Each Stage Measures

| Stage | What It Times |
|-------|---------------|
| Fill buffer | File read or `/dev/urandom` → host memory |
| HBM write | Host memory → HBM via XDMA |
| HBM read-back | HBM → host memory via XDMA |
| Compare | Byte-by-byte `memcmp` in host memory |

### VLED Bits

| Bit | Signal | Expected |
|-----|--------|----------|
| 0 | `hbm_ready` | 1 (HBM initialized) |
| 1 | `ddr_ready` | 0 (DDR disabled) |

---

## 7. Why PCIS, Not XDMA

The F2 Small Shell does **not** include XDMA DMA engine hardware in the FPGA. The XDMA kernel driver can be installed and will create `/dev/xdma*` device files (it finds the PCIe endpoint), but actual DMA transfers time out because no engine executes them. All engine registers read as `0x00000000`.

The test uses **PCIS (BAR4 MMIO)** instead:
- **Writes:** `fpga_pci_write_burst` — DWORD-by-DWORD memcpy through the write-combining mmap'd BAR
- **Reads:** `fpga_pci_get_address` — returns a mapped pointer, read DWORD-by-DWORD with volatile access

BAR4 is attached with `BURST_CAPABLE` for write-combining on the write path. If the BAR doesn't support WC, the test falls back to a non-WC attach.

---

## 8. Test Flow Summary

```
test_hbm_dma
  │
  ├── check_slot_config()     — verify AFI is loaded and PCI IDs match
  ├── check_hbm_ready()       — read VLED, confirm bit 0 = 1
  ├── axi_mstr_hbm_test()     — single-word register-level write/read to HBM
  │                              (uses AXI Master CSRs via BAR0)
  └── hbm_pcis_test()
        ├── Fill buffer        — file or urandom → write_buf
        ├── Attach BAR4        — BURST_CAPABLE (write-combining)
        ├── PCIS write         — write_buf → HBM @ 0x10_0000_0000
        ├── PCIS read          — HBM @ 0x10_0000_0000 → read_buf
        └── Compare            — write_buf vs read_buf, report diffs
```

---

## 8. HBM Address Map

| Region | Address Range | Size | Status |
|--------|---------------|------|--------|
| DDR (tied off) | `0x00_0000_0000` – `0x0F_FFFF_FFFF` | 64 GB | Disabled |
| **HBM** | **`0x10_0000_0000`** – **`0x1C_FFFF_FFFF`** | **16 GB** | Active |

The test writes at `0x10_0000_0000` (HBM base). The crossbar decodes addresses >= `0x10_0000_0000` to the DDRB port, which routes through `cl_hbm_axi4` → `cl_hbm_wrapper` → physical HBM2.

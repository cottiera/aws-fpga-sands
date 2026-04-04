# FM-Index Accelerator — Build, Deploy & Test Guide

## Prerequisites

- AWS EC2 instance for buids with FPGA Developer AMI 1.19 (rX works well)
- AWS F2 instance with FPGA Developer AMI 1.19
- S3 bucket for DCP upload (Ensure IAM profile is given to builder instance)
- Rust toolchain (`curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y` on F2)

---

## 1. Build the DCP

```bash
source hdk_setup.sh
export CL_DIR=$HDK_DIR/cl/examples/cl_dram_hbm_dma
cd $CL_DIR/build/scripts
python3 aws_build_dcp_from_cl.py
```

Build takes 2-4 hours. The output DCP and manifest land in:

```
$CL_DIR/build/checkpoints/to_aws/
```

---

## 2. Create the AFI

Run these scripts to submit AFI to S3, then create the FPGA image:

```bash
source $AWS_FPGA_REPO_DIR/hdk/scripts/start_venv.sh
$AWS_FPGA_REPO_DIR/hdk/scripts/create_afi.py
```

Name the AFI, give a description, then automatically scan and select the AFI you created.   
  
Select `us-east-1` as the region. Add the AFI to a new folder (enter custom path) inside the `ece492-w2026-sands-afis` bucket.  
  
Proceed through the CLI guide until the upload begins.  

---

## 3. Load the AFI onto the F2 Instance

Once the upload finished, it will give you a command to run in the F2 instance that looks like the following:

```bash
sudo fpga-load-local-image -S 0 -I <afi-id>
```

Paste it into your F2 terminal. 

Note that the rest of this guide takes place ***inside of the F2 instance*.**

---

## 4. Build the Index File

The FM-index hardware reads a `.fmi` binary built by the `fmindexer` tool. Use the `build-sim` subcommand (not `build`) — it produces the flat binary format the hardware expects.

```bash
cd ~/aws-fpga-sands/sands/fmindexer.rs
cargo build

# Create a test sequence
echo -n "BANANA" > /tmp/seq.txt

# Build the hardware-format index
./target/debug/fmindexer build-sim /tmp/seq.txt /tmp/banana.fmi
```

For real genomic data, replace the sequence file with your reference:

```bash
./target/debug/fmindexer build-sim /path/to/reference.txt /tmp/reference.fmi
```

### Alphabet Encoding

The current test program uses this fixed character-to-code mapping:


| Character | Code |
| --------- | ---- |
| A         | 1    |
| B, C      | 2    |
| G, N      | 3    |
| T         | 4    |


This must match the alphabet the indexer used when building the `.fmi` file.

---

## 5. Build the Host Test

```bash
source sdk_setup.sh
cd ~/aws-fpga-sands/hdk/cl/examples/cl_dram_hbm_dma/software/runtime
make all
```

This produces the `test_fmindex` binary.

---

## 6. Run the Test

```bash
sudo ./test_fmindex --index /tmp/banana.fmi --pattern "ANA"
```

### Options


| Flag              | Description                     |
| ----------------- | ------------------------------- |
| `--index <path>`  | Path to `.fmi` file (required)  |
| `--pattern <str>` | Query pattern string (required) |
| `--slot <hex>`    | FPGA slot ID (default: 0)       |


### Example Test Cases (BANANA)

```bash
# Match: "ANA" appears 2 times
sudo ./test_fmindex --index /tmp/banana.fmi --pattern "ANA"

# Match: "A" appears 3 times
sudo ./test_fmindex --index /tmp/banana.fmi --pattern "A"

# No match: "AB" does not appear
sudo ./test_fmindex --index /tmp/banana.fmi --pattern "AB"
```

### Cross-Check with Software

To verify hardware results against the software implementation:

```bash
cd ~/aws-fpga-sands/sands/fmindexer.rs

# Build a software-format index (different from build-sim)
./target/debug/fmindexer build /tmp/seq.txt /tmp/banana_sw.fmi

# Run software search
./target/debug/fmindexer search /tmp/banana_sw.fmi "ANA" --no-list-all-outputs
# Output: low=2, high=4  (matches hardware l=2, r=4)
```

---

## 7. Interpreting Output

### Successful Match

```
Status:    DONE (match found)
l:         2
r:         4
Occurrences: 2
```

The pattern occurs `r - l` times. The `[l, r)` range identifies which rows in the suffix array contain the matches.

### No Match

```
Status:    FAIL (no match)
```

The pattern does not exist in the reference sequence.

---

## 8. Test Flow Summary

```
test_fmindex --index <path.fmi> --pattern <string>
  │
  ├── check_slot_config()      verify AFI loaded, PCI IDs match
  ├── check VLED bit 0         confirm HBM is ready
  │
  ├── Phase 1: Load index
  │     ├── Assert fmindex_reset
  │     ├── Load .fmi into HBM at 0x10_0000_0000 via BAR4
  │     ├── Readback-verify first 8 DWORDs
  │     └── Write HBM base address to accelerator registers
  │
  └── Phase 2: Query
        ├── Release fmindex_reset (triggers auto-boot)
        ├── Poll CTRL for boot_done
        ├── Encode pattern and write to pattern registers
        ├── Write pattern length and query ID
        ├── Set CTRL submit bit
        ├── Poll CTRL for result_pending
        └── Read result registers (status, l, r, query_id)
```

---

## 9. Troubleshooting


| Symptom                             | Likely Cause                      | Fix                                                                   |
| ----------------------------------- | --------------------------------- | --------------------------------------------------------------------- |
| `HBM not ready (VLED bit 0 is 0)`   | HBM didn't initialize             | Check AFI loaded correctly, reload                                    |
| `Timeout waiting for boot`          | AXI read latency > pipeline depth | Increase `RAM_DELAY_CYCLES` in `cl_dram_hbm_dma.sv`                   |
| `FAIL` on pattern that should match | Pattern encoding mismatch         | Verify character-to-code mapping matches the indexer                  |
| Wrong query ID in result            | DCP timing violation              | Rebuild until timing passes cleanly                                   |
| `Slot is not ready`                 | AFI not loaded                    | Run `fpga-load-local-image`, then `fpga-describe-local-image -S 0 -R` |



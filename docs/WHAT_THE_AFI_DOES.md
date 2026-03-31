# What the AFI Actually Does

## The Short Version

The AFI loaded on your FPGA contains **no compute logic**. It is a wiring harness — a PCIe-accessible memory controller for 16 GB of HBM2 DRAM. When your host CPU writes bytes to a specific PCIe BAR address, those bytes travel through a chain of routing logic and end up stored in the physical HBM2 memory chips on the FPGA board. Reads work the same way in reverse.

---

## The Hardware Stack

Here's what's physically inside the FPGA with this AFI:

```
HOST CPU
  │
  │  PCIe Gen3 x16
  ▼
┌─────────────────────────────────────────────────────────┐
│ FPGA                                                     │
│                                                          │
│ ┌──────────────────────┐                                 │
│ │ AWS Shell (fixed)     │  You don't control this.       │
│ │ - PCIe endpoint       │  AWS provides it.              │
│ │ - BAR0 (registers)    │  It translates PCIe            │
│ │ - BAR4 (PCIS memory)  │  transactions into AXI bus     │
│ │ - Clock generation    │  transactions that your        │
│ │ - Management          │  custom logic sees.            │
│ └──────────┬────────────┘                                │
│            │ AXI4 bus (sh_cl_dma_pcis_bus)                │
│            ▼                                             │
│ ┌──────────────────────┐                                 │
│ │ YOUR CUSTOM LOGIC     │  This is cl_dram_hbm_dma.      │
│ │ (the "CL")            │  You built this. It contains:  │
│ │                        │                                │
│ │  ┌──────────────────┐ │                                │
│ │  │ AXI Crossbar      │ │  Routes by address:           │
│ │  │ (2x2 switch)      │ │  < 0x10... → DDR (dead end)   │
│ │  │                    │ │  ≥ 0x10... → HBM (live)       │
│ │  └───────┬────────────┘ │                                │
│ │          │ (DDRB port)  │                                │
│ │          ▼              │                                │
│ │  ┌──────────────────┐  │                                │
│ │  │ AXI4→AXI3 Bridge │  │  Converts bus protocol.       │
│ │  │ 250 MHz → 450 MHz│  │  Crosses clock domains.       │
│ │  └───────┬──────────┘  │                                │
│ │          ▼              │                                │
│ │  ┌──────────────────┐  │                                │
│ │  │ HBM Controller   │  │  AMD/Xilinx hard IP block.    │
│ │  │ (cl_hbm)         │  │  Manages refresh, timing,     │
│ │  │                   │  │  bank interleaving, etc.      │
│ │  └───────┬──────────┘  │                                │
│ └──────────┼──────────────┘                                │
│            ▼                                               │
│  ┌──────────────────┐                                      │
│  │ Physical HBM2     │  Two stacks of DRAM chips          │
│  │ 16 GB             │  soldered onto the FPGA package.   │
│  │ (on the FPGA die) │  ~450 MHz, 256-bit bus per stack.  │
│  └──────────────────┘                                      │
└────────────────────────────────────────────────────────────┘
```

## What Each Piece Does

| Component | What it is | What it does |
|-----------|-----------|--------------|
| **AWS Shell** | Fixed silicon provided by AWS | Handles PCIe, translates host reads/writes into AXI bus transactions |
| **BAR0** | A small register window (64 KB) | Used for control registers (AXI Master CSRs, OCL, interrupts). NOT for bulk data. |
| **BAR4** | A large memory window (PCIS) | Maps the entire CL address space. Host reads/writes here become AXI transactions at the corresponding address. This is how bulk data reaches HBM. |
| **AXI Crossbar** | A 2-input, 2-output switch | Routes transactions by address. Addresses 0x10_0000_0000+ go to HBM. Addresses below that go to DDR (which is tied off / dead in our build). |
| **AXI4→AXI3 Bridge** | Protocol + clock converter | HBM speaks AXI3 at 450 MHz. The rest of the CL speaks AXI4 at 250 MHz. This block translates between them. |
| **HBM Controller** | AMD/Xilinx hard IP | Handles the complex DDR-like protocol to the physical HBM2 chips: refresh timing, bank management, read/write sequencing. |
| **HBM2 Physical Memory** | DRAM chips on the FPGA package | 16 GB of high-bandwidth memory. Not on a DIMM — it's stacked directly on the FPGA die. |

## What "HBM Working" Means

Three things, and only three things:

1. **The HBM controller initialized** — It calibrated its timing against the physical memory chips and is ready to accept read/write commands. You can verify this: VLED bit 0 = 1.

2. **You can store bytes** — Write a value to an HBM address, read it back, get the same value. The memory is functioning as memory.

3. **The full chain is intact** — Host CPU → PCIe → Shell → crossbar → bridge → HBM controller → physical DRAM, and back. No broken links.

That's it. There is no processing, no transformation, no kernel. The FPGA is acting purely as a memory controller that happens to be accessible over PCIe.

## What the Test Does

```
test_hbm_dma

  1. Check AFI is loaded           (is the FPGA programmed?)
  2. Check VLED bit 0 = 1          (did HBM controller initialize?)
  3. Poke 0xCAFEBABE to BAR4       (write one word to HBM via PCIe)
     Peek it back                  (read it back via PCIe)
     Compare                       (same value? → chain works)
  4. Write 1 MB of incrementing    (stress test at scale)
     DWORDs, read them all back,
     compare every one
```

If all DWORDs match, the data path is validated. You can then trust this path to carry real data (e.g., an FM-index) in future phases.

## Address Map

| Range | What | Status |
|-------|------|--------|
| `0x00_0000_0000` – `0x0F_FFFF_FFFF` | DDR (64 GB window) | Dead — `EN_DDR=0`, crossbar routes here but `sh_ddr` just ties off all signals |
| `0x10_0000_0000` – `0x1C_FFFF_FFFF` | HBM (16 GB) | **Active** — this is where your data goes |

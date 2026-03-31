// ============================================================================
// HBM Data Pipeline — Minimal Validation Test
//
// Proves the data path works: host → PCIe BAR4 → AXI crossbar → HBM → back.
//
// Test 1: Write and read back a single 32-bit word via poke/peek.
// Test 2: Write and read back a buffer via write_burst / peek.
//         - Default: 1 MB of incrementing DWORDs
//         - With --file: loads a file from disk into HBM instead
//
// Uses PCIS (BAR4 MMIO). No XDMA — the F2 Small Shell has no DMA engine.
// ============================================================================

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <errno.h>
#include <time.h>
#include <sys/stat.h>

#include "fpga_pci.h"
#include "fpga_mgmt.h"
#include "utils/lcd.h"

#include "test_dram_dma_common.h"

#define HBM_BASE  (0x10ULL << 32)   // 0x10_0000_0000 — start of HBM address space
#define MB        (1024ULL * 1024)

static const struct logger *logger = &logger_stdout;

// -------------------------------------------------------------------------
// Test 1: single-word poke/peek through BAR4 → HBM
// -------------------------------------------------------------------------

static int test_single_word(pci_bar_handle_t bar4)
{
    const uint64_t addr = HBM_BASE;
    const uint32_t pattern = 0xCAFEBABE;
    uint32_t readback = 0;
    int rc;

    log_info("[Test 1] Writing 0x%08X to HBM at 0x%llX via BAR4 poke...",
             pattern, (unsigned long long)addr);

    rc = fpga_pci_poke(bar4, addr, pattern);
    if (rc) {
        log_error("poke failed (rc=%d)", rc);
        return rc;
    }

    rc = fpga_pci_peek(bar4, addr, &readback);
    if (rc) {
        log_error("peek failed (rc=%d)", rc);
        return rc;
    }

    log_info("[Test 1] Read back: 0x%08X", readback);

    if (readback == pattern) {
        log_info("[Test 1] PASSED — single word round-trip OK");
        return 0;
    } else {
        log_error("[Test 1] FAILED — wrote 0x%08X, read 0x%08X",
                  pattern, readback);
        return 1;
    }
}

// -------------------------------------------------------------------------
// Test 2: bulk write_burst / peek loop through BAR4 → HBM
// -------------------------------------------------------------------------

static double elapsed_sec(struct timespec *a, struct timespec *b)
{
    return (b->tv_sec - a->tv_sec) + (b->tv_nsec - a->tv_nsec) / 1e9;
}

static int load_file(const char *path, uint8_t **buf_out, size_t *size_out)
{
    struct stat st;
    if (stat(path, &st) != 0) {
        log_error("Cannot stat file: %s (%s)", path, strerror(errno));
        return -1;
    }

    size_t file_size = (size_t)st.st_size;
    size_t aligned = (file_size + 3) & ~3ULL;

    uint8_t *buf = calloc(1, aligned);
    if (!buf) {
        log_error("malloc failed for %zu bytes", aligned);
        return -ENOMEM;
    }

    FILE *fp = fopen(path, "rb");
    if (!fp) {
        log_error("Cannot open file: %s (%s)", path, strerror(errno));
        free(buf);
        return -1;
    }

    size_t nread = fread(buf, 1, file_size, fp);
    fclose(fp);

    if (nread != file_size) {
        log_error("Short read: got %zu of %zu bytes", nread, file_size);
        free(buf);
        return -1;
    }

    *buf_out  = buf;
    *size_out = aligned;
    log_info("Loaded file: %s (%zu bytes, padded to %zu for DWORD alignment)",
             path, file_size, aligned);
    return 0;
}

static int test_bulk(pci_bar_handle_t bar4, size_t size, const char *file_path)
{
    int rc = 0;
    struct timespec t0, t1;
    uint32_t *write_buf = NULL;
    uint32_t *read_buf  = NULL;

    if (file_path) {
        uint8_t *raw = NULL;
        size_t   raw_size = 0;
        rc = load_file(file_path, &raw, &raw_size);
        if (rc) return rc;
        write_buf = (uint32_t *)raw;
        size = raw_size;
    } else {
        write_buf = malloc(size);
        if (!write_buf) {
            log_error("malloc failed for %zu bytes", size);
            return -ENOMEM;
        }
        size_t dword_count = size / 4;
        for (size_t i = 0; i < dword_count; i++)
            write_buf[i] = (uint32_t)i;
    }

    size_t dword_count = size / 4;
    read_buf = calloc(dword_count, 4);
    if (!read_buf) {
        log_error("malloc failed for %zu bytes", size);
        rc = -ENOMEM;
        goto out;
    }

    // -- Write ---------------------------------------------------------------
    log_info("[Test 2] Writing %zu bytes (%zu DWORDs) to HBM at 0x%llX...",
             size, dword_count, (unsigned long long)HBM_BASE);

    clock_gettime(CLOCK_MONOTONIC, &t0);
    rc = fpga_pci_write_burst(bar4, HBM_BASE, write_buf, dword_count);
    clock_gettime(CLOCK_MONOTONIC, &t1);

    if (rc) {
        log_error("write_burst failed (rc=%d)", rc);
        goto out;
    }
    double ws = elapsed_sec(&t0, &t1);
    log_info("[Test 2] Write done in %.4f s  (%.2f MB/s)",
             ws, (size / (double)MB) / ws);

    // -- Read back -----------------------------------------------------------
    log_info("[Test 2] Reading back %zu DWORDs...", dword_count);

    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (size_t i = 0; i < dword_count; i++) {
        rc = fpga_pci_peek(bar4, HBM_BASE + i * 4, &read_buf[i]);
        if (rc) {
            log_error("peek failed at DWORD %zu (rc=%d)", i, rc);
            goto out;
        }
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);

    double rs = elapsed_sec(&t0, &t1);
    log_info("[Test 2] Read done in %.4f s  (%.2f MB/s)",
             rs, (size / (double)MB) / rs);

    // -- Compare -------------------------------------------------------------
    size_t mismatches = 0;
    for (size_t i = 0; i < dword_count; i++) {
        if (write_buf[i] != read_buf[i]) {
            if (mismatches == 0)
                log_error("First mismatch at DWORD %zu: wrote 0x%08X, read 0x%08X",
                          i, write_buf[i], read_buf[i]);
            mismatches++;
        }
    }

    if (mismatches == 0) {
        log_info("[Test 2] PASSED — all %zu DWORDs match", dword_count);
        rc = 0;
    } else {
        log_error("[Test 2] FAILED — %zu / %zu DWORDs differ", mismatches, dword_count);
        rc = 1;
    }

out:
    free(write_buf);
    free(read_buf);
    return rc;
}

// -------------------------------------------------------------------------
// CLI
// -------------------------------------------------------------------------

static void usage(const char *prog)
{
    printf("Usage: %s [--slot <id>] [--size <bytes>] [--file <path>]\n"
           "  --slot   FPGA slot (default 0, hex)\n"
           "  --size   Bulk test size in bytes (default 1 MB, must be multiple of 4)\n"
           "           Ignored when --file is used (size comes from the file).\n"
           "  --file   Load this file into HBM instead of a test pattern\n",
           prog);
}

// -------------------------------------------------------------------------
// main
// -------------------------------------------------------------------------

int main(int argc, char **argv)
{
    int rc;
    uint32_t slot_id = 0;
    size_t   size    = 1 * MB;
    const char *file_path = NULL;
    pci_bar_handle_t bar4 = PCI_BAR_HANDLE_INIT;

    // Parse args
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--slot") && i + 1 < argc)
            sscanf(argv[++i], "%x", &slot_id);
        else if (!strcmp(argv[i], "--size") && i + 1 < argc)
            size = strtoul(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--file") && i + 1 < argc)
            file_path = argv[++i];
        else { usage(argv[0]); return 1; }
    }

    if (!file_path && size % 4 != 0) {
        fprintf(stderr, "Size must be a multiple of 4\n");
        return 1;
    }

    // Init
    rc = log_init("test_hbm_dma");
    if (rc) { fprintf(stderr, "log_init failed\n"); return 1; }
    rc = log_attach(logger, NULL, 0);
    if (rc) { fprintf(stderr, "log_attach failed\n"); return 1; }

    log_info("========================================");
    log_info("  HBM Data Pipeline — Validation Test   ");
    log_info("========================================");
    if (file_path)
        log_info("Slot: %u    File: %s", slot_id, file_path);
    else
        log_info("Slot: %u    Bulk size: %zu bytes (%.2f MB)", slot_id, size, size/(double)MB);

    rc = fpga_mgmt_init();
    fail_on(rc, done, "fpga_mgmt_init failed");

    rc = check_slot_config(slot_id);
    fail_on(rc, done, "Slot config check failed — is the AFI loaded?");

    // Check HBM ready via VLED
    uint16_t vled;
    rc = fpga_mgmt_get_vLED_status(slot_id, &vled);
    fail_on(rc, done, "Cannot read VLED");
    log_info("VLED: 0x%04X  (bit0 = hbm_ready, bit1 = ddr_ready)", vled);
    if (!(vled & 0x1)) {
        log_error("HBM not ready (VLED bit 0 is 0). Aborting.");
        rc = 1; goto done;
    }
    log_info("HBM controller is initialized and ready.");

    // Attach BAR4 (PCIS — the path to HBM)
    log_info("Attaching BAR4 (PCIS) with write-combining...");
    rc = fpga_pci_attach(slot_id, FPGA_APP_PF, APP_PF_BAR4, BURST_CAPABLE, &bar4);
    if (rc) {
        log_info("Write-combining not available (rc=%d), attaching without it...", rc);
        rc = fpga_pci_attach(slot_id, FPGA_APP_PF, APP_PF_BAR4, 0, &bar4);
    }
    fail_on(rc, done, "Cannot attach BAR4");
    log_info("BAR4 attached.");

    // Run tests
    rc = test_single_word(bar4);
    fail_on(rc, done, "Single-word test failed");

    rc = test_bulk(bar4, size, file_path);
    fail_on(rc, done, "Bulk test failed");

done:
    log_info("========================================");
    log_info("  RESULT: %s", rc == 0 ? "ALL TESTS PASSED" : "FAILED");
    log_info("========================================");

    if (bar4 != PCI_BAR_HANDLE_INIT)
        fpga_pci_detach(bar4);
    return rc;
}

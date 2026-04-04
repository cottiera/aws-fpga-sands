// ============================================================================
// FM Index Accelerator — MVP Host Test
//
// End-to-end test:
//   1. Load a .fmi index binary into HBM via BAR4 (PCIS write_burst)
//   2. Release FM_Index from reset; wait for auto-boot
//   3. Encode a query pattern, submit via OCL registers
//   4. Poll for result, print (l, r) interval
//
// Usage:
//   test_fmindex --index <path.fmi> --pattern <string> [--slot <id>]
//
// Pattern encoding: characters are sorted alphabetically (excluding '$'),
// then assigned 1-based indices. E.g. for BANANA: A=1, B=2, N=3.
// The alphabet mapping is derived from the unique characters in the pattern
// plus the reference — the caller must ensure consistency with the indexer.
// For the BANANA MVP, the alphabet is hardcoded: A=1, B=2, N=3.
// ============================================================================

#define _DEFAULT_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <errno.h>
#include <ctype.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>

#include "fpga_pci.h"
#include "fpga_mgmt.h"
#include "utils/lcd.h"

#include "test_dram_dma_common.h"

#define HBM_BASE       (0x10ULL << 32)
#define OCL_SLOT6_BASE 0x0600

#define REG_CTRL           (OCL_SLOT6_BASE + 0x00)
#define REG_PAT_LEN        (OCL_SLOT6_BASE + 0x04)
#define REG_QUERY_ID       (OCL_SLOT6_BASE + 0x08)
#define REG_RESULT_STATUS  (OCL_SLOT6_BASE + 0x0C)
#define REG_RESULT_L       (OCL_SLOT6_BASE + 0x10)
#define REG_RESULT_R       (OCL_SLOT6_BASE + 0x14)
#define REG_RESULT_QID     (OCL_SLOT6_BASE + 0x18)
#define REG_HBM_BASE_LO   (OCL_SLOT6_BASE + 0x1C)
#define REG_HBM_BASE_HI   (OCL_SLOT6_BASE + 0x20)
#define REG_PATTERN_BASE   (OCL_SLOT6_BASE + 0x40)

#define CTRL_SUBMIT         (1U << 0)
#define CTRL_RESULT_PENDING (1U << 1)
#define CTRL_BOOT_DONE      (1U << 2)
#define CTRL_FMINDEX_RESET  (1U << 3)

#define PAT_MAX_LEN  150
#define CHAR_WIDTH   3

static const struct logger *logger = &logger_stdout;

// -------------------------------------------------------------------------
// Encode a pattern string into 3-bit symbols
//
// For the BANANA MVP, we use a fixed alphabet: A=1, B=2, N=3.
// A general implementation would read the alphabet from the index header.
// -------------------------------------------------------------------------

static int encode_pattern(const char *str, uint32_t *encoded_words, int *pat_len)
{
    int len = (int)strlen(str);
    if (len > PAT_MAX_LEN) {
        fprintf(stderr, "Pattern too long (%d > %d)\n", len, PAT_MAX_LEN);
        return -1;
    }

    int total_bits = len * CHAR_WIDTH;
    int num_words = (total_bits + 31) / 32;

    memset(encoded_words, 0, num_words * sizeof(uint32_t));

    for (int i = 0; i < len; i++) {
        uint32_t code;
        switch (toupper((unsigned char)str[i])) {
            case 'A': code = 1; break;
            case 'B': code = 2; break;
            case 'C': code = 2; break;
            case 'G': code = 3; break;
            case 'N': code = 3; break;
            case 'T': code = 4; break;
            default:
                fprintf(stderr, "Unknown character '%c' in pattern\n", str[i]);
                return -1;
        }
        int bit_pos = i * CHAR_WIDTH;
        int word_idx = bit_pos / 32;
        int bit_off  = bit_pos % 32;
        encoded_words[word_idx] |= (code << bit_off);
    }

    *pat_len = len;
    return num_words;
}

// -------------------------------------------------------------------------
// Load file helper
// -------------------------------------------------------------------------

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
    log_info("Loaded file: %s (%zu bytes, padded to %zu)", path, file_size, aligned);
    return 0;
}

// -------------------------------------------------------------------------
// CLI
// -------------------------------------------------------------------------

static void usage(const char *prog)
{
    printf("Usage: %s --index <path.fmi> --pattern <string> [--slot <id>]\n"
           "  --index    Path to .fmi index binary from fmindexer build-sim\n"
           "  --pattern  Query pattern string (e.g. 'BAN')\n"
           "  --slot     FPGA slot (default 0, hex)\n",
           prog);
}

// -------------------------------------------------------------------------
// main
// -------------------------------------------------------------------------

int main(int argc, char **argv)
{
    int rc;
    uint32_t slot_id = 0;
    const char *index_path = NULL;
    const char *pattern_str = NULL;
    pci_bar_handle_t bar0 = PCI_BAR_HANDLE_INIT;
    pci_bar_handle_t bar4 = PCI_BAR_HANDLE_INIT;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--slot") && i + 1 < argc)
            sscanf(argv[++i], "%x", &slot_id);
        else if (!strcmp(argv[i], "--index") && i + 1 < argc)
            index_path = argv[++i];
        else if (!strcmp(argv[i], "--pattern") && i + 1 < argc)
            pattern_str = argv[++i];
        else { usage(argv[0]); return 1; }
    }

    if (!index_path || !pattern_str) {
        usage(argv[0]);
        return 1;
    }

    rc = log_init("test_fmindex");
    if (rc) { fprintf(stderr, "log_init failed\n"); return 1; }
    rc = log_attach(logger, NULL, 0);
    if (rc) { fprintf(stderr, "log_attach failed\n"); return 1; }

    log_info("========================================");
    log_info("  FM Index Accelerator — MVP Test        ");
    log_info("========================================");
    log_info("Slot: %u    Index: %s    Pattern: %s", slot_id, index_path, pattern_str);

    rc = fpga_mgmt_init();
    fail_on(rc, done, "fpga_mgmt_init failed");

    rc = check_slot_config(slot_id);
    fail_on(rc, done, "Slot config check failed");

    // Check HBM ready via VLED
    uint16_t vled;
    rc = fpga_mgmt_get_vLED_status(slot_id, &vled);
    fail_on(rc, done, "Cannot read VLED");
    log_info("VLED: 0x%04X  (bit0 = hbm_ready)", vled);
    if (!(vled & 0x1)) {
        log_error("HBM not ready (VLED bit 0 is 0). Aborting.");
        rc = 1; goto done;
    }

    // Attach BARs
    rc = fpga_pci_attach(slot_id, FPGA_APP_PF, APP_PF_BAR0, 0, &bar0);
    fail_on(rc, done, "Cannot attach BAR0 (OCL)");

    rc = fpga_pci_attach(slot_id, FPGA_APP_PF, APP_PF_BAR4, BURST_CAPABLE, &bar4);
    if (rc) {
        log_info("Write-combining not available, attaching without it...");
        rc = fpga_pci_attach(slot_id, FPGA_APP_PF, APP_PF_BAR4, 0, &bar4);
    }
    fail_on(rc, done, "Cannot attach BAR4 (PCIS)");

    // =====================================================================
    // Phase 1: Load index into HBM
    // =====================================================================

    // Hold FM_Index in reset during loading
    log_info("[Phase 1] Holding FM_Index in reset...");
    rc = fpga_pci_poke(bar0, REG_CTRL, CTRL_FMINDEX_RESET);
    fail_on(rc, done, "Failed to assert fmindex_reset");

    // Load index file
    uint8_t *index_buf = NULL;
    size_t index_size = 0;
    rc = load_file(index_path, &index_buf, &index_size);
    fail_on(rc, done, "Failed to load index file");

    size_t dword_count = index_size / 4;
    log_info("[Phase 1] Writing %zu bytes (%zu DWORDs) to HBM at 0x%llX...",
             index_size, dword_count, (unsigned long long)HBM_BASE);

    rc = fpga_pci_write_burst(bar4, HBM_BASE, (uint32_t *)index_buf, dword_count);
    fail_on(rc, done, "write_burst failed");
    log_info("[Phase 1] Index loaded into HBM.");

    // Readback verification: read first 8 DWORDs back via BAR4
    log_info("[Phase 1] Verifying HBM readback...");
    int rb_errors = 0;
    uint32_t *index_words = (uint32_t *)index_buf;
    for (int i = 0; i < 8 && i < (int)dword_count; i++) {
        uint32_t rb;
        rc = fpga_pci_peek(bar4, HBM_BASE + i * 4, &rb);
        if (rc) {
            log_error("  HBM readback peek failed at DWORD %d (rc=%d)", i, rc);
            rb_errors++;
        } else {
            log_info("  HBM[%d]: wrote=0x%08X  read=0x%08X  %s",
                     i, index_words[i], rb,
                     (rb == index_words[i]) ? "OK" : "MISMATCH");
            if (rb != index_words[i]) rb_errors++;
        }
    }
    if (rb_errors)
        log_error("[Phase 1] HBM readback had %d errors!", rb_errors);
    else
        log_info("[Phase 1] HBM readback OK.");

    // Write HBM base address to accelerator registers
    rc = fpga_pci_poke(bar0, REG_HBM_BASE_LO, (uint32_t)(HBM_BASE & 0xFFFFFFFF));
    fail_on(rc, done, "Failed to write HBM_BASE_LO");
    rc = fpga_pci_poke(bar0, REG_HBM_BASE_HI, (uint32_t)(HBM_BASE >> 32));
    fail_on(rc, done, "Failed to write HBM_BASE_HI");

    // =====================================================================
    // Phase 2: Boot and query
    // =====================================================================

    // Verify HBM base address readback from accelerator registers
    {
        uint32_t lo_rb, hi_rb;
        fpga_pci_peek(bar0, REG_HBM_BASE_LO, &lo_rb);
        fpga_pci_peek(bar0, REG_HBM_BASE_HI, &hi_rb);
        log_info("[Phase 1] Accel HBM_BASE regs: LO=0x%08X HI=0x%08X (expect LO=0x%08X HI=0x%08X)",
                 lo_rb, hi_rb,
                 (uint32_t)(HBM_BASE & 0xFFFFFFFF),
                 (uint32_t)(HBM_BASE >> 32));
    }

    // Release FM_Index from reset
    log_info("[Phase 2] Releasing FM_Index from reset (auto-boot starts)...");
    rc = fpga_pci_poke(bar0, REG_CTRL, 0x0);
    fail_on(rc, done, "Failed to clear fmindex_reset");

    // Poll for boot_done with progress reporting
    log_info("[Phase 2] Waiting for boot_done...");
    uint32_t ctrl_val;
    int timeout = 10000;
    int polls = 0;
    do {
        rc = fpga_pci_peek(bar0, REG_CTRL, &ctrl_val);
        fail_on(rc, done, "Failed to read CTRL");
        if (ctrl_val & CTRL_BOOT_DONE) break;
        if (polls < 10 || (polls % 1000) == 0)
            log_info("  poll %d: CTRL=0x%08X", polls, ctrl_val);
        polls++;
        usleep(100);
    } while (--timeout > 0);

    if (!(ctrl_val & CTRL_BOOT_DONE)) {
        log_error("Timeout waiting for FM_Index boot after %d polls. CTRL=0x%08X", polls, ctrl_val);
        // Dump all readable registers for diagnostics
        uint32_t diag;
        fpga_pci_peek(bar0, REG_RESULT_STATUS, &diag);
        log_error("  RESULT_STATUS=0x%08X", diag);
        fpga_pci_peek(bar0, REG_RESULT_L, &diag);
        log_error("  RESULT_L=0x%08X", diag);
        fpga_pci_peek(bar0, REG_RESULT_R, &diag);
        log_error("  RESULT_R=0x%08X", diag);
        rc = 1; goto done;
    }
    log_info("[Phase 2] FM_Index boot complete.");

    // Encode pattern
    uint32_t encoded[24];
    int pat_len = 0;
    int num_words = encode_pattern(pattern_str, encoded, &pat_len);
    if (num_words < 0) { rc = 1; goto done; }

    log_info("[Phase 2] Pattern '%s' encoded to %d symbols, %d words", pattern_str, pat_len, num_words);

    // Write pattern registers
    for (int i = 0; i < num_words; i++) {
        rc = fpga_pci_poke(bar0, REG_PATTERN_BASE + i * 4, encoded[i]);
        fail_on(rc, done, "Failed to write PATTERN[%d]", i);
    }

    // Write pattern length and query ID
    rc = fpga_pci_poke(bar0, REG_PAT_LEN, (uint32_t)pat_len);
    fail_on(rc, done, "Failed to write PAT_LEN");

    uint32_t query_id = 42;
    rc = fpga_pci_poke(bar0, REG_QUERY_ID, query_id);
    fail_on(rc, done, "Failed to write QUERY_ID");

    // Submit the query
    log_info("[Phase 2] Submitting query (id=%u)...", query_id);
    rc = fpga_pci_poke(bar0, REG_CTRL, CTRL_SUBMIT);
    fail_on(rc, done, "Failed to write CTRL submit");

    // Poll for result_pending
    log_info("[Phase 2] Waiting for result...");
    timeout = 100000;
    do {
        rc = fpga_pci_peek(bar0, REG_CTRL, &ctrl_val);
        fail_on(rc, done, "Failed to read CTRL");
        if (ctrl_val & CTRL_RESULT_PENDING) break;
        usleep(10);
    } while (--timeout > 0);

    if (!(ctrl_val & CTRL_RESULT_PENDING)) {
        log_error("Timeout waiting for result. CTRL=0x%08X", ctrl_val);
        rc = 1; goto done;
    }

    // Read results
    uint32_t result_status, result_l, result_r, result_qid;
    rc  = fpga_pci_peek(bar0, REG_RESULT_STATUS, &result_status);
    rc |= fpga_pci_peek(bar0, REG_RESULT_L, &result_l);
    rc |= fpga_pci_peek(bar0, REG_RESULT_R, &result_r);
    rc |= fpga_pci_peek(bar0, REG_RESULT_QID, &result_qid);
    fail_on(rc, done, "Failed to read result registers");

    bool is_done = (result_status & 1) != 0;
    bool is_fail = (result_status & 2) != 0;

    log_info("========================================");
    log_info("  RESULT");
    log_info("========================================");
    log_info("  Query ID:  %u", result_qid);
    log_info("  Status:    %s", is_done ? "DONE (match found)" : (is_fail ? "FAIL (no match)" : "UNKNOWN"));
    log_info("  l:         %u", result_l);
    log_info("  r:         %u", result_r);
    if (is_done)
        log_info("  Occurrences: %u", result_r - result_l);
    log_info("========================================");

    // Clear result_pending
    rc = fpga_pci_poke(bar0, REG_CTRL, CTRL_RESULT_PENDING);
    fail_on(rc, done, "Failed to clear result_pending");

    rc = (is_done || is_fail) ? 0 : 1;

done:
    log_info("RESULT: %s", rc == 0 ? "PASSED" : "FAILED");
    free(index_buf);
    if (bar0 != PCI_BAR_HANDLE_INIT) fpga_pci_detach(bar0);
    if (bar4 != PCI_BAR_HANDLE_INIT) fpga_pci_detach(bar4);
    return rc;
}

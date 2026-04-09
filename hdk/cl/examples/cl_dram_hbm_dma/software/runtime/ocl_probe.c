#define _DEFAULT_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>

#include "fpga_pci.h"
#include "fpga_mgmt.h"
#include "utils/lcd.h"

#include "test_dram_dma_common.h"

static const struct logger *logger = &logger_stdout;

int main(int argc, char **argv)
{
    uint32_t slot_id = 0;
    pci_bar_handle_t bar0 = PCI_BAR_HANDLE_INIT;
    int rc;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--slot") && i + 1 < argc)
            sscanf(argv[++i], "%x", &slot_id);
    }

    rc = log_init("ocl_probe");
    rc |= log_attach(logger, NULL, 0);
    if (rc) { fprintf(stderr, "log init failed\n"); return 1; }

    rc = fpga_mgmt_init();
    if (rc) { log_error("fpga_mgmt_init failed"); return 1; }

    rc = check_slot_config(slot_id);
    if (rc) { log_error("slot config check failed"); return 1; }

    rc = fpga_pci_attach(slot_id, FPGA_APP_PF, APP_PF_BAR0, 0, &bar0);
    if (rc) { log_error("cannot attach BAR0"); return 1; }

    struct { uint32_t addr; const char *name; } probes[] = {
        { 0x0000, "slot  0  pcim_tst   CTRL" },
        { 0x0100, "slot  1  ddra_tst   CTRL" },
        { 0x0500, "slot  5  axi_mstr   CTRL" },
        { 0x0600, "slot  6  fmindex    CTRL" },
        { 0x0604, "slot  6  fmindex    PAT_LEN" },
        { 0x0608, "slot  6  fmindex    QUERY_ID" },
        { 0x060C, "slot  6  fmindex    RESULT_STATUS" },
        { 0x0610, "slot  6  fmindex    RESULT_L" },
        { 0x0614, "slot  6  fmindex    RESULT_R" },
        { 0x0618, "slot  6  fmindex    RESULT_QID" },
        { 0x061C, "slot  6  fmindex    HBM_BASE_LO" },
        { 0x0620, "slot  6  fmindex    HBM_BASE_HI" },
        { 0x0700, "slot  7  (unused)   dead_beef" },
        { 0x0D00, "slot 13  int_tst    CTRL" },
    };
    int n = sizeof(probes) / sizeof(probes[0]);

    log_info("============================================");
    log_info("  OCL Slot Probe — reading all slots");
    log_info("============================================");

    int deadbeef_count = 0;
    for (int i = 0; i < n; i++) {
        uint32_t val = 0xCAFECAFE;
        rc = fpga_pci_peek(bar0, probes[i].addr, &val);
        const char *tag = "";
        if (rc != 0)
            tag = "  ** PEEK FAILED **";
        else if (val == 0xDEADBEEF) {
            tag = "  <-- DEADBEEF";
            deadbeef_count++;
        }
        log_info("  0x%04X  %-35s  rc=%d  val=0x%08X%s",
                 probes[i].addr, probes[i].name, rc, val, tag);
    }

    log_info("--------------------------------------------");
    if (deadbeef_count == n)
        log_info("  ALL reads returned DEADBEEF — OCL bus may be broken or wrong AFI");
    else if (deadbeef_count > 0)
        log_info("  %d/%d reads returned DEADBEEF — check specific slots above", deadbeef_count, n);
    else
        log_info("  No DEADBEEF values — all slots responding");
    log_info("============================================");

    fpga_pci_detach(bar0);
    return 0;
}

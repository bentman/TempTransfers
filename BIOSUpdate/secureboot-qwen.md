## Implementation Process Outline

1.  **Catalog Sync:** Subscribe to Dell Business Client Update Catalog (V3) in SCCM SUP; sync BIOS-specific metadata.
2.  **ADR Creation:** Create Automatic Deployment Rule filtering for "BIOS/Firmware" updates targeting Dell hardware collections.
3.  **Deployment Configuration:** Configure Mandatory deployment using existing site policy (Windows Update UX, deadlines, deferrals).
4.  **Safety Controls:** Ensure BitLocker suspension is automated (Task Sequence pre-script or SCCM setting) prior to BIOS flash.
5.  **QA Pilot:** Deploy ADR to QA device collection (1% fleet); validate BIOS version increment and successful reboot.
6.  **Script Deployment:** Deploy Secure Boot PowerShell script (via SCCM Package/Script) to devices reporting successful BIOS update.
7.  **Script Execution:** Script validates UEFI mode, queries `UEFICA2023Status`, applies cert via `WinCsFlags.exe` if needed, and logs to `$env:ProgramData\CFGUtil\SecureBoot2023\`.
8.  **Idempotency Check:** Verify script creates `.flg`/`.dun` completion marker to prevent re-runs.
9.  **PROD Phased Rollout:** Expand ADR and Script deployments via rings (1% → 10% → 100%) based on QA success criteria.
10. **Compliance Reporting:** Monitor SCCM compliance states and script logs; target ≥90% completion within 14 days.

---

## Jira Story Drafts

### Story 1: QA Validation
**Title:** Validate Dell BIOS & Secure Boot Certificate Update Workflow (QA)
**Description:** Execute BIOS update ADR and Secure Boot script in QA environment to confirm stability, logging, and idempotency before production release. This addresses the UEFI CA 2023 expiration risk.
**Acceptance Criteria:**
*   QA devices successfully update BIOS version via SCCM ADR without user intervention errors.
*   BitLocker suspends/resumes automatically without recovery key prompts.
*   Secure Boot script executes, logs stages to `$env:ProgramData\CFGUtil\SecureBoot2023\`, and creates completion flag file.
*   Registry key `UEFICA2023Status` reflects "Updated" post-script execution.
*   Change Advisory Board (CAB) approval granted for PROD rollout based on QA logs.
**Labels:** secure-boot, bios-update, dell, sccm, change-request, qa

### Story 2: Production Implementation
**Title:** Execute Phased Dell BIOS & Secure Boot Certificate Update (PROD)
**Description:** Deploy BIOS updates and Secure Boot script to production fleet using phased rings to mitigate risk. Ensures compliance with UEFI CA 2023 security requirements across 99% Dell hardware.
**Acceptance Criteria:**
*   Deployment expands via rings (1% → 10% → 100%) only after previous ring achieves ≥90% compliance.
*   SCCM dashboards show BIOS version compliance for targeted models.
*   Secure Boot script completion flags verified on sampled devices across all rings.
*   No critical incidents (boot failures, BitLocker locks) reported during rollout windows.
*   Final change closure report includes compliance metrics and log samples.
**Labels:** secure-boot, bios-update, dell, sccm, change-request, prod
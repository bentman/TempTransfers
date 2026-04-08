**Process Outline**

- Create and test BIOS-only ADR using Dell Business Client Update Catalog in SCCM, targeted to Dell hardware collections.
- Deploy mandatory BIOS update with Windows Update-style notifications, deadlines, and deferrals aligned to standard patching cycle.
- Monitor and complete phased BIOS rollout in production (starting with pilot ring).
- Validate post-BIOS compliance (~65% of fleet) via Intune/SCCM reporting and registry/firmware checks.
- Deploy Secure Boot 2023 certificate update PowerShell script via Intune/SCCM after BIOS confirmation.
- Script executes in stages: setup Secure-Boot-Update scheduled task, apply registry flags, monitor UEFICA2023Status and related keys.
- Script logs progress to `$env:ProgramData\CFGUtil\SecureBoot2023\` and creates `.flg`/`.dun` completion marker for idempotency.
- Perform validation of script execution, registry status, and Secure Boot database updates.
- Monitor for successful certificate update and revocation across fleet.
- Document completion and update compliance baseline.

```markdown
**Jira Story 1**

**Title:** Implement Secure Boot UEFI CA 2023 Update - QA Validation

**Description:**  
Following successful Dell BIOS updates via SCCM, deploy and validate the PowerShell script that applies the Windows Secure Boot UEFI CA 2023 certificate updates. This addresses the 2011 certificate expiration (June/October 2026) to maintain boot integrity and mitigate CVE-2023-24932. Perform full validation in QA environment first.

**Acceptance Criteria:**
- BIOS updates confirmed applied on QA Dell devices (≥95% success rate).
- Script deploys successfully, runs in stages, sets scheduled task, updates registry keys (UEFICA2023Status etc.), and creates completion .flg/.dun file.
- Logs written to $env:ProgramData\CFGUtil\SecureBoot2023\ with full stage audit trail.
- Post-script validation confirms Secure Boot database updated with 2023 CAs and 2011 PCA revocation status.
- Script verified as idempotent (does not re-run on completed devices).
- All testing documented with logs and screenshots attached.

**Labels:** secure-boot, bios-update, dell, sccm, change-request, qa-validation
```

```markdown
**Jira Story 2**

**Title:** Implement Secure Boot UEFI CA 2023 Update - Production Rollout

**Description:**  
Roll out the Secure Boot 2023 certificate update script to production following QA validation and BIOS updates. This ensures continued Secure Boot integrity for the 99% Dell fleet ahead of 2011 certificate expiration.

**Acceptance Criteria:**
- QA story successfully completed and signed off.
- Script deployed via Intune/SCCM to production in ring-based phases (Pilot → Broad).
- ≥98% compliance achieved for Secure Boot 2023 updates across targeted Dell devices.
- Script idempotency confirmed (completion markers prevent re-execution).
- Logging and audit trail verified in $env:ProgramData\CFGUtil\SecureBoot2023\ for sampled devices.
- Post-rollout monitoring shows no increase in boot issues or related incidents; compliance reported to change board.

**Labels:** secure-boot, bios-update, dell, sccm, change-request, production
```
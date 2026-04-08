## Implementation Process Outline

* **Catalog Integration:** Synchronize the Dell Business Client Update Catalog in SCCM and filter for BIOS-only updates targeting the identified fleet.
* **ADR Configuration:** Establish an Automatic Deployment Rule (ADR) for Dell hardware collections with mandatory deadlines and standard business patching notifications.
* **Targeting Logic:** Define collections specifically for the ~65% of devices requiring the BIOS prerequisite before the certificate update.
* **Script Staging:** Prepare the PowerShell update script to include administrative elevation checks, UEFI mode validation, and the `WinCsFlags.exe` utility.
* **Logging Initialization:** Configure the script to create and write to `$env:ProgramData\CFGUtil\SecureBoot2023\` for granular stage tracking.
* **Task Scheduling:** Execute the script to set up the `Secure-Boot-Update` Microsoft scheduled task as the primary mechanism for certificate application.
* **Registry Monitoring:** Program the script to query `UEFICA2023Status` and related keys to confirm the successful transition of the Secure Boot database.
* **Idempotency Check:** Implement logic to detect existing `.flg` or `.dun` marker files, ensuring the script terminates immediately if the update is already complete.
* **Phased Deployment:** Release BIOS updates via SCCM, followed by the Secure Boot script deployment through Intune/SCCM to validated devices.
* **Compliance Reporting:** Monitor deployment status via SCCM monitoring and Intune hardware inventory to verify successful certificate rotation across the fleet.

---

## Jira Story Drafts

### 1. QA Validation
**Title:** [QA] Validate BIOS Prerequisite and Secure Boot 2023 CA Update Script
**Description:** Verify the end-to-end deployment of BIOS updates and the PowerShell certificate update script on pilot Dell hardware. This ensures firmware stability and validates the script’s staging and logging logic before production release.
**Acceptance Criteria:**
* **Pilot Success:** BIOS updates successfully applied to 100% of the QA pilot group via SCCM ADR.
* **Script Logic:** PowerShell script correctly identifies UEFI mode and administrative elevation on test units.
* **State Tracking:** Verification that the `Secure-Boot-Update` task is created and registry keys (`UEFICA2023Status`) reflect the update progress.
* **Audit Confirmation:** Log files are generated in `$env:ProgramData\CFGUtil\SecureBoot2023\` with no errors recorded.
* **Idempotency:** Re-running the script on a successful unit results in immediate termination due to the presence of the `.flg`/`.dun` marker.

**Labels:** `secure-boot`, `bios-update`, `dell`, `sccm`, `change-request`

---

### 2. Production Implementation
**Title:** [PROD] Rollout BIOS and Secure Boot 2023 CA Updates to Dell Fleet
**Description:** Execute the phased production rollout of mandatory BIOS updates and the follow-up Secure Boot certificate rotation script. This initiative addresses the 2026 UEFI CA expiration and mitigates the BlackLotus vulnerability.
**Acceptance Criteria:**
* **Ring-Based Rollout:** Deployment follows established production rings (e.g., Pilot -> Broad) with a mandatory 90% compliance threshold before proceeding to the next ring.
* **BIOS Prerequisite:** Script execution is gated to ensure it only runs on devices that have successfully met the minimum BIOS version requirement.
* **Compliance Target:** 95%+ of the targeted Dell fleet reports successful certificate update via SCCM/Intune dashboards.
* **Persistence:** The `.flg` or `.dun` completion marker is present on all successfully updated endpoints to prevent redundant execution cycles.
* **Audit Trail:** Centralized collection or local verification confirms that stage-based logs exist for all production endpoints in the `$env:ProgramData` path.

**Labels:** `secure-boot`, `bios-update`, `dell`, `sccm`, `change-request`

How would you like to handle the reporting for devices that fail the BIOS update prerequisite during the production phase?
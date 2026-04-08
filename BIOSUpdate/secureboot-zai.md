### Implementation Process Outline

*   Sync the **Dell Business Client Update Catalog** within the SCCM Software Update Point.
*   Populate **Dell hardware collections** based on the required BIOS versions/models.
*   Configure and deploy the **BIOS-only Automatic Deployment Rule (ADR)** as mandatory with Windows Update-style deadlines.
*   Package the **PowerShell Secure Boot script** (WinCsFlags.exe logic) for SCCM application/Script deployment.
*   Execute **Pilot/QA deployment**; validate BIOS version increment and script execution logs.
*   Verify **script idempotency** by confirming `.flg`/`.dun` markers prevent re-execution.
*   Initiate **Phase 1 Production rollout** (e.g., Ring 1: 10% of fleet) and monitor SCCM compliance.
*   Review deployment status and logs; proceed to **Phase 2** (remaining fleet) upon meeting compliance gates.
*   Conduct final **audit of logs** in `$env:ProgramData\CFGUtil\SecureBoot2023\` to confirm certificate application.
*   Close change request after achieving >90% compliance and resolving exception cases.

***

### Jira Story Drafts

#### Story 1: QA Validation
**Title:** Validate Dell BIOS ADR and Secure Boot Script in QA Environment

**Description:**
Test the SCCM Automatic Deployment Rule (ADR) for Dell BIOS updates and the subsequent PowerShell script to apply the Windows UEFI CA 2023 certificate. Ensure functionality, logging accuracy, and idempotency within the QA pilot group before production release.

**Acceptance Criteria:**
*   Dell catalog synced successfully; ADR deploys correct BIOS version to pilot units.
*   BIOS update installs successfully, triggering a reboot if required by firmware.
*   PowerShell script executes stages correctly: Scheduled task creation, registry query, and certificate injection via `WinCsFlags.exe`.
*   **Idempotency Verified:** Script creates `.flg`/`.dun` marker files and skips execution on subsequent runs.
*   **Logging Verified:** Logs written to `$env:ProgramData\CFGUtil\SecureBoot2023\` without errors.
*   Test devices confirm UEFI CA 2023 presence in Secure Boot databases.

**Labels:** `secure-boot`, `bios-update`, `dell`, `sccm`, `change-request`

***

#### Story 2: Production Implementation
**Title:** Production Rollout: Dell BIOS and Windows UEFI CA 2023 Update

**Description:**
Execute the phased production deployment of mandatory Dell BIOS updates and the Secure Boot database script via SCCM. Maintain fleet boot integrity and compliance with the 2023 certificate requirement through a monitored, ring-based rollout.

**Acceptance Criteria:**
*   ADR and Script deployed to Production Dell collections aligned with the patching cycle.
*   **Phase 1 Gate:** Compliance >95% in the initial target ring before expanding to the broader fleet.
*   **Script Logic:** Scheduled task executes successfully; `WinCsFlags.exe` applies certificate only if registry keys indicate missing status.
*   **Audit Trail:** Log files confirm successful stage execution on target endpoints.
*   Final compliance report shows >90% of the targeted ~65% inventory successfully updated.
*   Exceptions/failures flagged for manual intervention via DCU or support ticket.

**Labels:** `secure-boot`, `bios-update`, `dell`, `sccm`, `change-request`
## Process Outline

* Build and validate a **BIOS-only Dell ADR** in SCCM using the Dell Business Client Update Catalog and target Dell hardware collections only.
* Confirm deployment settings use **mandatory enforcement** with existing SCCM client notification, deadline, restart, and deferral behavior aligned to the normal patch cycle.
* Scope deployment to a **pilot/ring 0 collection** and verify BIOS applicability, install success, reboot behavior, and post-update device health.
* Review SCCM compliance and failure data; remediate exclusions or known issue models before broader release.
* Promote BIOS deployment through **phased production rings** using defined collection membership and change-control checkpoints.
* After BIOS compliance reaches the required threshold, deploy the **Secure Boot Database Update PowerShell script** to updated Dell devices.
* Script stage 1 registers the scheduled task and creates the working/log path under `$env:ProgramData\CFGUtil\SecureBoot2023\`.
* Script stage 2 checks execution prerequisites and state, including **elevation, UEFI mode, registry values** (`UEFICA2023Status`, etc.), and existing completion markers.
* Script stage 3 applies the Windows UEFI CA 2023 update via **WinCsFlags.exe** only when required, then writes log entries and `.flg`/`.dun` completion markers.
* Validate completion through **SCCM reporting, script logs, registry state, and marker files** to confirm idempotent execution and auditability.

---

## Jira Story Draft 1

**Title:** Validate Dell BIOS ADR and Secure Boot 2023 update workflow in QA

**Description:**
Validate the approved remediation workflow for Windows Secure Boot UEFI CA 2023 certificate readiness on Dell endpoints. Scope includes BIOS delivery through SCCM third-party updates and post-BIOS execution of the Secure Boot database update script, with verification of compliance, logging, and repeat-run behavior.

**Acceptance Criteria:**

* BIOS-only ADR is created in SCCM using the Dell Business Client Update Catalog and limited to QA/pilot Dell collections.
* QA devices identified as requiring BIOS remediation successfully install the targeted BIOS update and reboot without boot integrity issues.
* SCCM deployment behavior reflects mandatory enforcement with expected user notifications, deadlines, and deferral experience.
* Post-BIOS PowerShell script deploys successfully to QA devices and creates the scheduled task as designed.
* Script validates prerequisite conditions, including elevation and UEFI mode, before attempting remediation.
* Script checks registry state (`UEFICA2023Status`, related keys) and applies WinCsFlags.exe only when update is required.
* Script writes logs for each stage under `$env:ProgramData\CFGUtil\SecureBoot2023\`.
* Script creates completion marker file(s) (`.flg`/`.dun`) and skips reprocessing on subsequent runs.
* QA validation confirms idempotent behavior by executing the script more than once on a completed device with no duplicate action taken.
* Evidence is captured for change review, including SCCM compliance results, sample device logs, registry results, and completion markers.

**Labels:**
secure-boot, bios-update, dell, sccm, change-request

---

## Jira Story Draft 2

**Title:** Implement phased production rollout for Dell BIOS remediation and Secure Boot 2023 update

**Description:**
Implement the approved production rollout to address Secure Boot UEFI CA 2023 certificate requirements across Dell endpoints requiring BIOS remediation. Deployment will use SCCM phased targeting for BIOS updates followed by the Secure Boot database update script, with compliance gates, logging validation, and audit evidence captured for change management.

**Acceptance Criteria:**

* Production BIOS ADR is enabled for Dell hardware collections and scoped using defined rollout rings.
* Rollout begins only after QA validation is completed and approved through change control.
* BIOS deployment progresses through production rings using documented gate reviews between phases.
* Each production ring meets the defined compliance threshold before promotion to the next ring.
* Devices receiving the BIOS update remain healthy post-restart with no increase in boot-related incidents attributable to the change.
* Secure Boot database update script is deployed only to devices in scope for post-BIOS remediation.
* Script confirms existing completion markers and skips already-remediated systems, demonstrating idempotent behavior in production.
* Script logs are written to `$env:ProgramData\CFGUtil\SecureBoot2023\` and are available for operational review/audit.
* Audit evidence includes SCCM compliance reporting, deployment status by ring, sample log output, registry confirmation, and marker-file confirmation.
* Final implementation is considered complete when targeted production rings reach the approved compliance threshold and exceptions/failures are documented for follow-up.

**Labels:**
secure-boot, bios-update, dell, sccm, change-request

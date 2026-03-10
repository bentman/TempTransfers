# Dell BIOS Updates via SCCM + DCU-WU

## Recommended approach

Use an **SCCM Application** to trigger **Dell Command | Update for Windows Universal (DCU-WU)** for **BIOS-only** updates.

Why this is the primary recommendation:
- SCCM remains the **orchestration layer**.
- DCU-WU remains the **execution engine**.
- The **Application model** supports detection, requirements, return codes, and controlled reboot behavior.
- SCCM / Software Center can provide the user notification and restart experience.

References:
- [Microsoft Learn - Create applications in Configuration Manager](https://learn.microsoft.com/en-us/intune/configmgr/apps/deploy-use/create-applications)
- [Dell - Dell Command | Update](https://www.dell.com/support/kbdoc/en-us/000177325/dell-command-update)

---

## Options eliminated

- **ADR / third-party updates**: not selected because SCCM ADR is not the chosen model for this workflow.
- **Task Sequence as the primary method**: not selected because it adds unnecessary complexity for recurring BIOS servicing.
- **Package/Program as the primary method**: not selected because it lacks the Application model’s native detection and return code handling.
- **DCU automatic scheduling**: not selected because SCCM is responsible for initiating the workflow.

References:
- [Microsoft Learn - Create applications in Configuration Manager](https://learn.microsoft.com/en-us/intune/configmgr/apps/deploy-use/create-applications)
- [Dell Command | Update CLI reference (current product docs entry)](https://www.dell.com/support/home/en-us/product-support/product/command-update/docs)

---

## High-level process

### 1) Deployment
- Create a dedicated **SCCM Application** for Dell BIOS updates.
- Use a **Script Installer** deployment type that calls `dcu-cli.exe`.
- Deploy through **Software Center**.

References:
- [Microsoft Learn - Supported deployment types and application model](https://learn.microsoft.com/en-us/intune/configmgr/apps/deploy-use/create-applications)

### 2) Configuration
- Keep DCU in **manual** mode for this workflow.
- Limit the run to **BIOS** updates only.
- Enable **BitLocker auto-suspend** through DCU.
- Use `-reboot=disable` so the wrapper can return control to **SCCM** for restart handling.
- Keep user-facing notification responsibility with **SCCM**, not DCU.

Implementation note:
- Treat SCCM reboot ownership as the **required operating model** and validate it in pilot, because BIOS update behavior can vary by model/DCU version/update package.

Example DCU settings/command intent:
- BIOS only
- BitLocker auto-suspend enabled
- reboot disabled

References:
- [Dell - Dell Command | Update docs landing page](https://www.dell.com/support/home/en-us/product-support/product/command-update/docs)
- [Dell - BIOS update guidance](https://www.dell.com/support/kbdoc/en-us/000124211/dell-bios-updates)

### 3) Detection
- Use an **Application detection method** to confirm the BIOS state after execution.
- Preferred detection: validate the target **BIOS version/date**.
- If you use a DCU scan/report design, detection can instead validate whether a BIOS update is still applicable.

References:
- [Microsoft Learn - Detection methods for deployment types](https://learn.microsoft.com/en-us/intune/configmgr/apps/deploy-use/create-applications#deployment-type-detection-method-options)

### 4) Remediation
- SCCM starts the DCU-WU BIOS update command.
- DCU evaluates and applies the BIOS update.
- SCCM re-runs detection after execution.
- Configure DCU return codes in the deployment type so SCCM correctly interprets success and reboot-required outcomes.

Recommended handling in wrapper logic:
- Run `/scan` first and short-circuit on known no-update results.
- If a reboot is already pending, return **3010** to SCCM so restart UX stays in SCCM.

References:
- [Microsoft Learn - Return codes for deployment types](https://learn.microsoft.com/en-us/intune/configmgr/apps/deploy-use/create-applications#deployment-type-return-codes)
- [Dell Command | Update docs landing page](https://www.dell.com/support/home/en-us/product-support/product/command-update/docs)

### 5) User notifications
- Use **Software Center / SCCM notifications** as the primary user-facing channel.
- Keep the message simple:
  - a BIOS update is ready or required
  - a restart will be required
  - restart timing is controlled by SCCM

References:
- [Microsoft Learn - Software Center user guide](https://learn.microsoft.com/en-us/intune/configmgr/core/understand/software-center)
- [Microsoft Learn - Device restart notifications](https://learn.microsoft.com/en-us/intune/configmgr/core/clients/deploy/device-restart-notifications)

### 6) Reboot handling
- Do **not** let DCU own the end-user reboot experience.
- Let **SCCM** manage:
  - reminder timing
  - snooze behavior
  - final countdown
- BIOS install completes during the restart sequence.

References:
- [Microsoft Learn - Device restart notifications](https://learn.microsoft.com/en-us/intune/configmgr/core/clients/deploy/device-restart-notifications)
- [Dell - BIOS update guidance](https://www.dell.com/support/kbdoc/en-us/000124211/dell-bios-updates)

---

## Minimal deployment outline

1. Create an **SCCM Application** for Dell BIOS updates.
2. Use DCU-WU CLI in **BIOS-only** mode.
3. Enable **BitLocker auto-suspend**.
4. Suppress immediate DCU reboot.
5. Use an SCCM **detection method** to validate BIOS state.
6. Map DCU return codes in the deployment type.
7. Deploy through **Software Center**.
8. Let **SCCM** handle notifications and restart timing.

---

## DCU return codes and SCCM mapping (validated)

From current Dell DCU 5.x CLI docs, key **documented** generic return codes include:

- `0` = command execution successful
- `1` = reboot required
- `5` = reboot pending from previous operation

Also commonly used in ConfigMgr Application deployments:

- `3010` = **Soft Reboot** in SCCM deployment type return codes (ConfigMgr behavior)

Important nuance on `3010`:
- `3010` is not listed as a primary DCU generic CLI code in the current Dell 5.x error table.
- It can still appear in enterprise deployment workflows (for example, from wrapped installers/update engines), so treating `3010` as reboot-required in SCCM wrapper logic is operationally valid.

Suggested SCCM deployment type mappings:
- `0` => Success (no reboot)
- `500` => Success (no reboot / no updates found)
- `1` => Soft Reboot
- `5` => Soft Reboot
- `3010` => Soft Reboot

References:
- [Dell Command | Update 5.x - Command Line Interface Error codes](https://www.dell.com/support/manuals/en-ca/command-update/dcu_rg/command-line-interface-error-codes?guid=guid-fbb96b06-4603-423a-baec-cbf5963d8948&lang=en-us)
- [Microsoft Learn - Create applications in Configuration Manager (Return Codes)](https://learn.microsoft.com/en-us/intune/configmgr/apps/deploy-use/create-applications#deployment-type-return-codes)

---

## Script usage

Use `Invoke-DellBiosUpdate.ps1` as the SCCM-triggered wrapper for DCU-WU.

### What the script does
- confirms DCU is installed
- checks AC power / battery state
- handles AC-present battery states recognized by `Win32_Battery` (not only a single status code)
- relies on DCU `-autoSuspendBitLocker=enable` for BitLocker handling
- runs DCU in **BIOS-only** mode
- runs DCU `/scan` first and exits cleanly when no BIOS updates are applicable
- suppresses immediate DCU reboot
- returns **3010** to SCCM when reboot handling is required
- does **not** provide end-user toast notifications; SCCM / Software Center owns user messaging

### Log and result path
- `C:\ProgramData\CFG_Utils\Update-DellBIOS`

Files written there:
- `Invoke-DellBiosUpdate.log`
- `Invoke-DellBiosUpdate.transcript.log`
- `dcu_scan.log`
- `dcu_apply.log`
- `result.json`

### Example SCCM install command

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Invoke-DellBiosUpdate.ps1
```

### Basic SCCM instruction
- Create an **Application** with a **Script Installer** deployment type.
- Use the script above as the install command.
- Configure **3010** as **Soft Reboot** in the deployment type.
- Use your normal SCCM detection method for BIOS state.
- Let SCCM manage user notifications and reboot timing.
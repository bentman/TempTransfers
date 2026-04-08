# Dell BIOS Updates via SCCM + DCU-WU (Service-Driven / Native Toast)

## What this is

An alternative SCCM deployment model that uses DCU-WU's service-driven update
cycle to deliver native Windows toast notifications to the logged-on user, rather
than SCCM / Software Center owning all user messaging.

SCCM runs the wrapper script as SYSTEM. The script configures DCU for toast-enabled
BIOS-only updates, then triggers an immediate scan. DellClientManagementService picks
up the scan result and delivers the download, install, and reboot toast to the active
user session. SCCM detection and deadline enforcement remain unchanged.

---

## How DCU toast notifications actually work

Toast notifications in DCU-WU are NOT produced by `dcu-cli.exe /applyUpdates`.
They are delivered by **DellClientManagementService** to the active user session when:
- `-updatesNotification=enable` is configured
- `-scheduleAction=DownloadInstallAndNotify` is configured
- The service detects an applicable update on its next cycle after a scan

Running `dcu-cli.exe /applyUpdates` without `-silent` only affects console output
visibility. It does not engage the UWP toast layer regardless of run context.
The scheduled task bridge approach (running the script as the user) does not change
this — the toast layer is owned by the service, not the CLI process.

This is confirmed by Dell's 5.x CLI Reference Guide (`-updatesNotification` and
`-scheduleAction` are `/configure` flags, not `/applyUpdates` flags) and by the
Dell 5.x User Guide (CLI is documented as an automated deployment path without
interactive user prompts or GUI features).

---

## DCU 5.6 known issue

DCU 5.6 requires at least one prior user logon before `dcu-cli.exe` is functional.
Running it in a pure SYSTEM/OOBE context before first logon fails with an OOBE state
error. This does not affect normal SCCM Application deployments where the logon
requirement is set to "Only when a user is logged on."

---

## What the user sees

1. After the scan triggers, DellClientManagementService processes the BIOS update
   in the background within minutes.
2. A DCU toast notification appears: "Updates are available" or "Updates have been
   installed — restart required."
3. A persistent reboot toast appears in the system tray with a "Restart Now" button.
   The user can defer per the configured deferral settings.
4. After all deferrals are exhausted, DCU forces the restart automatically.
5. SCCM reboot policy fires as the enforcement backstop if the user defers past the
   SCCM deployment deadline.

If no user is logged on when the service cycle fires, the update installs silently
without a toast. The reboot toast appears at next logon if a restart is still pending.

---

## Key differences from Invoke-DellBiosUpdate.ps1

| Behavior                    | Invoke-DellBiosUpdate.ps1         | Invoke-DellBiosUpdateUser.ps1           |
|-----------------------------|-----------------------------------|-----------------------------------------|
| Execution context           | SYSTEM (SCCM direct)              | SYSTEM (SCCM direct)                    |
| Update execution            | dcu-cli.exe /applyUpdates         | DellClientManagementService (async)     |
| Toast notifications         | None                              | Native DCU toasts via service           |
| Reboot UX                   | SCCM owns entirely                | DCU toast first, SCCM backstop          |
| SCCM return code            | Maps DCU apply exit code          | Always 0 (scan triggered) or 3010      |
| BIOS update timing          | Synchronous during SCCM install   | Asynchronous after SCCM install step   |
| SCCM detection timing       | Immediately after install step    | After user reboots and BIOS flashes     |
| Log folder                  | Update-DellBIOS                   | Update-DellBIOS-User                   |

---

## Log and result path

`C:\ProgramData\CFG_Utils\Update-DellBIOS-User`

Files written:
- `Invoke-DellBiosUpdateUser.log`
- `Invoke-DellBiosUpdateUser.transcript.log`
- `dcu_configure.log`
- `dcu_scan.log`
- `result.json`

---

## DCU return codes and SCCM mapping

This script returns these codes to SCCM:

- `0`    = Scan triggered (no update found) or scan triggered (service will proceed)
- `3010` = Reboot pending from a previous operation; SCCM handles restart
- `1`    = Script-level failure (DCU not found, power check failed, service unavailable)

The BIOS apply operation runs inside DellClientManagementService asynchronously.
Its exit codes are not returned to SCCM. BIOS version detection confirms completion.

---

## SCCM implementation

### Step 1 — Prepare package source

Place `Invoke-DellBiosUpdateUser.ps1` in your SCCM package source folder.

---

### Step 2 — SCCM Application

**Software Library > Application Management > Applications > Create Application**

- Name: `Dell BIOS Update - DCU Native Toast`
- Manually specify application information

---

### Step 3 — Deployment Type

**Application > Deployment Types > Add > Script Installer**

General:
- Name: `Script Installer - Native Toast`

Content:
- Content location: `<your package source UNC path>`

Programs:
- Installation program:
  ```
  powershell.exe -ExecutionPolicy Bypass -File .\Invoke-DellBiosUpdateUser.ps1
  ```
- Uninstall program: (none)

Detection Method:
- Use WMI (`Win32_BIOS.SMBIOSBIOSVersion`) or a script to compare the current BIOS
  version against the target version.
- Do not use `result.json` presence as the detection method. The script exits before
  the service completes the BIOS update. Only BIOS version confirms the target state.

User Experience:
- Install behavior: `Install for system`
- Logon requirement: `Only when a user is logged on`
- Installation program visibility: `Hidden`
- Allow users to interact: `No`
- Maximum allowed run time: `30 minutes`
- Estimated installation time: `5 minutes`

Return Codes:
- `0`    = Success
- `3010` = Soft Reboot (add manually)

Requirements: (optional, recommended)
- Add a requirement rule for `Dell` manufacturer via WMI or global condition.

---

### Step 4 — Deployment

**Application > Deploy**

- Collection: Dell endpoints collection
- Purpose: `Required`
- Software Center notifications: `Display in Software Center and show all notifications`
- Schedule: set available date and deadline per your change window
- User Experience:
  - `Display user notifications for software installations`: Yes
  - Deadline behavior: `Automatically install...`
  - Device restart behavior: `ConfigMgr determines restart behavior`
- Reboot suppression: Do **not** suppress restart — SCCM reboot is the enforcement backstop.

---

## Reboot ownership

DCU owns the reboot toast UX. The user sees a Dell notification prompting restart,
with deferral options per the configured deferral settings. After all deferrals are
exhausted DCU forces the restart. If the user does not restart before the SCCM
deadline grace period expires, SCCM issues its standard restart countdown as the
enforcement backstop.

---

## Detection timing note

Because the BIOS update runs asynchronously inside DellClientManagementService after
this script exits, SCCM's post-install detection will not confirm success until the
user has rebooted and the BIOS has flashed. The deployment will show as "In Progress"
or "Pending Restart" in SCCM until detection succeeds. This is expected behavior for
this workflow and not a deployment failure.

---

## Caveats

- If DellClientManagementService is stopped or disabled, toast notifications will not
  be delivered. The script checks service state and fails fast if the service is
  unavailable.
- If no user is logged on when the service processes the update, the install proceeds
  silently without toast. The `Logon requirement: Only when a user is logged on`
  setting mitigates this for the SCCM trigger, but not for service cycles that fire
  later.
- Deferral settings configured by this script are persistent in DCU. If you need to
  change them after deployment, re-run the script or push a new `/configure` operation.
- This workflow has been validated against DCU-WU v5.6.0.

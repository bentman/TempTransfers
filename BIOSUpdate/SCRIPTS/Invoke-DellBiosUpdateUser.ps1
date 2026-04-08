<#
.SYNOPSIS
    Configures DCU-WU for service-driven BIOS updates with native toast notifications,
    then triggers an immediate one-time scan via DellClientManagementService.

.DESCRIPTION
    SCCM-triggered configuration wrapper for Dell Command | Update service-driven BIOS updates.
    Key behaviors:
      - Runs as SYSTEM via SCCM Application deployment type.
      - Resolves DCU path in both x64 and x86 install locations.
      - Enforces AC power + battery threshold checks (laptops).
      - Configures DCU for BIOS-only updates with user toast notifications enabled.
      - Configures DCU schedule to manual so SCCM controls when the service fires.
      - Configures system restart and installation deferral to allow user toast interaction.
      - Triggers an immediate DCU scan via dcu-cli.exe; DellClientManagementService
        then handles download, install, and toast notification delivery to the user session.
      - Uses DCU built-in BitLocker handling for BIOS updates.
      - Writes logs and result output for SCCM troubleshooting.

    Toast notification behavior:
      - Toast notifications in DCU-WU are delivered by DellClientManagementService to the
        active user session. They are NOT produced by dcu-cli.exe applyUpdates directly.
      - The -updatesNotification=enable and -scheduleAction=DownloadInstallAndNotify
        /configure flags control whether the service surfaces toasts when updates are found.
      - This script configures those flags and triggers a one-time scan so the service
        picks up the BIOS update and delivers the toast on its next service cycle.
      - If no user is logged on at the time the service delivers the toast, the update
        will install silently on the next service cycle without user interaction.

    Notes:
      - This script runs as SYSTEM via SCCM. The toast is delivered by the service,
        not by this script or dcu-cli.exe directly.
      - SCCM / Software Center remains the enforcement and deadline layer.
      - SCCM reboot policy serves as the backstop if the user defers past the deadline.
      - DCU 5.6 requires at least one prior user logon before dcu-cli.exe is functional.
        This is a Dell 5.6 regression. SCCM's "Only when a user is logged on" logon
        requirement on the deployment type mitigates this in normal operation.

.PARAMETER MinBatteryPercent
    Minimum battery percentage required when a battery is present.

.PARAMETER DeferralRestartHours
    Hours the user can defer a DCU restart toast before DCU forces the restart.
    Valid range: 1-99. Default: 4.

.PARAMETER DeferralRestartCount
    Number of times the user can defer the DCU restart toast.
    Valid range: 1-9. Default: 3.

.PARAMETER LogLevel
    Sets logging verbosity: 'INFO', 'DEBUG', 'WARN', 'ERROR'. Default is 'INFO'.

.NOTES
    Preferred log and result root: C:\ProgramData\CFG_Utils\Update-DellBIOS-User
    Fallback log and result root:  %TEMP%\CFG_Utils\Update-DellBIOS-User (if ProgramData is not writable)
    Aligned to SCCM-triggered DCU-WU service-driven BIOS update workflow with native toast.

    DCU CLI reference:
      https://www.dell.com/support/manuals/en-us/command-update/dcu_rg/dell-command-update-cli-commands
    DCU CLI error codes:
      https://www.dell.com/support/manuals/en-ca/command-update/dcu_rg/command-line-interface-error-codes
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100)]
    [int]$MinBatteryPercent = 30,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 99)]
    [int]$DeferralRestartHours = 4,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 9)]
    [int]$DeferralRestartCount = 3,

    [Parameter(Mandatory = $false)]
    [ValidateSet('INFO', 'DEBUG', 'WARN', 'ERROR')]
    [string]$LogLevel = 'INFO'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 1. Configuration
# ---------------------------------------------------------------------------
$DcuCandidates = @(
    "${env:ProgramW6432}\Dell\CommandUpdate\dcu-cli.exe",
    "${env:ProgramFiles}\Dell\CommandUpdate\dcu-cli.exe",
    "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe"
)

$DellLogRoot     = $null
$ScriptLogPath   = $null
$TranscriptPath  = $null
$DcuScanLogPath  = $null
$ResultPath      = $null

# ---------------------------------------------------------------------------
# 2. Helper Functions
# ---------------------------------------------------------------------------
function Initialize-Logging {
    param([string]$LogLevel)

    $preferredRoot = Join-Path $env:ProgramData 'CFG_Utils\Update-DellBIOS-User'
    $fallbackRoot  = Join-Path $env:TEMP 'CFG_Utils\Update-DellBIOS-User'

    try {
        if (-not (Test-Path -LiteralPath $preferredRoot)) {
            New-Item -Path $preferredRoot -ItemType Directory -Force | Out-Null
        }
        $script:DellLogRoot = $preferredRoot
    }
    catch {
        if (-not (Test-Path -LiteralPath $fallbackRoot)) {
            New-Item -Path $fallbackRoot -ItemType Directory -Force | Out-Null
        }
        $script:DellLogRoot = $fallbackRoot
    }

    $script:ScriptLogPath  = Join-Path $script:DellLogRoot 'Invoke-DellBiosUpdateUser.log'
    $script:TranscriptPath = Join-Path $script:DellLogRoot 'Invoke-DellBiosUpdateUser.transcript.log'
    $script:DcuScanLogPath = Join-Path $script:DellLogRoot 'dcu_scan.log'
    $script:ResultPath     = Join-Path $script:DellLogRoot 'result.json'

    if (-not (Test-Path -LiteralPath $script:ScriptLogPath)) {
        New-Item -Path $script:ScriptLogPath -ItemType File -Force | Out-Null
    }

    $script:LogLevel = $LogLevel.ToUpper()
}

function Write-Result {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][int]$ExitCode,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $false)][Nullable[int]]$DcuExitCode = $null
    )

    $result = [ordered]@{
        Timestamp   = (Get-Date).ToString('s')
        Status      = $Status
        ExitCode    = $ExitCode
        DcuExitCode = $DcuExitCode
        Message     = $Message
        LogRoot     = $script:DellLogRoot
        ScriptLog   = $script:ScriptLogPath
        ScanLog     = $script:DcuScanLogPath
    }

    $result | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $script:ResultPath -Encoding UTF8
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $false)][ValidateSet('INFO', 'DEBUG', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry  = "[$timestamp] [$Level] $Message"

    if ($script:LogLevel -eq 'DEBUG' -or $Level -eq 'ERROR' -or $Level -eq 'WARN') {
        Write-Host $logEntry -ForegroundColor $(Get-LogLevelColor $Level)
    }

    Add-Content -LiteralPath $script:ScriptLogPath -Value $logEntry
}

function Get-LogLevelColor {
    param([string]$Level)
    switch ($Level) {
        'INFO'  { return 'White' }
        'DEBUG' { return 'Gray' }
        'WARN'  { return 'Yellow' }
        'ERROR' { return 'Red' }
    }
}

function Resolve-DcuPath {
    foreach ($candidate in $DcuCandidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    return $null
}

function Test-RunningAsAdmin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-DellClientManagementService {
    $svc = Get-Service -Name 'DellClientManagementService' -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log -Level 'ERROR' -Message 'DellClientManagementService not found. Toast notifications will not be delivered.'
        return $false
    }
    if ($svc.Status -ne 'Running') {
        Write-Log -Level 'WARN' -Message "DellClientManagementService is not running (status: $($svc.Status)). Attempting to start."
        try {
            Start-Service -Name 'DellClientManagementService' -ErrorAction Stop
            Write-Log -Message 'DellClientManagementService started.'
        }
        catch {
            Write-Log -Level 'ERROR' -Message "Failed to start DellClientManagementService: $_"
            return $false
        }
    }
    else {
        Write-Log -Message 'DellClientManagementService is running.'
    }
    return $true
}

function Test-PowerStatus {
    param(
        [Parameter(Mandatory = $true)][int]$MinimumBatteryPercent
    )

    $batteries = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
    if (-not $batteries) {
        Write-Log -Message 'No battery detected (desktop or unavailable telemetry). Skipping battery checks.'
        return $true
    }

    # Win32_Battery BatteryStatus AC-present states:
    # 2 (Unknown/AC present), 3 (Fully Charged), 6 (Charging), 7 (Charging/High),
    # 8 (Charging/Low), 9 (Charging/Critical)
    $acAcceptableStatuses = @(2, 3, 6, 7, 8, 9)

    foreach ($battery in @($batteries)) {
        $status = [int]$battery.BatteryStatus
        $charge = [int]$battery.EstimatedChargeRemaining
        Write-Log -Message "Battery status=$status, charge=$charge%."

        if ($status -notin $acAcceptableStatuses) {
            Write-Log -Level 'WARN' -Message 'Device is not on AC power. BIOS update blocked.'
            return $false
        }

        if ($charge -lt $MinimumBatteryPercent) {
            Write-Log -Level 'WARN' -Message "Battery charge $charge% is below threshold $MinimumBatteryPercent%. BIOS update blocked."
            return $false
        }
    }

    return $true
}

function Start-DcuProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $argString = ($Arguments -join ' ')
    Write-Log -Message "Executing: $FilePath $argString"

    $process = Start-Process -FilePath $FilePath -ArgumentList $argString -NoNewWindow -Wait -PassThru
    return $process.ExitCode
}

# ---------------------------------------------------------------------------
# 3. Validate Parameters and Context
# ---------------------------------------------------------------------------
Initialize-Logging -LogLevel $LogLevel

try {
    Start-Transcript -Path $TranscriptPath -Force | Out-Null
}
catch {
    Write-Log -Level 'WARN' -Message 'Unable to start transcript. Continuing with file logging only.'
}

Write-Log -Message '=== Starting Invoke-DellBiosUpdateUser ==='
Write-Log -Message "Log root: $DellLogRoot"
Write-Log -Message 'Deployment context: SCCM (SYSTEM) - service-driven toast workflow'
Write-Log -Message "Log level: $LogLevel"
Write-Log -Message "Deferral settings: restart=${DeferralRestartHours}h x${DeferralRestartCount}"

if (-not (Test-RunningAsAdmin)) {
    Write-Log -Level 'ERROR' -Message 'Script must run elevated (Administrator/SYSTEM).'
    Write-Result -Status 'Failed' -ExitCode 1 -Message 'Script must run elevated (Administrator/SYSTEM).'
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

$DcuPath = Resolve-DcuPath
if (-not $DcuPath) {
    Write-Log -Level 'ERROR' -Message 'Dell Command | Update CLI (dcu-cli.exe) not found in standard install locations.'
    Write-Result -Status 'Failed' -ExitCode 1 -Message 'Dell Command | Update CLI (dcu-cli.exe) not found.'
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}
Write-Log -Message "Resolved DCU path: $DcuPath"

if (-not (Test-DellClientManagementService)) {
    Write-Result -Status 'Failed' -ExitCode 1 -Message 'DellClientManagementService not available. Toast notifications cannot be delivered.'
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

if (-not (Test-PowerStatus -MinimumBatteryPercent $MinBatteryPercent)) {
    Write-Log -Level 'ERROR' -Message 'Power prerequisites not met. Exiting without update.'
    Write-Result -Status 'Blocked' -ExitCode 1 -Message 'Power prerequisites not met. Exiting without update.'
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

# ---------------------------------------------------------------------------
# 4. Configure DCU for Service-Driven Toast Workflow
# ---------------------------------------------------------------------------
# -scheduleManual: disables DCU automatic schedule; SCCM controls when this runs.
# -updateType=bios: scope to BIOS only.
# -autoSuspendBitLocker=enable: DCU suspends BitLocker before flash; re-enables after reboot.
# -updatesNotification=enable: allows DellClientManagementService to deliver toast
#   notifications to the active user session when updates are found or installed.
# -scheduleAction=DownloadInstallAndNotify: service downloads, installs, then notifies
#   the user via toast. User sees a reboot toast; can defer per deferral settings.
# -systemRestartDeferral / -deferralRestartInterval / -deferralRestartCount:
#   controls how many times and how long the user can defer the DCU reboot toast.
#   After all deferrals are exhausted DCU will force the restart automatically.

$configArgs = @(
    '/configure',
    '-scheduleManual',
    '-updateType=bios',
    '-autoSuspendBitLocker=enable',
    '-updatesNotification=enable',
    '-scheduleAction=DownloadInstallAndNotify',
    '-systemRestartDeferral=enable',
    "-deferralRestartInterval=$DeferralRestartHours",
    "-deferralRestartCount=$DeferralRestartCount",
    '-silent',
    "-outputLog=$($script:DellLogRoot)\dcu_configure.log"
)

$configExitCode = Start-DcuProcess -FilePath $DcuPath -Arguments $configArgs
Write-Log -Message "DCU configure exit code: $configExitCode"

# /configure can return non-zero even on partial success in some DCU versions.
# Log it but treat any non-fatal code as a warning, not a hard failure.
if ($configExitCode -notin @(0, 1, 5)) {
    Write-Log -Level 'WARN' -Message "DCU configure returned code $configExitCode. Continuing to scan phase."
}

# ---------------------------------------------------------------------------
# 5. Trigger Scan
# ---------------------------------------------------------------------------
# /scan with -silent suppresses console output but does not suppress the service.
# DellClientManagementService picks up the scan result and delivers the toast
# notification and download/install cycle to the active user session.
# This script returns 0 to SCCM immediately after triggering the scan.
# The actual BIOS update and reboot toast are delivered asynchronously by the service.

$scanArgs = @(
    '/scan',
    '-updateType=bios',
    '-silent',
    "-outputLog=$DcuScanLogPath"
)

$scanExitCode = Start-DcuProcess -FilePath $DcuPath -Arguments $scanArgs
Write-Log -Message "DCU scan exit code: $scanExitCode"

$scanNoUpdateCodes       = @(500)
$scanRebootPendingCodes  = @(1, 5)
$scanSuccessCodes        = @(0)

if ($scanExitCode -in $scanNoUpdateCodes) {
    Write-Log -Message 'Scan result: no applicable BIOS updates.'
    Write-Result -Status 'Success' -ExitCode 0 -Message 'No applicable BIOS updates found during scan.'
    try { Stop-Transcript | Out-Null } catch {}
    exit 0
}

if ($scanExitCode -in $scanRebootPendingCodes) {
    Write-Log -Level 'WARN' -Message "Scan indicates reboot is required before continuing (code: $scanExitCode)."
    Write-Result -Status 'RebootRequired' -ExitCode 3010 -Message 'Pending reboot detected by DCU scan. Returning 3010 for SCCM handling.'
    try { Stop-Transcript | Out-Null } catch {}
    exit 3010
}

if ($scanExitCode -notin $scanSuccessCodes) {
    Write-Log -Level 'ERROR' -Message "DCU scan failed with non-success code: $scanExitCode"
    Write-Result -Status 'Failed' -ExitCode 1 -Message "DCU scan failed with code: $scanExitCode" -DcuExitCode $scanExitCode
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

# ---------------------------------------------------------------------------
# 6. Exit — Service takes over from here
# ---------------------------------------------------------------------------
# Scan returned 0: BIOS update is available. DellClientManagementService will
# proceed with download and install on its next cycle (typically within minutes)
# and deliver the toast to the active user session.
# This script returns 0 to SCCM. SCCM detection method (BIOS version) will confirm
# completion after the user reboots and the BIOS flashes.

Write-Log -Message 'Scan triggered successfully. DellClientManagementService will deliver the update and toast notification.'
Write-Result -Status 'ScanTriggered' -ExitCode 0 -Message 'BIOS update scan triggered. Service will deliver update and toast notification to user session.'
try { Stop-Transcript | Out-Null } catch {}
exit 0

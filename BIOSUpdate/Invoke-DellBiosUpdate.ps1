<#
.SYNOPSIS
    Executes Dell BIOS updates safely by using Dell Command | Update CLI for SCCM application deployments.

.DESCRIPTION
    Production-oriented BIOS update wrapper for SCCM-managed Dell BIOS update deployments.
    Key behaviors:
      - Resolves DCU path in both x64 and x86 install locations.
      - Enforces AC power + battery threshold checks (laptops).
      - Uses BIOS-only scope for scan/apply operations.
      - Uses Dell CLI style consistently: /command -option=value.
      - Uses DCU built-in BitLocker handling for BIOS updates.
      - Handles known DCU exit states and controlled reboot behavior.
      - Writes logs and result output for SCCM troubleshooting.

    Notes:
      - SCCM / Software Center is expected to own all reboot UX.

.PARAMETER MinBatteryPercent
    Minimum battery percentage required when a battery is present.

.PARAMETER LogLevel
    Sets logging verbosity: 'INFO', 'DEBUG', 'WARN', 'ERROR'. Default is 'INFO'.

.NOTES
    Preferred log and result root: C:\ProgramData\CFG_Utils\Update-DellBIOS
    Fallback log and result root:  %TEMP%\CFG_Utils\Update-DellBIOS (if ProgramData is not writable)
    Aligned to SCCM-triggered DCU-WU BIOS update workflow.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100)]
    [int]$MinBatteryPercent = 30,

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

$DellLogRoot = $null
$ScriptLogPath = $null
$TranscriptPath = $null
$DcuScanLogPath = $null
$DcuApplyLogPath = $null
$ResultPath = $null

# ---------------------------------------------------------------------------
# 2. Helper Functions
# ---------------------------------------------------------------------------
function Initialize-Logging {
    param([string]$LogLevel)

    $preferredRoot = Join-Path $env:ProgramData 'CFG_Utils\Update-DellBIOS'
    $fallbackRoot = Join-Path $env:TEMP 'CFG_Utils\Update-DellBIOS'

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

    $script:ScriptLogPath = Join-Path $script:DellLogRoot 'Invoke-DellBiosUpdate.log'
    $script:TranscriptPath = Join-Path $script:DellLogRoot 'Invoke-DellBiosUpdate.transcript.log'
    $script:DcuScanLogPath = Join-Path $script:DellLogRoot 'dcu_scan.log'
    $script:DcuApplyLogPath = Join-Path $script:DellLogRoot 'dcu_apply.log'
    $script:ResultPath = Join-Path $script:DellLogRoot 'result.json'

    if (-not (Test-Path -LiteralPath $script:ScriptLogPath)) {
        New-Item -Path $script:ScriptLogPath -ItemType File -Force | Out-Null
    }

    # Set logging level
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
        Timestamp = (Get-Date).ToString('s')
        Status    = $Status
        ExitCode  = $ExitCode
        DcuExitCode = $DcuExitCode
        Message   = $Message
        LogRoot   = $script:DellLogRoot
        ScriptLog = $script:ScriptLogPath
        ScanLog   = $script:DcuScanLogPath
        ApplyLog  = $script:DcuApplyLogPath
    }

    $result | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $script:ResultPath -Encoding UTF8
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $false)][ValidateSet('INFO', 'DEBUG', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "[$timestamp] [$Level] $Message"

    # Write to console if DEBUG level
    if ($script:LogLevel -eq 'DEBUG' -or $Level -eq 'ERROR' -or $Level -eq 'WARN') {
        Write-Host $logEntry -ForegroundColor $(GetLogLevelColor $Level)
    }

    # Always write to log file
    Add-Content -LiteralPath $script:ScriptLogPath -Value $logEntry
}

function GetLogLevelColor {
    param([string]$Level)
    switch ($Level) {
        'INFO' { return 'White' }
        'DEBUG' { return 'Gray' }
        'WARN' { return 'Yellow' }
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
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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

    $acAcceptableStatuses = @(2, 3, 6, 7, 8, 9)

    foreach ($battery in @($batteries)) {
        $status = [int]$battery.BatteryStatus
        $charge = [int]$battery.EstimatedChargeRemaining
        Write-Log -Message "Battery status=$status, charge=$charge%."

        # Win32_Battery AC-present states include:
        # 2 (Unknown/AC present), 3 (Fully Charged), 6/7/8/9 (Charging states)
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

Write-Log -Message '=== Starting Invoke-DellBiosUpdate ==='
Write-Log -Message "Log root: $DellLogRoot"
Write-Log -Message 'Deployment context: SCCM'
Write-Log -Message "Log level: $LogLevel"

if (-not (Test-RunningAsAdmin)) {
    Write-Log -Level 'ERROR' -Message 'Script must run elevated (Administrator/SYSTEM).'
    Write-Result -Status 'Failed' -ExitCode 1 -Message 'Script must run elevated (Administrator/SYSTEM).'
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

$DcuPath = Resolve-DcuPath
if (-not $DcuPath) {
    Write-Log -Level 'ERROR' -Message 'Dell Command | Update CLI (dcu-cli.exe) not found in standard install locations.'
    Write-Result -Status 'Failed' -ExitCode 1 -Message 'Dell Command | Update CLI (dcu-cli.exe) not found in standard install locations.'
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}
Write-Log -Message "Resolved DCU path: $DcuPath"

if (-not (Test-PowerStatus -MinimumBatteryPercent $MinBatteryPercent)) {
    Write-Log -Level 'ERROR' -Message 'Power prerequisites not met. Exiting without update.'
    Write-Result -Status 'Blocked' -ExitCode 1 -Message 'Power prerequisites not met. Exiting without update.'
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

# ---------------------------------------------------------------------------
# 4. Execute BIOS Update Flow with Context-Specific Logic
# ---------------------------------------------------------------------------
$scanArgs = @(
    '/scan',
    '-updateType=bios',
    '-silent',
    "-outputLog=$DcuScanLogPath"
)

$scanExitCode = Start-DcuProcess -FilePath $DcuPath -Arguments $scanArgs
Write-Log -Message "DCU scan exit code: $scanExitCode"

$scanSuccessCodes = @(0)
$scanNoUpdateCodes = @(500)
$scanRebootRequiredCodes = @(1, 5, 3010)

if ($scanExitCode -in $scanNoUpdateCodes) {
    Write-Log -Message 'Scan result: no applicable BIOS updates.'
    Write-Result -Status 'Success' -ExitCode 0 -Message 'No applicable BIOS updates found during scan.'
    try { Stop-Transcript | Out-Null } catch {}
    exit 0
}

if ($scanExitCode -in $scanRebootRequiredCodes) {
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

$applyArgs = @(
    '/applyUpdates',
    '-updateType=bios',
    '-silent',
    '-reboot=disable',
    '-autoSuspendBitLocker=enable',
    "-outputLog=$DcuApplyLogPath"
)

$applyExitCode = Start-DcuProcess -FilePath $DcuPath -Arguments $applyArgs
Write-Log -Message "DCU apply exit code: $applyExitCode"

# ---------------------------------------------------------------------------
# 5. Exit Code Policy + Reboot Control with Context Handling
# ---------------------------------------------------------------------------
$noUpdateSuccessCodes = @(0, 500)

# Note: DCU's documented generic reboot-required code is 1 and pending reboot is 5.
# Some environments also observe 3010 from wrapped update installers, so handle it as reboot-required.
$rebootRequiredCodes = @(1, 5, 3010)

if ($applyExitCode -in $noUpdateSuccessCodes) {
    Write-Log -Message 'Result: success/no applicable BIOS updates.'
    Write-Result -Status 'Success' -ExitCode 0 -Message 'Success or no applicable BIOS updates.'
    try { Stop-Transcript | Out-Null } catch {}
    exit 0
}

if ($applyExitCode -in $rebootRequiredCodes) {
    Write-Log -Message 'Result: BIOS update applied; reboot required.'
    Write-Result -Status 'RebootRequired' -ExitCode 3010 -Message 'BIOS update applied; reboot required. Returning 3010 for SCCM handling.'
    try { Stop-Transcript | Out-Null } catch {}
    exit 3010
}

Write-Log -Level 'ERROR' -Message "Result: DCU failed/unknown exit code: $applyExitCode"
Write-Result -Status 'Failed' -ExitCode 1 -Message "DCU failed or returned an unknown exit code: $applyExitCode" -DcuExitCode $applyExitCode
try { Stop-Transcript | Out-Null } catch {}
exit 1
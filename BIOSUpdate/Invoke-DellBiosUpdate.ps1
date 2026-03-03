<#
.SYNOPSIS
    Executes Dell BIOS updates safely by using Dell Command | Update CLI, optimized for both Intune and SCCM deployment scenarios.

.DESCRIPTION
    Production-oriented BIOS update wrapper for co-managed environments with enhanced support for both Intune and SCCM deployment methods.
    Key behaviors:
      - Resolves DCU path in both x64 and x86 install locations.
      - Enforces AC power + battery threshold checks (laptops).
      - Uses BIOS-only scope for scan/apply operations.
      - Uses Dell CLI style consistently: /command -option=value.
      - Suspends BitLocker on the OS volume before BIOS update with automatic resume after N reboots.
      - Supports secure BIOS password arguments (encrypted only).
      - Handles known DCU exit states and controlled reboot behavior.
      - Enhanced logging for both Intune and SCCM environments.
      - Dynamic configuration based on deployment context (Intune vs SCCM).

    Notes:
      - Toast notifications from SYSTEM context may not render for the logged-on user.
        They are best-effort only and never block update flow.
      - If your management plane should own all reboot UX, run with -NoAutoReboot.
      - Script automatically detects deployment context and adjusts behavior accordingly.

.PARAMETER Force
    Skip interactive grace delay.

.PARAMETER MinBatteryPercent
    Minimum battery percentage required when a battery is present.

.PARAMETER UserGraceSeconds
    Delay before update when an interactive user is detected.

.PARAMETER RebootDelaySeconds
    Delay before restart when reboot is required and user session is detected.

.PARAMETER NoAutoReboot
    Do not restart automatically. Exit 3010 when reboot is required.

.PARAMETER EncryptedPassword
    Encrypted BIOS password value for DCU.

.PARAMETER EncryptedPasswordFile
    Path to encrypted BIOS password file for DCU.

.PARAMETER EncryptionKey
    Encryption key used with encrypted BIOS password value/file.

.PARAMETER DeploymentContext
    Specifies deployment context: 'Intune', 'SCCM', or 'Auto' (auto-detects). Default is 'Auto'.

.PARAMETER LogLevel
    Sets logging verbosity: 'INFO', 'DEBUG', 'WARN', 'ERROR'. Default is 'INFO'.

.NOTES
    Preferred log root: C:\ProgramData\Dell\Logs
    Fallback log root:  %TEMP%\Dell\Logs (if ProgramData is not writable)
    Enhanced for both Intune Win32 app deployments and SCCM software update catalog integration.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100)]
    [int]$MinBatteryPercent = 30,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 3600)]
    [int]$UserGraceSeconds = 60,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 7200)]
    [int]$RebootDelaySeconds = 120,

    [Parameter(Mandatory = $false)]
    [switch]$NoAutoReboot,

    [Parameter(Mandatory = $false)]
    [string]$EncryptedPassword,

    [Parameter(Mandatory = $false)]
    [string]$EncryptedPasswordFile,

    [Parameter(Mandatory = $false)]
    [string]$EncryptionKey,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Auto', 'Intune', 'SCCM')]
    [string]$DeploymentContext = 'Auto',

    [Parameter(Mandatory = $false)]
    [ValidateSet('INFO', 'DEBUG', 'WARN', 'ERROR')]
    [string]$LogLevel = 'INFO'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 1. Configuration and Context Detection
# ---------------------------------------------------------------------------
$DcuCandidates = @(
    "${env:ProgramFiles}\Dell\CommandUpdate\dcu-cli.exe",
    "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe"
)

$DellLogRoot      = $null
$ScriptLogPath    = $null
$TranscriptPath   = $null
$DcuScanLogPath   = $null
$DcuApplyLogPath  = $null

# ---------------------------------------------------------------------------
# 2. Helper Functions
# ---------------------------------------------------------------------------
function Initialize-Logging {
    param([string]$LogLevel)

    $preferredRoot = Join-Path $env:ProgramData 'Dell\Logs'
    $fallbackRoot = Join-Path $env:TEMP 'Dell\Logs'

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

    $script:ScriptLogPath   = Join-Path $script:DellLogRoot 'Invoke-DellBiosUpdate.log'
    $script:TranscriptPath  = Join-Path $script:DellLogRoot 'Invoke-DellBiosUpdate.transcript.log'
    $script:DcuScanLogPath  = Join-Path $script:DellLogRoot 'dcu_scan.log'
    $script:DcuApplyLogPath = Join-Path $script:DellLogRoot 'dcu_apply.log'

    if (-not (Test-Path -LiteralPath $script:ScriptLogPath)) {
        New-Item -Path $script:ScriptLogPath -ItemType File -Force | Out-Null
    }

    # Set logging level
    $script:LogLevel = $LogLevel.ToUpper()
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $false)][ValidateSet('INFO','DEBUG','WARN','ERROR')][string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "[$timestamp] [$Level] $Message"

    # Write to console if DEBUG level
    if ($script:LogLevel -eq 'DEBUG' -or $Level -eq 'ERROR' -or $Level -eq 'WARN') {
        Write-Host $logEntry -ForegroundColor $GetLogLevelColor($Level)
    }

    # Always write to log file
    Add-Content -LiteralPath $ScriptLogPath -Value $logEntry
}

function GetLogLevelColor {
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

    foreach ($battery in @($batteries)) {
        $status = [int]$battery.BatteryStatus
        $charge = [int]$battery.EstimatedChargeRemaining
        Write-Log -Message "Battery status=$status, charge=$charge%."

        # Win32_Battery BatteryStatus 2 = On AC/Charging
        if ($status -ne 2) {
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

function Test-IsUserLoggedOn {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    return (-not [string]::IsNullOrWhiteSpace($cs.UserName))
}

function Detect-DeploymentContext {
    param([string]$SpecifiedContext)

    if ($SpecifiedContext -ne 'Auto') {
        return $SpecifiedContext
    }

    # Intune detection: Check for Intune management agent
    if (Get-Service -Name 'IntuneManagementExtension' -ErrorAction SilentlyContinue) {
        return 'Intune'
    }

    # SCCM detection: Check for SCCM client
    if (Get-Service -Name 'SMS_Executive' -ErrorAction SilentlyContinue) {
        return 'SCCM'
    }

    # Default to Intune if no clear detection
    return 'Intune'
}

function Send-UserNotification {
    param([Parameter(Mandatory = $true)][string]$Message)

    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

        $template = @"
<toast scenario="reminder">
  <visual>
    <binding template="ToastGeneric">
      <text>IT System Maintenance</text>
      <text>$Message</text>
    </binding>
  </visual>
</toast>
"@
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml($template)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Dell BIOS Update').Show($toast)
        Write-Log -Message 'Notification attempt sent.'
    }
    catch {
        Write-Log -Level 'WARN' -Message 'Notification could not be displayed (common in SYSTEM context).'
    }
}

function Invoke-BitLockerSuspend {
    $systemDrive = $env:SystemDrive
    if ([string]::IsNullOrWhiteSpace($systemDrive)) { $systemDrive = 'C:' }

    try {
        $before = Get-BitLockerVolume -MountPoint $systemDrive -ErrorAction Stop
        Write-Log -Message "BitLocker pre-state: MountPoint=$systemDrive ProtectionStatus=$($before.ProtectionStatus) VolumeStatus=$($before.VolumeStatus)."
    }
    catch {
        Write-Log -Level 'WARN' -Message "Could not query BitLocker pre-state on $systemDrive. Continuing to suspend attempt."
    }

    try {
        Write-Log -Message "Suspending BitLocker on $systemDrive for 2 reboot cycles."
        Suspend-BitLocker -MountPoint $systemDrive -RebootCount 2 -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Log -Level 'ERROR' -Message "Failed to suspend BitLocker on $systemDrive. $($_.Exception.Message)"
        throw
    }

    try {
        $after = Get-BitLockerVolume -MountPoint $systemDrive -ErrorAction Stop
        Write-Log -Message "BitLocker post-state: MountPoint=$systemDrive ProtectionStatus=$($after.ProtectionStatus) VolumeStatus=$($after.VolumeStatus)."
    }
    catch {
        Write-Log -Level 'WARN' -Message "Could not query BitLocker post-state on $systemDrive."
    }
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
Write-Log -Message "Deployment context: $DeploymentContext (Auto-detected: $(Detect-DeploymentContext -SpecifiedContext $DeploymentContext))"
Write-Log -Message "Log level: $LogLevel"

if (-not (Test-RunningAsAdmin)) {
    Write-Log -Level 'ERROR' -Message 'Script must run elevated (Administrator/SYSTEM).'
    exit 1
}

if ($EncryptedPassword -and $EncryptedPasswordFile) {
    Write-Log -Level 'ERROR' -Message 'Specify either -EncryptedPassword or -EncryptedPasswordFile, not both.'
    exit 1
}

if (($EncryptedPassword -or $EncryptedPasswordFile) -and -not $EncryptionKey) {
    Write-Log -Level 'ERROR' -Message 'EncryptionKey is required when encrypted BIOS password input is provided.'
    exit 1
}

$DcuPath = Resolve-DcuPath
if (-not $DcuPath) {
    Write-Log -Level 'ERROR' -Message 'Dell Command | Update CLI (dcu-cli.exe) not found in standard install locations.'
    exit 1
}
Write-Log -Message "Resolved DCU path: $DcuPath"

if (-not (Test-PowerStatus -MinimumBatteryPercent $MinBatteryPercent)) {
    Write-Log -Level 'ERROR' -Message 'Power prerequisites not met. Exiting without update.'
    exit 1
}

$isInteractive = Test-IsUserLoggedOn
Write-Log -Message "Session type: $(if ($isInteractive) { 'Interactive' } else { 'Headless' })"

if ($isInteractive -and -not $Force -and $UserGraceSeconds -gt 0) {
    Send-UserNotification -Message "A required BIOS update starts in $UserGraceSeconds seconds. Please save your work."
    Write-Log -Message "User grace delay: $UserGraceSeconds seconds."
    Start-Sleep -Seconds $UserGraceSeconds
}

# ---------------------------------------------------------------------------
# 4. Execute BIOS Update Flow with Context-Specific Logic
# ---------------------------------------------------------------------------
Invoke-BitLockerSuspend

$scanArgs = @(
    '/scan',
    '-updateType=bios',
    '-silent',
    "-outputLog=$DcuScanLogPath"
)

$scanExitCode = Start-DcuProcess -FilePath $DcuPath -Arguments $scanArgs
Write-Log -Message "DCU scan exit code: $scanExitCode"

$applyArgs = @(
    '/applyUpdates',
    '-updateType=bios',
    '-silent',
    '-reboot=disable',
    '-autoSuspendBitLocker=enable',
    "-outputLog=$DcuApplyLogPath"
)

if ($EncryptedPassword) {
    $applyArgs += "-encryptedPassword=$EncryptedPassword"
    $applyArgs += "-encryptionKey=$EncryptionKey"
}
elseif ($EncryptedPasswordFile) {
    $applyArgs += "-encryptedPasswordFile=$EncryptedPasswordFile"
    $applyArgs += "-encryptionKey=$EncryptionKey"
}

# Add context-specific arguments
switch (Detect-DeploymentContext -SpecifiedContext $DeploymentContext) {
    'Intune' {
        $applyArgs += '-logLevel=verbose'
        Write-Log -Message 'Intune deployment context detected. Adding verbose logging.'
    }
    'SCCM' {
        $applyArgs += '-logLevel=standard'
        Write-Log -Message 'SCCM deployment context detected. Adding standard logging.'
    }
    default {
        Write-Log -Message 'Auto-detected deployment context. Using default logging.'
    }
}

$applyExitCode = Start-DcuProcess -FilePath $DcuPath -Arguments $applyArgs
Write-Log -Message "DCU apply exit code: $applyExitCode"

# ---------------------------------------------------------------------------
# 5. Exit Code Policy + Reboot Control with Context Handling
# ---------------------------------------------------------------------------
$noUpdateSuccessCodes = @(0, 500)

$rebootRequiredCodes = @(1)

if ($applyExitCode -in $noUpdateSuccessCodes) {
    Write-Log -Message 'Result: success/no applicable BIOS updates.'
    exit 0
}

if ($applyExitCode -in $rebootRequiredCodes) {
    Write-Log -Message 'Result: BIOS update applied; reboot required.'

    if ($NoAutoReboot) {
        Write-Log -Message 'NoAutoReboot set. Returning 3010 for management-plane restart handling.'
        exit 3010
    }

    if ($isInteractive -and $RebootDelaySeconds -gt 0) {
        Send-UserNotification -Message "BIOS update completed. Restarting in $RebootDelaySeconds seconds."
        Write-Log -Message "Reboot delay: $RebootDelaySeconds seconds."
        Start-Sleep -Seconds $RebootDelaySeconds
    }

    Write-Log -Message 'Initiating forced reboot now.'
    Restart-Computer -Force
    exit 0
}

Write-Log -Level 'ERROR' -Message "Result: DCU failed/unknown exit code: $applyExitCode"
exit 1
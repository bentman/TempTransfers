# Phase 2: Reinstall WSUS
# Run this AFTER Phase2-NuclearCleanup.ps1 and reboot
# Run in elevated PowerShell

#Requires -RunAsAdministrator

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Phase 2: WSUS Reinstallation" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Find the most recent backup
$backupDirs = Get-ChildItem -Path "C:\Temp" -Filter "WSUS_Nuclear_Backup_*" -Directory | 
    Sort-Object LastWriteTime -Descending

if ($backupDirs.Count -eq 0) {
    Write-Host "⚠ WARNING: No backup configuration found" -ForegroundColor Yellow
    Write-Host "  Using SSL-only default values`n" -ForegroundColor Yellow
    
    $wsusConfig = @{
        ContentDir = "C:\WSUS"
        PortNumber = 8531
        UsingSSL = 1
        EnforceSSLOnly = $true
    }
} else {
    $latestBackup = $backupDirs[0].FullName
    Write-Host "Using configuration from: $latestBackup`n" -ForegroundColor Gray
    
    $wsusConfig = Import-Clixml "$latestBackup\WSUS_Config.xml"
    
    # Enforce SSL-only configuration regardless of saved configuration
    if ($wsusConfig.EnforceSSLOnly -eq $true) {
        Write-Host " SSL-Only enforcement enabled - forcing SSL configuration" -ForegroundColor Yellow
        $wsusConfig.PortNumber = 8531
        $wsusConfig.UsingSSL = 1
    }
}

Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Content Directory: $($wsusConfig.ContentDir)" -ForegroundColor Gray
Write-Host "  Port: $($wsusConfig.PortNumber)" -ForegroundColor Gray
Write-Host "  Using SSL: $($wsusConfig.UsingSSL)" -ForegroundColor Gray
Write-Host "  SSL-Only Enforcement: $($wsusConfig.EnforceSSLOnly)" -ForegroundColor Gray
Write-Host ""

# ========================================
# PHASE 2.1: INSTALL WSUS FEATURES
# ========================================
Write-Host "[Phase 2.1] Installing WSUS features..." -ForegroundColor Yellow

try {
    Install-WindowsFeature -Name UpdateServices-Services, UpdateServices-DB -IncludeManagementTools -ErrorAction Stop
    Write-Host "  ✓ WSUS features installed`n" -ForegroundColor Green
} catch {
    Write-Host "  ✗ Installation failed: $_" -ForegroundColor Red
    exit 1
}

# ========================================
# PHASE 2.2: CREATE CONTENT DIRECTORY
# ========================================
Write-Host "[Phase 2.2] Creating content directory..." -ForegroundColor Yellow

$contentDir = if ($wsusConfig.ContentDir) { $wsusConfig.ContentDir } else { "C:\WSUS" }

if (!(Test-Path $contentDir)) {
    New-Item -Path $contentDir -ItemType Directory -Force | Out-Null
    Write-Host "  ✓ Created: $contentDir`n" -ForegroundColor Green
} else {
    Write-Host "  ✓ Directory exists: $contentDir`n" -ForegroundColor Green
}

# ========================================
# PHASE 2.3: RUN POSTINSTALL
# ========================================
Write-Host "[Phase 2.3] Running wsusutil postinstall..." -ForegroundColor Yellow

$wsusUtilPath = "C:\Program Files\Update Services\Tools\wsusutil.exe"
if (!(Test-Path $wsusUtilPath)) {
    Write-Host "  ✗ wsusutil.exe not found at: $wsusUtilPath" -ForegroundColor Red
    exit 1
}

Write-Host "  Executing postinstall (this may take several minutes)..." -ForegroundColor Gray

# Build postinstall command
$postinstallArgs = "postinstall CONTENT_DIR=$contentDir"

# Add SQL instance if using remote/named SQL
if ($wsusConfig.DatabaseServer -and $wsusConfig.DatabaseServer -notmatch "MICROSOFT##WID") {
    $postinstallArgs += " SQL_INSTANCE_NAME=`"$($wsusConfig.DatabaseServer)`""
}

Write-Host "  Command: wsusutil.exe $postinstallArgs" -ForegroundColor Gray

$postinstallResult = & $wsusUtilPath $postinstallArgs.Split(' ') 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✓ Postinstall completed successfully`n" -ForegroundColor Green
} else {
    Write-Host "  ✗ Postinstall failed with exit code: $LASTEXITCODE" -ForegroundColor Red
    Write-Host "  Output: $postinstallResult`n" -ForegroundColor Red
    
    # Check common failure reasons
    Write-Host "Troubleshooting:" -ForegroundColor Yellow
    Write-Host "  1. Check Application Event Log for WsusSetup errors" -ForegroundColor Gray
    Write-Host "  2. Verify SQL Server/WID is running" -ForegroundColor Gray
    Write-Host "  3. Check permissions on content directory" -ForegroundColor Gray
    Write-Host "  4. Verify IIS is running`n" -ForegroundColor Gray
    
    exit 1
}

Start-Sleep -Seconds 5

# ========================================
# PHASE 2.4: VERIFY SERVICE REGISTRATION
# ========================================
Write-Host "[Phase 2.4] Verifying service registration..." -ForegroundColor Yellow

# Test 1: Get-Service
Write-Host "  Test 1: Get-Service..." -NoNewline
try {
    $service = Get-Service WSUSService -ErrorAction Stop
    Write-Host " PASS ✓" -ForegroundColor Green
    Write-Host "    Status: $($service.Status)" -ForegroundColor Gray
    Write-Host "    StartType: $($service.StartType)" -ForegroundColor Gray
} catch {
    Write-Host " FAIL ✗" -ForegroundColor Red
    Write-Host "    Error: $_" -ForegroundColor Red
}

# Test 2: sc.exe query
Write-Host "`n  Test 2: SC Query..." -NoNewline
$scResult = sc.exe query WSUSService 2>&1
if ($scResult -match "RUNNING|STOPPED") {
    Write-Host " PASS ✓" -ForegroundColor Green
} else {
    Write-Host " FAIL ✗" -ForegroundColor Red
    Write-Host "    $scResult" -ForegroundColor Red
}

# Test 3: Process running
Write-Host "`n  Test 3: Process check..." -NoNewline
$process = Get-Process WsusService -ErrorAction SilentlyContinue
if ($process) {
    Write-Host " PASS ✓" -ForegroundColor Green
    Write-Host "    PID: $($process.Id)" -ForegroundColor Gray
} else {
    Write-Host " FAIL ✗" -ForegroundColor Red
}

# Test 4: Network ports
Write-Host "`n  Test 4: Network connectivity..."
Write-Host "    Port 8530 (HTTP)..." -NoNewline
$port8530 = Test-NetConnection -ComputerName localhost -Port 8530 -WarningAction SilentlyContinue
if ($port8530.TcpTestSucceeded) {
    Write-Host " PASS ✓" -ForegroundColor Green
} else {
    Write-Host " FAIL ✗" -ForegroundColor Red
}

if ($wsusConfig.UsingSSL -eq 1) {
    Write-Host "    Port 8531 (HTTPS)..." -NoNewline
    $port8531 = Test-NetConnection -ComputerName localhost -Port 8531 -WarningAction SilentlyContinue
    if ($port8531.TcpTestSucceeded) {
        Write-Host " PASS ✓" -ForegroundColor Green
    } else {
        Write-Host " FAIL ✗" -ForegroundColor Red
    }
}

# Test 5: WSUS API
Write-Host "`n Test 5: WSUS API access..." -NoNewline
try {
    $port = if ($wsusConfig.UsingSSL -eq 1) { 8531 } else { 8530 }
    $useSSL = $wsusConfig.UsingSSL -eq 1
    
    $wsus = [Microsoft.UpdateServices.Administration.AdminProxy]::GetUpdateServer('localhost', $useSSL, $port)
    $wsusStatus = $wsus.GetStatus()
    Write-Host " PASS ✓" -ForegroundColor Green
    Write-Host "    Database version: $($wsusStatus.DatabaseVersion)" -ForegroundColor Gray
} catch {
    Write-Host " FAIL ✗" -ForegroundColor Red
    Write-Host "    Error: $_" -ForegroundColor Red
}

# Test 6: SSL-Only Configuration Validation
Write-Host "`n  Test 6: SSL-Only configuration validation..." -NoNewline
try {
    # Check registry to ensure UsingSSL is set correctly
    $regUsingSSL = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup" -Name UsingSSL -ErrorAction SilentlyContinue).UsingSSL
    $regPortNumber = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup" -Name PortNumber -ErrorAction SilentlyContinue).PortNumber
    
    if ($regUsingSSL -eq 1 -and $regPortNumber -eq 8531) {
        Write-Host " PASS ✓" -ForegroundColor Green
        Write-Host "    Registry UsingSSL: $regUsingSSL (expected: 1)" -ForegroundColor Gray
        Write-Host "    Registry PortNumber: $regPortNumber (expected: 8531)" -ForegroundColor Gray
    } else {
        Write-Host " FAIL ✗" -ForegroundColor Red
        Write-Host "    Registry UsingSSL: $regUsingSSL (expected: 1)" -ForegroundColor Gray
        Write-Host "    Registry PortNumber: $regPortNumber (expected: 8531)" -ForegroundColor Gray
    }
} catch {
    Write-Host " FAIL ✗" -ForegroundColor Red
    Write-Host "    Error checking registry: $_" -ForegroundColor Red
}

# ========================================
# PHASE 2.5: SUMMARY
# ========================================
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Overall status check
$overallSuccess = $true
try {
    $svc = Get-Service WSUSService -ErrorAction Stop
    $overallSuccess = ($svc.Status -eq 'Running' -and $svc.StartType -eq 'Automatic')
    $scTest = (sc.exe query WSUSService 2>&1) -match "RUNNING"
    $overallSuccess = $overallSuccess -and $scTest
} catch {
    $overallSuccess = $false
}

if ($overallSuccess) {
    Write-Host "✓ WSUS reinstallation successful!`n" -ForegroundColor Green
    
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "  1. Configure WSUS via console (set upstream server, products, classifications)" -ForegroundColor White
    Write-Host "  2. In SCCM Console:" -ForegroundColor White
    Write-Host "     - Remove and re-add Software Update Point role" -ForegroundColor White
    Write-Host "     - Verify SSL setting matches WSUS (SSL=$($wsusConfig.UsingSSL -eq 1))" -ForegroundColor White
    Write-Host "     - Configure port ($($wsusConfig.PortNumber))" -ForegroundColor White
    Write-Host "  3. Initiate manual SUP sync from SCCM" -ForegroundColor White
    Write-Host "  4. Monitor WCM.log and WSyncMgr.log" -ForegroundColor White
    Write-Host "  5. Test reboot after 24 hours of successful operation`n" -ForegroundColor White
    
} else {
    Write-Host "✗ WSUS reinstallation incomplete`n" -ForegroundColor Red
    
    Write-Host "Troubleshooting steps:" -ForegroundColor Yellow
    Write-Host "  1. Check Event Viewer > Application log for 'WsusSetup' errors" -ForegroundColor White
    Write-Host "  2. Review IIS configuration and application pools" -ForegroundColor White
    Write-Host "  3. Verify SQL Server/WID service is running" -ForegroundColor White
    Write-Host "  4. Check content directory permissions" -ForegroundColor White
    Write-Host "  5. Review postinstall output above for specific errors`n" -ForegroundColor White
}

Write-Host "WSUS Console: C:\Windows\System32\wsus\UpdateServicesConsole.exe" -ForegroundColor Gray
Write-Host "WSUS Tools: C:\Program Files\Update Services\Tools\`n" -ForegroundColor Gray

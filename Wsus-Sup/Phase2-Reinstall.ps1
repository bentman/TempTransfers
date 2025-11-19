# Phase 2: Reinstall WSUS
# Run this AFTER Phase2-NuclearCleanup.ps1 and reboot
# Run in elevated PowerShell

#Requires -RunAsAdministrator

$hostname = hostname
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$outputFile = "C:\Temp\WSUS-REINSTALL_${hostname}-${timestamp}.txt"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Phase 2: WSUS Reinstallation" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Initialize report content
$reportContent = @()
$reportContent += "=" * 80
$reportContent += "WSUS REINSTALLATION REPORT"
$reportContent += "Server: $hostname"
$reportContent += "Date/Time: $(Get-Date)"
$reportContent += "Script: Phase2-Reinstall.ps1"
$reportContent += "=" * 80
$reportContent += ""

# Check for Configuration Manager site code (if SCCM is installed)
$siteCode = $null
try {
    # Try to get the site code from registry if SCCM client is installed
    $sccmRegPath = "HKLM:\SOFTWARE\Microsoft\CCM"
    if (Test-Path $sccmRegPath) {
        $siteCode = (Get-ItemProperty $sccmRegPath -ErrorAction SilentlyContinue).'CM Site Code'
    }
    # Alternative registry location for site code
    if (-not $siteCode) {
        $sccmRegPath2 = "HKLM:\SOFTWARE\Microsoft\SMS\Identification"
        if (Test-Path $sccmRegPath2) {
            $siteCode = (Get-ItemProperty $sccmRegPath2 -ErrorAction SilentlyContinue).SiteCode
        }
    }
} catch {
    # If we can't get the site code, continue without it
}

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
    $reportContent += "1. CONFIGURATION SOURCE:"
    $reportContent += "   Status: NO BACKUP FOUND - USING DEFAULT SSL-ONLY VALUES"
    $reportContent += "   Content Directory: C:\WSUS"
    $reportContent += "   Port Number: 8531 (HTTPS)"
    $reportContent += "   Using SSL: 1 (Enabled)"
    if ($siteCode) {
        $reportContent += "   SCCM Site Code: $siteCode"
    }
    $reportContent += ""
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
    
    $reportContent += "1. CONFIGURATION SOURCE:"
    $reportContent += "   Backup Directory: $latestBackup"
    $reportContent += "   Content Directory: $($wsusConfig.ContentDir)"
    $reportContent += "   Port Number: $($wsusConfig.PortNumber)"
    $reportContent += "   Using SSL: $($wsusConfig.UsingSSL)"
    $reportContent += "   SSL-Only Enforcement: $($wsusConfig.EnforceSSLOnly)"
    if ($wsusConfig.EnforceSSLOnly -eq $true) {
        $reportContent += "   SSL Configuration: FORCED TO SSL-ONLY MODE"
    }
    if ($siteCode) {
        $reportContent += "   SCCM Site Code: $siteCode"
    }
    $reportContent += ""
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
    $featureResult = Install-WindowsFeature -Name UpdateServices-Services, UpdateServices-DB -IncludeManagementTools -ErrorAction Stop
    Write-Host "  ✓ WSUS features installed`n" -ForegroundColor Green
    $reportContent += "2. WSUS FEATURES INSTALLATION:"
    $reportContent += "   UpdateServices-Services: INSTALLED ✓"
    $reportContent += "   UpdateServices-DB: INSTALLED ✓"
    $reportContent += "   IncludeManagementTools: YES"
} catch {
    Write-Host "  ✗ Installation failed: $_" -ForegroundColor Red
    $reportContent += "2. WSUS FEATURES INSTALLATION:"
    $reportContent += "   Status: FAILED ✗"
    $reportContent += "   Error: $($_.Exception.Message)"
    $reportContent | Out-File -FilePath $outputFile -Encoding UTF8
    exit 1
}
$reportContent += ""

# ========================================
# PHASE 2.2: CREATE CONTENT DIRECTORY
# ========================================
Write-Host "[Phase 2.2] Creating content directory..." -ForegroundColor Yellow

$contentDir = if ($wsusConfig.ContentDir) { $wsusConfig.ContentDir } else { "C:\WSUS" }

if (!(Test-Path $contentDir)) {
    New-Item -Path $contentDir -ItemType Directory -Force | Out-Null
    Write-Host "  ✓ Created: $contentDir`n" -ForegroundColor Green
    $reportContent += "3. CONTENT DIRECTORY:"
    $reportContent += "   Path: $contentDir"
    $reportContent += "   Status: CREATED ✓"
} else {
    Write-Host "  ✓ Directory exists: $contentDir`n" -ForegroundColor Green
    $reportContent += "3. CONTENT DIRECTORY:"
    $reportContent += "   Path: $contentDir"
    $reportContent += "   Status: ALREADY EXISTS ✓"
}
$reportContent += ""

# ========================================
# PHASE 2.3: RUN POSTINSTALL
# ========================================
Write-Host "[Phase 2.3] Running wsusutil postinstall..." -ForegroundColor Yellow

$wsusUtilPath = "C:\Program Files\Update Services\Tools\wsusutil.exe"
if (!(Test-Path $wsusUtilPath)) {
    Write-Host "  ✗ wsusutil.exe not found at: $wsusUtilPath" -ForegroundColor Red
    $reportContent += "4. WSUSUTIL POSTINSTALL:"
    $reportContent += "   wsusutil.exe Path: $wsusUtilPath"
    $reportContent += "   Status: NOT FOUND ✗"
    $reportContent | Out-File -FilePath $outputFile -Encoding UTF8
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
    $reportContent += "4. WSUSUTIL POSTINSTALL:"
    $reportContent += "   Command: wsusutil.exe $postinstallArgs"
    $reportContent += "   Status: SUCCESS ✓"
    $reportContent += "   Exit Code: $LASTEXITCODE"
} else {
    Write-Host "  ✗ Postinstall failed with exit code: $LASTEXITCODE" -ForegroundColor Red
    Write-Host "  Output: $postinstallResult`n" -ForegroundColor Red
    
    # Check common failure reasons
    Write-Host "Troubleshooting:" -ForegroundColor Yellow
    Write-Host "  1. Check Application Event Log for WsusSetup errors" -ForegroundColor Gray
    Write-Host "  2. Verify SQL Server/WID is running" -ForegroundColor Gray
    Write-Host "  3. Check permissions on content directory" -ForegroundColor Gray
    Write-Host "  4. Verify IIS is running`n" -ForegroundColor Gray
    
    $reportContent += "4. WSUSUTIL POSTINSTALL:"
    $reportContent += "   Command: wsusutil.exe $postinstallArgs"
    $reportContent += "   Status: FAILED ✗"
    $reportContent += "   Exit Code: $LASTEXITCODE"
    $reportContent += "   Output: $postinstallResult"
    $reportContent | Out-File -FilePath $outputFile -Encoding UTF8
    exit 1
}
$reportContent += ""

Start-Sleep -Seconds 5

# ========================================
# PHASE 2.4: VERIFY SERVICE REGISTRATION
# ========================================
Write-Host "[Phase 2.4] Verifying service registration..." -ForegroundColor Yellow

# Get service dependencies for reporting
$serviceReg = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\WSUSService" -ErrorAction SilentlyContinue
$dependencies = $serviceReg | Select-Object -ExpandProperty DependOnService -ErrorAction SilentlyContinue

$reportContent += "5. SERVICE DEPENDENCIES:"
if ($dependencies) {
    $reportContent += "   WSUS Service Dependencies: $($dependencies -join ', ')"
    foreach ($dep in $dependencies) {
        $depStatus = Get-Service $dep -ErrorAction SilentlyContinue
        if ($depStatus) {
            $reportContent += "   - $dep : $($depStatus.Status)"
        } else {
            $reportContent += "   - $dep : NOT FOUND"
        }
    }
} else {
    $reportContent += "   WSUS Service Dependencies: None found in registry"
}
$reportContent += ""

# Test 1: Get-Service
Write-Host "  Test 1: Get-Service..." -NoNewline
try {
    $service = Get-Service WSUSService -ErrorAction Stop
    Write-Host " PASS ✓" -ForegroundColor Green
    $reportContent += "6. SERVICE VALIDATION TESTS:"
    $reportContent += "   Test 1 - Get-Service: PASS ✓"
    $reportContent += "   Service Status: $($service.Status)"
    $reportContent += "   Service StartType: $($service.StartType)"
} catch {
    Write-Host " FAIL ✗" -ForegroundColor Red
    Write-Host "    Error: $_" -ForegroundColor Red
    $reportContent += "6. SERVICE VALIDATION TESTS:"
    $reportContent += "   Test 1 - Get-Service: FAIL ✗"
    $reportContent += "   Error: $($_.Exception.Message)"
}

# Test 2: sc.exe query
Write-Host "`n  Test 2: SC Query..." -NoNewline
$scResult = sc.exe query WSUSService 2>&1
if ($scResult -match "RUNNING|STOPPED") {
    Write-Host " PASS ✓" -ForegroundColor Green
    $reportContent += "   Test 2 - SC Query: PASS ✓"
} else {
    Write-Host " FAIL ✗" -ForegroundColor Red
    Write-Host " $scResult" -ForegroundColor Red
    $reportContent += "   Test 2 - SC Query: FAIL ✗"
    $reportContent += "   SC Result: $scResult"
}

# Test 3: Process running
Write-Host "`n  Test 3: Process check..." -NoNewline
$process = Get-Process WsusService -ErrorAction SilentlyContinue
if ($process) {
    Write-Host " PASS ✓" -ForegroundColor Green
    Write-Host "    PID: $($process.Id)" -ForegroundColor Gray
    $reportContent += "   Test 3 - Process Check: PASS ✓"
    $reportContent += "   Process ID: $($process.Id)"
} else {
    Write-Host " FAIL ✗" -ForegroundColor Red
    $reportContent += "   Test 3 - Process Check: FAIL ✗"
    $reportContent += "   Process Status: NOT RUNNING"
}

# Test 4: Network ports
Write-Host "`n  Test 4: Network connectivity..."
Write-Host "    Port 8530 (HTTP)..." -NoNewline
$port8530 = Test-NetConnection -ComputerName localhost -Port 8530 -WarningAction SilentlyContinue
if ($port8530.TcpTestSucceeded) {
    Write-Host " PASS ✓" -ForegroundColor Green
    $reportContent += "   Test 4 - Port 8530 (HTTP): PASS ✓"
} else {
    Write-Host " FAIL ✗" -ForegroundColor Red
    $reportContent += "   Test 4 - Port 8530 (HTTP): FAIL ✗"
}

if ($wsusConfig.UsingSSL -eq 1) {
    Write-Host "    Port 8531 (HTTPS)..." -NoNewline
    $port8531 = Test-NetConnection -ComputerName localhost -Port 8531 -WarningAction SilentlyContinue
    if ($port8531.TcpTestSucceeded) {
        Write-Host " PASS ✓" -ForegroundColor Green
        $reportContent += "   Test 5 - Port 8531 (HTTPS): PASS ✓"
    } else {
        Write-Host " FAIL ✗" -ForegroundColor Red
        $reportContent += "   Test 5 - Port 8531 (HTTPS): FAIL ✗"
    }
} else {
    $reportContent += "   Test 5 - Port 8531 (HTTPS): SKIPPED (SSL disabled)"
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
    $reportContent += "   Test 6 - WSUS API Access: PASS ✓"
    $reportContent += "   API Port: $port (SSL: $useSSL)"
    $reportContent += "   Database Version: $($wsusStatus.DatabaseVersion)"
} catch {
    Write-Host " FAIL ✗" -ForegroundColor Red
    Write-Host "    Error: $_" -ForegroundColor Red
    $reportContent += "   Test 6 - WSUS API Access: FAIL ✗"
    $reportContent += "   Error: $($_.Exception.Message)"
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
        $reportContent += "   Test 7 - SSL Configuration: PASS ✓"
        $reportContent += "   Registry UsingSSL: $regUsingSSL (expected: 1)"
        $reportContent += "   Registry PortNumber: $regPortNumber (expected: 8531)"
    } else {
        Write-Host " FAIL ✗" -ForegroundColor Red
        Write-Host "    Registry UsingSSL: $regUsingSSL (expected: 1)" -ForegroundColor Gray
        Write-Host "    Registry PortNumber: $regPortNumber (expected: 8531)" -ForegroundColor Gray
        $reportContent += "   Test 7 - SSL Configuration: FAIL ✗"
        $reportContent += "   Registry UsingSSL: $regUsingSSL (expected: 1)"
        $reportContent += "   Registry PortNumber: $regPortNumber (expected: 8531)"
    }
} catch {
    Write-Host " FAIL ✗" -ForegroundColor Red
    Write-Host "    Error checking registry: $_" -ForegroundColor Red
    $reportContent += "   Test 7 - SSL Configuration: FAIL ✗"
    $reportContent += "   Error checking registry: $_"
}
$reportContent += ""

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

# Add layman categorization of errors
$reportContent += "7. SUMMARY AND ERROR CATEGORIZATION:"
$reportContent += "   Server: $hostname"
$reportContent += "   Assessment Time: $(Get-Date)"
$reportContent += ""

$reportContent += "   LAYMAN ERROR CATEGORIES:"

if ($overallSuccess) {
    $reportContent += "   - OK: WSUS reinstallation successful"
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
    $reportContent += "   - ERROR: WSUS reinstallation incomplete"
    Write-Host "✗ WSUS reinstallation incomplete`n" -ForegroundColor Red
    
    Write-Host "Troubleshooting steps:" -ForegroundColor Yellow
    Write-Host "  1. Check Event Viewer > Application log for 'WsusSetup' errors" -ForegroundColor White
    Write-Host " 2. Review IIS configuration and application pools" -ForegroundColor White
    Write-Host "  3. Verify SQL Server/WID service is running" -ForegroundColor White
    Write-Host " 4. Check content directory permissions" -ForegroundColor White
    Write-Host "  5. Review postinstall output above for specific errors`n" -ForegroundColor White
}

$reportContent += ""
$reportContent += "=" * 80
$reportContent += "END OF REPORT"
$reportContent += "=" * 80

# Write the report to file
$reportContent | Out-File -FilePath $outputFile -Encoding UTF8

Write-Host "WSUS Console: C:\Windows\System32\wsus\UpdateServicesConsole.exe" -ForegroundColor Gray
Write-Host "WSUS Tools: C:\Program Files\Update Services\Tools\`n" -ForegroundColor Gray
Write-Host "Report saved to: $outputFile" -ForegroundColor Cyan

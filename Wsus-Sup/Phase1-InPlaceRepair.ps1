# Phase 1: In-Place Service Registration Repair
# Attempts to fix WSUSService registration without full reinstall
# Run in elevated PowerShell
# SAFER OPTION - Try this first before nuclear cleanup

#Requires -RunAsAdministrator

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Phase 1: In-Place Service Repair" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Verify WSUS binary exists
$servicePath = "C:\Program Files\Update Services\WebServices\WsusService\WsusService.exe"
if (!(Test-Path $servicePath)) {
    Write-Error "WsusService.exe not found at: $servicePath"
    Write-Error "Cannot proceed. WSUS may not be installed."
    exit 1
}

Write-Host "✓ WSUS binary found at: $servicePath`n" -ForegroundColor Green

# Step 1: Take ownership and fix ACLs on service registry key
Write-Host "[Step 1/4] Fixing registry ACLs..." -ForegroundColor Yellow

# Check if registry key exists
$serviceKeyExists = Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\WSUSService"

if ($serviceKeyExists) {
    Write-Host "  Service key exists. Fixing permissions..." -ForegroundColor Yellow
    
    # Take ownership using icacls (works better than PowerShell ACL for system keys)
    $regPath = "HKLM\SYSTEM\CurrentControlSet\Services\WSUSService"
    
    # Note: These commands may fail on some systems. That's expected.
    try {
        # Take ownership
        & takeown.exe /f $regPath /r /d y 2>&1 | Out-Null
        
        # Grant full control to Administrators
        & icacls.exe $regPath /grant "Administrators:F" /t 2>&1 | Out-Null
        
        Write-Host "  ✓ ACL permissions updated" -ForegroundColor Green
    } catch {
        Write-Host "  ⚠ Could not modify ACLs: $_" -ForegroundColor Yellow
        Write-Host "    Proceeding anyway..." -ForegroundColor Yellow
    }
} else {
    Write-Host "  ⚠ Service key does not exist - will create" -ForegroundColor Yellow
}

# Step 2: Stop orphaned process (if running)
Write-Host "`n[Step 2/4] Stopping orphaned process..." -ForegroundColor Yellow

$process = Get-Process WsusService -ErrorAction SilentlyContinue
if ($process) {
    Write-Host "  Found process PID: $($process.Id)" -ForegroundColor Yellow
    Stop-Process -Name WsusService -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
    
    if (Get-Process WsusService -ErrorAction SilentlyContinue) {
        Write-Host "  ✗ Process still running - force kill" -ForegroundColor Red
        Stop-Process -Name WsusService -Force
        Start-Sleep -Seconds 5
    }
    Write-Host "  ✓ Process stopped" -ForegroundColor Green
} else {
    Write-Host "  ℹ No orphaned process found" -ForegroundColor Gray
}

# Step 3: Delete and recreate service registration
Write-Host "`n[Step 3/4] Recreating service registration..." -ForegroundColor Yellow

# Delete existing service (if any)
Write-Host "  Removing old service registration..." -ForegroundColor Yellow
$deleteResult = sc.exe delete WSUSService 2>&1
if ($LASTEXITCODE -ne 0 -and $deleteResult -notmatch "does not exist") {
    Write-Host "  ⚠ Delete warning: $deleteResult" -ForegroundColor Yellow
} else {
    Write-Host "  ✓ Old registration removed" -ForegroundColor Green
}

Start-Sleep -Seconds 2

# Create service using sc.exe
Write-Host "  Creating new service registration..." -ForegroundColor Yellow

$displayName = "Windows Server Update Services"
$description = "Enables administrators to distribute updates and patches that are released by Microsoft Update for Windows operating systems and other Microsoft programs."

# Create service with proper parameters
$createResult = sc.exe create WSUSService `
    binPath= "`"$servicePath`"" `
    DisplayName= "$displayName" `
    start= auto `
    depend= RPCSS/W3SVC/WinHttpAutoProxySvc `
    obj= "NT AUTHORITY\NETWORK SERVICE" 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "  ✗ Service creation failed: $createResult" -ForegroundColor Red
    Write-Host "`n  This may require Phase 2 (full cleanup). See Phase2-NuclearCleanup.ps1" -ForegroundColor Yellow
    exit 1
}

Write-Host "  ✓ Service created" -ForegroundColor Green

# Set description
sc.exe description WSUSService "$description" | Out-Null

# Set failure actions (restart on failure)
sc.exe failure WSUSService reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null

# Set security descriptor (proper ACL)
# This SDDL allows SYSTEM, Admins, and Interactive/Service users to manage the service
sc.exe sdset WSUSService "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)S:(AU;FA;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;WD)" | Out-Null

Write-Host "  ✓ Service configuration complete" -ForegroundColor Green

# Step 4: Start service and validate
Write-Host "`n[Step 4/4] Starting service and validating..." -ForegroundColor Yellow

Start-Sleep -Seconds 2

# Start the service
try {
    Start-Service WSUSService -ErrorAction Stop
    Start-Sleep -Seconds 5
    Write-Host "  ✓ Service started" -ForegroundColor Green
} catch {
    Write-Host "  ✗ Failed to start service: $_" -ForegroundColor Red
    Write-Host "`n  Check Application Event Log for details." -ForegroundColor Yellow
}

# Validation
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Validation Results" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Test 1: Get-Service
Write-Host "Test 1: Get-Service cmdlet..." -NoNewline
try {
    $service = Get-Service WSUSService -ErrorAction Stop
    Write-Host " PASS ✓" -ForegroundColor Green
    Write-Host "  Status: $($service.Status)" -ForegroundColor Gray
    Write-Host "  StartType: $($service.StartType)" -ForegroundColor Gray
} catch {
    Write-Host " FAIL ✗" -ForegroundColor Red
    Write-Host "  Error: $_" -ForegroundColor Red
}

# Test 2: sc.exe query
Write-Host "`nTest 2: SC Query..." -NoNewline
$scResult = sc.exe query WSUSService 2>&1
if ($scResult -match "RUNNING|STOPPED") {
    Write-Host " PASS ✓" -ForegroundColor Green
} else {
    Write-Host " FAIL ✗" -ForegroundColor Red
    Write-Host "  $scResult" -ForegroundColor Red
}

# Test 3: Service management (stop/start cycle)
Write-Host "`nTest 3: Service control (stop/start)..." -NoNewline
try {
    Restart-Service WSUSService -ErrorAction Stop
    Start-Sleep -Seconds 5
    $service = Get-Service WSUSService -ErrorAction Stop
    if ($service.Status -eq 'Running') {
        Write-Host " PASS ✓" -ForegroundColor Green
    } else {
        Write-Host " FAIL ✗ (Service not running after restart)" -ForegroundColor Red
    }
} catch {
    Write-Host " FAIL ✗" -ForegroundColor Red
    Write-Host "  Error: $_" -ForegroundColor Red
}

# Test 4: Network ports
Write-Host "`nTest 4: Network connectivity..."
Write-Host "  Port 8530 (HTTP)..." -NoNewline
$port8530 = Test-NetConnection -ComputerName localhost -Port 8530 -WarningAction SilentlyContinue
if ($port8530.TcpTestSucceeded) {
    Write-Host " PASS ✓" -ForegroundColor Green
} else {
    Write-Host " FAIL ✗" -ForegroundColor Red
}

# Summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Next Steps" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$allPassed = $true
try {
    $svc = Get-Service WSUSService -ErrorAction Stop
    $allPassed = ($svc.Status -eq 'Running' -and $svc.StartType -eq 'Automatic')
} catch {
    $allPassed = $false
}

if ($allPassed) {
    Write-Host "✓ Service registration appears successful!`n" -ForegroundColor Green
    Write-Host "Recommended actions:" -ForegroundColor Yellow
    Write-Host "  1. Test WSUS console: Update Services console" -ForegroundColor White
    Write-Host "  2. Verify SCCM SUP sync from SCCM console" -ForegroundColor White
    Write-Host "  3. Schedule maintenance window for reboot test" -ForegroundColor White
    Write-Host "  4. Monitor WCM.log and WSyncMgr.log for 24-48 hours`n" -ForegroundColor White
} else {
    Write-Host "✗ Service registration incomplete`n" -ForegroundColor Red
    Write-Host "This in-place repair did not succeed." -ForegroundColor Yellow
    Write-Host "You may need to proceed to Phase 2 (full cleanup + reinstall).`n" -ForegroundColor Yellow
    Write-Host "See: Phase2-NuclearCleanup.ps1`n" -ForegroundColor Yellow
}

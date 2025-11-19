# Phase 0: Pre-Recovery Assessment
# Run this in elevated PowerShell to document current working state
# DO NOT MODIFY - This is for documentation only

$hostname = hostname
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$outputFile = "C:\Temp\WSUS-ASSESSMENT_${hostname}-${timestamp}.txt"

Write-Host "Phase 0: Capturing current WSUS state..." -ForegroundColor Cyan

# Initialize report content
$reportContent = @()
$reportContent += "=" * 80
$reportContent += "WSUS PRE-RECOVERY ASSESSMENT REPORT"
$reportContent += "Server: $hostname"
$reportContent += "Date/Time: $(Get-Date)"
$reportContent += "Script: Phase0-PreAssessment.ps1"
$reportContent += "=" * 80
$reportContent += ""

# 1. Capture current working process details
Write-Host "  [1/8] Capturing process details..." -ForegroundColor Yellow
$wsusProcess = Get-Process WsusService -ErrorAction SilentlyContinue
if ($wsusProcess) {
    $reportContent += "1. WSUS PROCESS STATUS:"
    $reportContent += "   Process ID: $($wsusProcess.Id)"
    $reportContent += "   Start Time: $($wsusProcess.StartTime)"
    $reportContent += "   Path: $($wsusProcess.Path)"
    $reportContent += "   Status: RUNNING ✓"
    $reportContent += ""
} else {
    $reportContent += "1. WSUS PROCESS STATUS:"
    $reportContent += "   Status: NOT RUNNING ✗"
    $reportContent += ""
}

# 2. Verify current service state in registry
Write-Host "  [2/8] Capturing registry state..." -ForegroundColor Yellow
$serviceReg = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\WSUSService" -ErrorAction SilentlyContinue
if ($serviceReg) {
    $reportContent += "2. SERVICE REGISTRY STATUS:"
    $reportContent += "   Service Name: $($serviceReg.PSChildName)"
    $reportContent += "   Display Name: $($serviceReg.DisplayName)"
    $reportContent += "   Service Type: $($serviceReg.Type)"
    $reportContent += "   Start Type: $($serviceReg.Start)"
    $reportContent += "   Service State: $($serviceReg.State)"
    $reportContent += "   Registry Entry: EXISTS ✓"
    $reportContent += ""
} else {
    $reportContent += "2. SERVICE REGISTRY STATUS:"
    $reportContent += "   Registry Entry: MISSING ✗"
    $reportContent += ""
}

# 3. Check for service in SCM database
Write-Host "  [3/8] Testing SCM query..." -ForegroundColor Yellow
$scResult = sc.exe query wsusservice 2>&1
$scResultStr = $scResult | Out-String
$reportContent += "3. SERVICE CONTROL MANAGER QUERY:"
$reportContent += "   Result: $scResultStr"
$reportContent += ""

# 4. Check for Configuration Manager site code (if SCCM is installed)
Write-Host "  [4/8] Checking for Configuration Manager..." -ForegroundColor Yellow
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
    $reportContent += "4. CONFIGURATION MANAGER INTEGRATION:"
    if ($siteCode) {
        $reportContent += "   Site Code: $siteCode"
        $reportContent += "   SCCM Client: DETECTED ✓"
    } else {
        $reportContent += "   Site Code: NOT FOUND"
        $reportContent += "   SCCM Client: NOT DETECTED"
    }
} catch {
    $reportContent += "4. CONFIGURATION MANAGER INTEGRATION:"
    $reportContent += "   Site Code: ERROR CHECKING"
    $reportContent += "   Error: $($_.Exception.Message)"
}
$reportContent += ""

# 5. Document WSUS configuration
Write-Host "  [5/8] Capturing WSUS configuration..." -ForegroundColor Yellow
$wsusConfig = @{
    ContentDir = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup" -Name ContentDir -ErrorAction SilentlyContinue).ContentDir
    DatabaseServer = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup" -Name SqlServerName -ErrorAction SilentlyContinue).SqlServerName
    DatabaseName = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup" -Name SqlDatabaseName -ErrorAction SilentlyContinue).SqlDatabaseName
    PortNumber = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup" -Name PortNumber -ErrorAction SilentlyContinue).PortNumber
    UsingSSL = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup" -Name UsingSSL -ErrorAction SilentlyContinue).UsingSSL
}
$reportContent += "5. WSUS CONFIGURATION:"
$reportContent += "   Content Directory: $($wsusConfig.ContentDir)"
$reportContent += "   Database Server: $($wsusConfig.DatabaseServer)"
$reportContent += "   Database Name: $($wsusConfig.DatabaseName)"
$reportContent += "   Port Number: $($wsusConfig.PortNumber)"
$reportContent += "   Using SSL: $($wsusConfig.UsingSSL)"
$reportContent += ""

# 6. Document current WSUS sync status (if API accessible)
Write-Host "  [6/8] Attempting to capture sync history..." -ForegroundColor Yellow
try {
    $useSSL = $wsusConfig.UsingSSL -eq 1
    $port = if ($useSSL) { 8531 } else { 8530 }
    $wsus = [Microsoft.UpdateServices.Administration.AdminProxy]::GetUpdateServer('localhost', $useSSL, $port)
    $syncHistory = $wsus.GetSubscription().GetSynchronizationHistory() | Select-Object -First 5
    $reportContent += "6. WSUS API AND SYNC STATUS:"
    $reportContent += "   API Access: SUCCESS ✓"
    $reportContent += "   SSL Mode: $useSSL (Port: $port)"
    $reportContent += "   Sync History (Last 5):"
    foreach ($sync in $syncHistory) {
        $reportContent += "   - $($sync.StartTime): $($sync.State)"
    }
    $reportContent += ""
} catch {
    $reportContent += "6. WSUS API AND SYNC STATUS:"
    $reportContent += "   API Access: FAILED ✗"
    $reportContent += "   Error: $($_.Exception.Message)"
    $reportContent += ""
}

# 7. Get-Service attempt
Write-Host "  [7/8] Testing Get-Service cmdlet..." -ForegroundColor Yellow
try {
    $svc = Get-Service WSUSService -ErrorAction Stop
    $reportContent += "7. POWERSHELL SERVICE QUERY:"
    $reportContent += "   Service Found: YES ✓"
    $reportContent += "   Status: $($svc.Status)"
    $reportContent += "   Start Type: $($svc.StartType)"
    $reportContent += ""
} catch {
    $reportContent += "7. POWERSHELL SERVICE QUERY:"
    $reportContent += "   Service Found: NO ✗"
    $reportContent += "   Error: $($_.Exception.Message)"
    $reportContent += ""
}

# 8. Capture IIS configuration
Write-Host "  [8/8] Capturing IIS configuration..." -ForegroundColor Yellow
Import-Module WebAdministration -ErrorAction SilentlyContinue
if (Get-Module WebAdministration) {
    $wsusSites = Get-Website | Where-Object { $_.Name -like "*WSUS*" }
    $reportContent += "8. IIS CONFIGURATION:"
    if ($wsusSites) {
        $reportContent += "   WSUS Websites Found:"
        foreach ($site in $wsusSites) {
            $reportContent += "   - Site: $($site.Name), Status: $($site.State)"
        }
    } else {
        $reportContent += "   WSUS Websites Found: NONE"
    }
    
    $wsusBindings = Get-WebBinding -Name "WSUS Administration" -ErrorAction SilentlyContinue
    if ($wsusBindings) {
        $reportContent += "   WSUS Bindings:"
        foreach ($binding in $wsusBindings) {
            $reportContent += "   - Protocol: $($binding.protocol), Binding Info: $($binding.bindingInformation)"
        }
    } else {
        $reportContent += "   WSUS Bindings: NONE"
    }
} else {
    $reportContent += "8. IIS CONFIGURATION:"
    $reportContent += "   WebAdministration module: NOT AVAILABLE"
}
$reportContent += ""

# Summary and layman categorization of errors
$reportContent += "9. SUMMARY AND ERROR CATEGORIZATION:"
$reportContent += "   Server: $hostname"
$reportContent += "   Assessment Time: $(Get-Date)"
$reportContent += ""

$processRunning = $null -ne (Get-Process WsusService -ErrorAction SilentlyContinue)
$serviceInSCM = $scResult -match "RUNNING|STOPPED"
$getServiceWorks = $null -ne (Get-Service WSUSService -ErrorAction SilentlyContinue)

$reportContent += "   LAYMAN ERROR CATEGORIES:"

if (-not $processRunning) {
    $reportContent += "   - CRITICAL: WSUS process is not running"
} else {
    $reportContent += "   - OK: WSUS process is running"
}

if (-not $serviceInSCM) {
    $reportContent += "   - CRITICAL: WSUS service is not registered in Service Control Manager"
} else {
    $reportContent += "   - OK: WSUS service is registered in Service Control Manager"
}

if (-not $getServiceWorks) {
    $reportContent += "   - CRITICAL: PowerShell cannot access WSUS service (service not registered)"
} else {
    $reportContent += "   - OK: PowerShell can access WSUS service"
}

if ($wsusConfig.UsingSSL -eq 0 -and $wsusConfig.PortNumber -eq 8531) {
    $reportContent += "   - ERROR: SSL configuration mismatch (UsingSSL=0 but Port=8531)"
} elseif ($wsusConfig.UsingSSL -eq 1 -and $wsusConfig.PortNumber -eq 8530) {
    $reportContent += "   - WARNING: SSL configuration mismatch (UsingSSL=1 but Port=8530)"
} else {
    $reportContent += "   - OK: SSL configuration is consistent"
}

$reportContent += ""
$reportContent += "=" * 80
$reportContent += "END OF REPORT"
$reportContent += "=" * 80

# Write the report to file
$reportContent | Out-File -FilePath $outputFile -Encoding UTF8

# Summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Assessment complete. Report saved to:" -ForegroundColor Cyan
Write-Host "  $outputFile" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan

# Display key findings
Write-Host "Key Findings:" -ForegroundColor Yellow
Write-Host "  Process running: " -NoNewline
if ($processRunning) {
    Write-Host "YES ✓" -ForegroundColor Green
} else {
    Write-Host "NO ✗" -ForegroundColor Red
}

Write-Host " Service in SCM: " -NoNewline
if ($serviceInSCM) {
    Write-Host "YES ✓" -ForegroundColor Green
} else {
    Write-Host "NO ✗ (Access Denied or Not Found)" -ForegroundColor Red
}

Write-Host "  Get-Service works: " -NoNewline
if ($getServiceWorks) {
    Write-Host "YES ✓" -ForegroundColor Green
} else {
    Write-Host "NO ✗" -ForegroundColor Red
}

Write-Host "`nNext steps: Review output file and proceed to Phase 1 if needed.`n" -ForegroundColor Cyan

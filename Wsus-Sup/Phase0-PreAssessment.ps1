# Phase 0: Pre-Recovery Assessment
# Run this in elevated PowerShell to document current working state
# DO NOT MODIFY - This is for documentation only

Write-Host "Phase 0: Capturing current WSUS state..." -ForegroundColor Cyan

# Create output directory
$outputDir = "C:\Temp\WSUS_PreFix_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -Path $outputDir -ItemType Directory -Force | Out-Null

# 1. Capture current working process details
Write-Host "  [1/8] Capturing process details..." -ForegroundColor Yellow
Get-Process WsusService -ErrorAction SilentlyContinue | 
    Select-Object Id, StartTime, Path, CommandLine | 
    Export-Clixml "$outputDir\WsusProcess_Working.xml"

# 2. Verify current service state in registry
Write-Host "  [2/8] Capturing registry state..." -ForegroundColor Yellow
Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\WSUSService" -ErrorAction SilentlyContinue | 
    Export-Clixml "$outputDir\WSUSService_Registry_Before.xml"

# 3. Check for service in SCM database
Write-Host "  [3/8] Testing SCM query..." -ForegroundColor Yellow
sc.exe query wsusservice > "$outputDir\sc_query_before.txt" 2>&1

# 4. Export current ACLs
Write-Host "  [4/8] Capturing ACLs..." -ForegroundColor Yellow
Get-Acl "HKLM:\SYSTEM\CurrentControlSet\Services\WSUSService" -ErrorAction SilentlyContinue | 
    Export-Clixml "$outputDir\WSUSService_ACL_Before.xml"

# 5. Document WSUS configuration
Write-Host "  [5/8] Capturing WSUS configuration..." -ForegroundColor Yellow
$wsusConfig = @{
    ContentDir = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup" -Name ContentDir -ErrorAction SilentlyContinue).ContentDir
    DatabaseServer = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup" -Name SqlServerName -ErrorAction SilentlyContinue).SqlServerName
    DatabaseName = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup" -Name SqlDatabaseName -ErrorAction SilentlyContinue).SqlDatabaseName
    PortNumber = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup" -Name PortNumber -ErrorAction SilentlyContinue).PortNumber
    UsingSSL = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup" -Name UsingSSL -ErrorAction SilentlyContinue).UsingSSL
}
$wsusConfig | Export-Clixml "$outputDir\WSUS_Config_Working.xml"

# 6. Document current WSUS sync status (if API accessible)
Write-Host "  [6/8] Attempting to capture sync history..." -ForegroundColor Yellow
try {
    $wsus = [Microsoft.UpdateServices.Administration.AdminProxy]::GetUpdateServer('localhost', $false, 8530)
    $wsus.GetSubscription().GetSynchronizationHistory() | 
        Select-Object -First 5 | 
        Export-Clixml "$outputDir\WSUS_SyncHistory_Working.xml"
    Write-Host "    ✓ Sync history captured" -ForegroundColor Green
} catch {
    Write-Host "    ⚠ Could not access WSUS API: $_" -ForegroundColor Yellow
    $_.Exception | Export-Clixml "$outputDir\WSUS_API_Error.xml"
}

# 7. Get-Service attempt
Write-Host "  [7/8] Testing Get-Service cmdlet..." -ForegroundColor Yellow
try {
    Get-Service WSUSService -ErrorAction Stop | 
        Select-Object * | 
        Export-Clixml "$outputDir\GetService_Result.xml"
    Write-Host "    ✓ Get-Service succeeded (service IS registered)" -ForegroundColor Green
} catch {
    Write-Host "    ✗ Get-Service failed (service NOT registered)" -ForegroundColor Red
    $_.Exception.Message | Out-File "$outputDir\GetService_Error.txt"
}

# 8. Capture IIS configuration
Write-Host "  [8/8] Capturing IIS configuration..." -ForegroundColor Yellow
Import-Module WebAdministration -ErrorAction SilentlyContinue
if (Get-Module WebAdministration) {
    Get-Website | Where-Object { $_.Name -like "*WSUS*" } | 
        Select-Object * | 
        Export-Clixml "$outputDir\IIS_WSUS_Sites.xml"
    Get-WebBinding -Name "WSUS Administration" -ErrorAction SilentlyContinue | 
        Export-Clixml "$outputDir\IIS_WSUS_Bindings.xml"
}

# Summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Assessment complete. Files saved to:" -ForegroundColor Cyan
Write-Host "  $outputDir" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan

# Display key findings
Write-Host "Key Findings:" -ForegroundColor Yellow
Write-Host "  Process running: " -NoNewline
if (Get-Process WsusService -ErrorAction SilentlyContinue) {
    Write-Host "YES ✓" -ForegroundColor Green
} else {
    Write-Host "NO ✗" -ForegroundColor Red
}

Write-Host "  Service in SCM: " -NoNewline
$scResult = sc.exe query wsusservice 2>&1
if ($scResult -match "RUNNING|STOPPED") {
    Write-Host "YES ✓" -ForegroundColor Green
} else {
    Write-Host "NO ✗ (Access Denied or Not Found)" -ForegroundColor Red
}

Write-Host "  Get-Service works: " -NoNewline
if (Get-Service WSUSService -ErrorAction SilentlyContinue) {
    Write-Host "YES ✓" -ForegroundColor Green
} else {
    Write-Host "NO ✗" -ForegroundColor Red
}

Write-Host "`nNext steps: Review output files and proceed to Phase 1 if needed.`n" -ForegroundColor Cyan

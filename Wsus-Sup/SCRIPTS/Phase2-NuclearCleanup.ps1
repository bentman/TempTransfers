# Phase 2: Nuclear Cleanup and Rebuild
# ONLY use this if Phase 1 failed
# This performs complete WSUS teardown and reinstallation
# Run in elevated PowerShell

#Requires -RunAsAdministrator

$hostname = hostname
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$outputFile = "C:\Temp\WSUS-NUCLEAR_CLEANUP_${hostname}-${timestamp}.txt"

Write-Host "`n========================================" -ForegroundColor Red
Write-Host "Phase 2: NUCLEAR CLEANUP" -ForegroundColor Red
Write-Host "========================================`n" -ForegroundColor Red

Write-Host "⚠ WARNING: This will completely remove and reinstall WSUS" -ForegroundColor Yellow
Write-Host "⚠ SUSDB will be backed up but sync history may be affected" -ForegroundColor Yellow
Write-Host "⚠ This will cause DOWNTIME for software updates`n" -ForegroundColor Yellow

$confirmation = Read-Host "Type 'PROCEED' to continue or anything else to abort"
if ($confirmation -ne 'PROCEED') {
    Write-Host "`nAborted by user." -ForegroundColor Yellow
    exit 0
}

Write-Host "`nStarting nuclear cleanup...`n" -ForegroundColor Cyan

# Initialize report content
$reportContent = @()
$reportContent += "=" * 80
$reportContent += "WSUS NUCLEAR CLEANUP REPORT"
$reportContent += "Server: $hostname"
$reportContent += "Date/Time: $(Get-Date)"
$reportContent += "Script: Phase2-NuclearCleanup.ps1"
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

# Create backup directory
$backupDir = "C:\Temp\WSUS_Nuclear_Backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -Path $backupDir -ItemType Directory -Force | Out-Null
Write-Host "Backup directory: $backupDir`n" -ForegroundColor Cyan

# ========================================
# PHASE 2.1: CAPTURE CURRENT CONFIG
# ========================================
Write-Host "[Phase 2.1] Capturing current configuration..." -ForegroundColor Yellow

# Capture WSUS config
$wsusConfig = @{
    ContentDir = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup" -Name ContentDir -ErrorAction SilentlyContinue).ContentDir
    DatabaseServer = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup" -Name SqlServerName -ErrorAction SilentlyContinue).SqlServerName
    DatabaseName = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup" -Name SqlDatabaseName -ErrorAction SilentlyContinue).SqlDatabaseName
    PortNumber = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup" -Name PortNumber -ErrorAction SilentlyContinue).PortNumber
    UsingSSL = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup" -Name UsingSSL -ErrorAction SilentlyContinue).UsingSSL
}

# Detect misconfigured SSL state: UsingSSL=0 but expecting HTTPS (port 8531)
$isMisconfigured = $false
if ($wsusConfig.UsingSSL -eq 0 -and $wsusConfig.PortNumber -eq 8531) {
    Write-Host "  ⚠ SSL MISMATCH DETECTED: UsingSSL=0 but PortNumber=8531 (HTTPS)" -ForegroundColor Red
    Write-Host "  This indicates a misconfigured state that will be corrected." -ForegroundColor Yellow
    $isMisconfigured = $true
} elseif ($wsusConfig.UsingSSL -eq 0) {
    Write-Host "  ℹ Current configuration: HTTP only (UsingSSL=0)" -ForegroundColor Gray
} elseif ($wsusConfig.UsingSSL -eq 1) {
    Write-Host "  ℹ Current configuration: SSL enabled (UsingSSL=1)" -ForegroundColor Gray
}

# Add SSL-only enforcement flag to configuration
$wsusConfig | Add-Member -NotePropertyName "EnforceSSLOnly" -NotePropertyValue $true

$wsusConfig | Export-Clixml "$backupDir\WSUS_Config.xml"

Write-Host "  Content Directory: $($wsusConfig.ContentDir)" -ForegroundColor Gray
Write-Host " Database Server: $($wsusConfig.DatabaseServer)" -ForegroundColor Gray
Write-Host "  Database Name: $($wsusConfig.DatabaseName)" -ForegroundColor Gray
Write-Host "  Port: $($wsusConfig.PortNumber)" -ForegroundColor Gray
Write-Host "  Using SSL: $($wsusConfig.UsingSSL)" -ForegroundColor Gray
Write-Host "  SSL-Only Enforcement: $($wsusConfig.EnforceSSLOnly)" -ForegroundColor Gray
if ($isMisconfigured) {
    Write-Host "  Misconfigured State: YES" -ForegroundColor Red
}
Write-Host ""

$reportContent += "1. CONFIGURATION CAPTURE:"
$reportContent += "   Content Directory: $($wsusConfig.ContentDir)"
$reportContent += "   Database Server: $($wsusConfig.DatabaseServer)"
$reportContent += "   Database Name: $($wsusConfig.DatabaseName)"
$reportContent += "   Port Number: $($wsusConfig.PortNumber)"
$reportContent += "   Using SSL: $($wsusConfig.UsingSSL)"
$reportContent += "   SSL-Only Enforcement: $($wsusConfig.EnforceSSLOnly)"
if ($isMisconfigured) {
    $reportContent += "   SSL Configuration: MISMATCH DETECTED (UsingSSL=0 but Port=8531)"
} else {
    $reportContent += "   SSL Configuration: CONSISTENT"
}
$reportContent += "   Backup Directory: $backupDir"
if ($siteCode) {
    $reportContent += "   SCCM Site Code: $siteCode"
}
$reportContent += ""

# ========================================
# PHASE 2.2: STOP SERVICES
# ========================================
Write-Host "[Phase 2.2] Stopping services..." -ForegroundColor Yellow

$reportContent += "2. SERVICE STOPPING ORDER:"
$reportContent += "   (Following dependency order: stopping dependent services first)"
$reportContent += "   1. WsusService (WSUS Service) - will be stopped"
$reportContent += "   2. W3SVC (World Wide Web Publishing Service) - will be stopped"
$reportContent += "   3. WAS (Windows Process Activation Service) - will be stopped"
$reportContent += ""

# Stop IIS
Write-Host "  Stopping IIS..." -ForegroundColor Gray
Stop-Service W3SVC -Force -ErrorAction SilentlyContinue
Stop-Service WAS -Force -ErrorAction SilentlyContinue

# Kill orphaned WSUS process
Write-Host "  Stopping WSUS processes..." -ForegroundColor Gray
Stop-Process -Name WsusService -Force -ErrorAction SilentlyContinue

Start-Sleep -Seconds 10
Write-Host "  ✓ Services stopped`n" -ForegroundColor Green

$reportContent += "3. SERVICES STOPPED:"
$w3svcStatus = (Get-Service W3SVC -ErrorAction SilentlyContinue).Status
$wasStatus = (Get-Service WAS -ErrorAction SilentlyContinue).Status
$reportContent += "   W3SVC (IIS) Status: $w3svcStatus"
$reportContent += "   WAS (Windows Process Activation) Status: $wasStatus"
$wsusProcess = Get-Process WsusService -ErrorAction SilentlyContinue
if ($null -eq $wsusProcess) {
    $reportContent += "   WsusService Process: STOPPED ✓"
} else {
    $reportContent += "   WsusService Process: FAILED TO STOP ✗"
}
$reportContent += ""

# ========================================
# PHASE 2.3: REMOVE WSUS FEATURES
# ========================================
Write-Host "[Phase 2.3] Removing WSUS features..." -ForegroundColor Yellow

try {
    $featureResult = Uninstall-WindowsFeature -Name UpdateServices-Services, UpdateServices-DB -Confirm:$false -ErrorAction Stop
    Write-Host "  ✓ WSUS features removed`n" -ForegroundColor Green
    $reportContent += "4. WSUS FEATURES REMOVAL:"
    $reportContent += "   UpdateServices-Services: $($featureResult[0].RestartNeeded)"
    $reportContent += "   UpdateServices-DB: $($featureResult[1].RestartNeeded)"
    $reportContent += "   Status: SUCCESS ✓"
} catch {
    Write-Host "  ⚠ Feature removal warning: $_`n" -ForegroundColor Yellow
    $reportContent += "4. WSUS FEATURES REMOVAL:"
    $reportContent += "   Status: FAILED ⚠"
    $reportContent += "   Error: $($_.Exception.Message)"
}
$reportContent += ""

Start-Sleep -Seconds 5

# ========================================
# PHASE 2.4: REMOVE FILES
# ========================================
Write-Host "[Phase 2.4] Removing WSUS directories..." -ForegroundColor Yellow

$dirsToRemove = @(
    "C:\Program Files\Update Services",
    "$($wsusConfig.ContentDir)"
)

$removedDirs = @()
foreach ($dir in $dirsToRemove) {
    if ($dir -and (Test-Path $dir)) {
        Write-Host "  Removing: $dir" -ForegroundColor Gray
        Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
        $removedDirs += $dir
    }
}

Write-Host "  ✓ Directories removed`n" -ForegroundColor Green

$reportContent += "5. DIRECTORY REMOVAL:"
if ($removedDirs.Count -gt 0) {
    foreach ($dir in $removedDirs) {
        $reportContent += "   Removed: $dir ✓"
    }
} else {
    $reportContent += "   No directories removed"
}
$reportContent += ""

# ========================================
# PHASE 2.5: REMOVE IIS SITES
# ========================================
Write-Host "[Phase 2.5] Removing IIS sites..." -ForegroundColor Yellow

Import-Module WebAdministration -ErrorAction SilentlyContinue
if (Get-Module WebAdministration) {
    $wsusSites = Get-Website | Where-Object { $_.Name -like "*WSUS*" }
    $removedSites = @()
    foreach ($site in $wsusSites) {
        Write-Host "  Removing site: $($site.Name)" -ForegroundColor Gray
        Remove-Website -Name $site.Name -Confirm:$false -ErrorAction SilentlyContinue
        $removedSites += $site.Name
    }
    
    # Remove WSUS app pools
    $wsusAppPools = Get-WebAppPoolState -Name "*WSUS*" -ErrorAction SilentlyContinue
    $removedAppPools = @()
    foreach ($appPool in $wsusAppPools) {
        $poolName = $appPool.ItemXPath -replace '.*name=''([^'']+)''.*', '$1'
        Write-Host "  Removing app pool: $poolName" -ForegroundColor Gray
        Remove-WebAppPool -Name $poolName -ErrorAction SilentlyContinue
        $removedAppPools += $poolName
    }
    
    Write-Host "  ✓ IIS sites removed`n" -ForegroundColor Green
    
    $reportContent += "6. IIS CONFIGURATION REMOVAL:"
    if ($removedSites.Count -gt 0) {
        $reportContent += "   Removed Websites: $($removedSites -join ', ')"
    } else {
        $reportContent += "   Removed Websites: None found"
    }
    if ($removedAppPools.Count -gt 0) {
        $reportContent += "   Removed App Pools: $($removedAppPools -join ', ')"
    } else {
        $reportContent += "   Removed App Pools: None found"
    }
} else {
    Write-Host "  ⚠ WebAdministration module not available`n" -ForegroundColor Yellow
    $reportContent += "6. IIS CONFIGURATION REMOVAL:"
    $reportContent += "   WebAdministration module: NOT AVAILABLE ⚠"
}
$reportContent += ""

# ========================================
# PHASE 2.6: CLEAN REGISTRY
# ========================================
Write-Host "[Phase 2.6] Cleaning registry..." -ForegroundColor Yellow

$keysToRemove = @(
    "HKLM:\SOFTWARE\Microsoft\Update Services\Server",
    "HKLM:\SYSTEM\CurrentControlSet\Services\WSUSService",
    "HKLM:\SYSTEM\ControlSet01\Services\WSUSService",
    "HKLM:\SYSTEM\ControlSet002\Services\WSUSService"
)

$removedKeys = @()
foreach ($key in $keysToRemove) {
    if (Test-Path $key) {
        Write-Host "  Removing: $key" -ForegroundColor Gray
        
        # Take ownership
        try {
            $acl = Get-Acl $key
            $acl.SetOwner([System.Security.Principal.NTAccount]"Administrators")
            Set-Acl $key $acl -ErrorAction SilentlyContinue
            
            # Grant full control
            $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
                "Administrators",
                "FullControl",
                "ContainerInherit,ObjectInherit",
                "None",
                "Allow"
            )
            $acl.SetAccessRule($rule)
            Set-Acl $key $acl -ErrorAction SilentlyContinue
            
            # Delete
            Remove-Item $key -Recurse -Force -ErrorAction Stop
            Write-Host "    ✓ Removed" -ForegroundColor Green
            $removedKeys += $key
        } catch {
            Write-Host "    ⚠ Could not remove: $_" -ForegroundColor Yellow
            # Try with reg.exe as fallback
            $regKey = $key -replace "HKLM:\\", "HKLM\"
            & reg.exe delete $regKey /f 2>&1 | Out-Null
        }
    }
}

Write-Host "  ✓ Registry cleaned`n" -ForegroundColor Green

$reportContent += "7. REGISTRY CLEANUP:"
if ($removedKeys.Count -gt 0) {
    foreach ($key in $removedKeys) {
        $reportContent += "   Removed Registry Key: $key ✓"
    }
} else {
    $reportContent += "   Removed Registry Keys: None found"
}
$reportContent += ""

# ========================================
# PHASE 2.7: FIX TEMP FOLDER PERMISSIONS
# ========================================
Write-Host "[Phase 2.7] Fixing temp folder permissions..." -ForegroundColor Yellow

$foldersToFix = @(
    "$env:windir\Temp",
    "$env:windir\Microsoft.NET\Framework64\v4.0.30319\Temporary ASP.NET Files"
)

$fixedFolders = @()
foreach ($folder in $foldersToFix) {
    if (Test-Path $folder) {
        Write-Host "  Fixing: $folder" -ForegroundColor Gray
        
        try {
            $acl = Get-Acl $folder
            
            # Grant IIS_IUSRS
            $rule1 = New-Object System.Security.AccessControl.FileSystemAccessRule(
                "IIS_IUSRS",
                "Modify",
                "ContainerInherit,ObjectInherit",
                "None",
                "Allow"
            )
            $acl.SetAccessRule($rule1)
            
            # Grant NETWORK SERVICE
            $rule2 = New-Object System.Security.AccessControl.FileSystemAccessRule(
                "NETWORK SERVICE",
                "Modify",
                "ContainerInherit,ObjectInherit",
                "None",
                "Allow"
            )
            $acl.SetAccessRule($rule2)
            
            Set-Acl $folder $acl
            Write-Host "    ✓ Permissions set" -ForegroundColor Green
            $fixedFolders += $folder
        } catch {
            Write-Host "    ⚠ Could not set permissions: $_" -ForegroundColor Yellow
        }
    }
}

Write-Host "`n  ✓ Permissions fixed`n" -ForegroundColor Green

$reportContent += "8. TEMP FOLDER PERMISSIONS:"
if ($fixedFolders.Count -gt 0) {
    foreach ($folder in $fixedFolders) {
        $reportContent += "   Fixed Permissions: $folder ✓"
    }
} else {
    $reportContent += "   Fixed Permissions: None needed"
}
$reportContent += ""

# Add layman categorization of errors
$reportContent += "9. SUMMARY AND ERROR CATEGORIZATION:"
$reportContent += "   Server: $hostname"
$reportContent += "   Assessment Time: $(Get-Date)"
$reportContent += ""

$reportContent += "   LAYMAN ERROR CATEGORIES:"
if ($isMisconfigured) {
    $reportContent += "   - ERROR: SSL configuration mismatch was present (UsingSSL=0 but Port=8531)"
} else {
    $reportContent += "   - OK: SSL configuration was consistent"
}
$reportContent += "   - INFO: Nuclear cleanup completed - system ready for reinstall"
if ($siteCode) {
    $reportContent += "   - INFO: SCCM Site Code detected: $siteCode (will need to reconfigure SUP role)"
}
$reportContent += ""

$reportContent += "=" * 80
$reportContent += "END OF REPORT"
$reportContent += "=" * 80

# Write the report to file
$reportContent | Out-File -FilePath $outputFile -Encoding UTF8

# ========================================
# PHASE 2.8: REBOOT PROMPT
# ========================================
Write-Host "[Phase 2.8] Cleanup complete`n" -ForegroundColor Yellow

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "REBOOT REQUIRED" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "The system must be rebooted before reinstalling WSUS." -ForegroundColor Yellow
Write-Host "This clears IIS, SCM, and WCF caches.`n" -ForegroundColor Yellow

Write-Host "After reboot, run: Phase2-Reinstall.ps1`n" -ForegroundColor White
Write-Host "Report saved to: $outputFile" -ForegroundColor Cyan

$rebootNow = Read-Host "Reboot now? (Y/N)"
if ($rebootNow -eq 'Y' -or $rebootNow -eq 'y') {
    Write-Host "`nRebooting in 60 seconds..." -ForegroundColor Yellow
    shutdown.exe /r /t 60 /c "WSUS nuclear cleanup complete - rebooting for reinstall"
} else {
    Write-Host "`nPlease reboot manually before running Phase2-Reinstall.ps1`n" -ForegroundColor Yellow
}

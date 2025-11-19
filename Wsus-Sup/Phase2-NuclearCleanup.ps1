# Phase 2: Nuclear Cleanup and Rebuild
# ONLY use this if Phase 1 failed
# This performs complete WSUS teardown and reinstallation
# Run in elevated PowerShell

#Requires -RunAsAdministrator

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
Write-Host "  Database Server: $($wsusConfig.DatabaseServer)" -ForegroundColor Gray
Write-Host "  Database Name: $($wsusConfig.DatabaseName)" -ForegroundColor Gray
Write-Host "  Port: $($wsusConfig.PortNumber)" -ForegroundColor Gray
Write-Host "  Using SSL: $($wsusConfig.UsingSSL)" -ForegroundColor Gray
Write-Host "  SSL-Only Enforcement: $($wsusConfig.EnforceSSLOnly)" -ForegroundColor Gray
if ($isMisconfigured) {
    Write-Host "  Misconfigured State: YES" -ForegroundColor Red
}
Write-Host ""

# ========================================
# PHASE 2.2: STOP SERVICES
# ========================================
Write-Host "[Phase 2.2] Stopping services..." -ForegroundColor Yellow

# Stop IIS
Write-Host "  Stopping IIS..." -ForegroundColor Gray
Stop-Service W3SVC -Force -ErrorAction SilentlyContinue
Stop-Service WAS -Force -ErrorAction SilentlyContinue

# Kill orphaned WSUS process
Write-Host "  Stopping WSUS processes..." -ForegroundColor Gray
Stop-Process -Name WsusService -Force -ErrorAction SilentlyContinue

Start-Sleep -Seconds 10
Write-Host "  ✓ Services stopped`n" -ForegroundColor Green

# ========================================
# PHASE 2.3: REMOVE WSUS FEATURES
# ========================================
Write-Host "[Phase 2.3] Removing WSUS features..." -ForegroundColor Yellow

try {
    Uninstall-WindowsFeature -Name UpdateServices-Services, UpdateServices-DB -Confirm:$false -ErrorAction Stop | Out-Null
    Write-Host "  ✓ WSUS features removed`n" -ForegroundColor Green
} catch {
    Write-Host "  ⚠ Feature removal warning: $_`n" -ForegroundColor Yellow
}

Start-Sleep -Seconds 5

# ========================================
# PHASE 2.4: REMOVE FILES
# ========================================
Write-Host "[Phase 2.4] Removing WSUS directories..." -ForegroundColor Yellow

$dirsToRemove = @(
    "C:\Program Files\Update Services",
    "$($wsusConfig.ContentDir)"
)

foreach ($dir in $dirsToRemove) {
    if ($dir -and (Test-Path $dir)) {
        Write-Host "  Removing: $dir" -ForegroundColor Gray
        Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "  ✓ Directories removed`n" -ForegroundColor Green

# ========================================
# PHASE 2.5: REMOVE IIS SITES
# ========================================
Write-Host "[Phase 2.5] Removing IIS sites..." -ForegroundColor Yellow

Import-Module WebAdministration -ErrorAction SilentlyContinue
if (Get-Module WebAdministration) {
    Get-Website | Where-Object { $_.Name -like "*WSUS*" } | ForEach-Object {
        Write-Host "  Removing site: $($_.Name)" -ForegroundColor Gray
        Remove-Website -Name $_.Name -Confirm:$false -ErrorAction SilentlyContinue
    }
    
    # Remove WSUS app pools
    Get-WebAppPoolState -Name "*WSUS*" -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "  Removing app pool: $($_.ItemXPath)" -ForegroundColor Gray
        Remove-WebAppPool -Name ($_.ItemXPath -replace '.*name=''([^'']+)''.*', '$1') -ErrorAction SilentlyContinue
    }
    
    Write-Host "  ✓ IIS sites removed`n" -ForegroundColor Green
} else {
    Write-Host "  ⚠ WebAdministration module not available`n" -ForegroundColor Yellow
}

# ========================================
# PHASE 2.6: CLEAN REGISTRY
# ========================================
Write-Host "[Phase 2.6] Cleaning registry..." -ForegroundColor Yellow

$keysToRemove = @(
    "HKLM:\SOFTWARE\Microsoft\Update Services\Server",
    "HKLM:\SYSTEM\CurrentControlSet\Services\WSUSService",
    "HKLM:\SYSTEM\ControlSet001\Services\WSUSService",
    "HKLM:\SYSTEM\ControlSet002\Services\WSUSService"
)

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
        } catch {
            Write-Host "    ⚠ Could not remove: $_" -ForegroundColor Yellow
            # Try with reg.exe as fallback
            $regKey = $key -replace "HKLM:\\", "HKLM\"
            & reg.exe delete $regKey /f 2>&1 | Out-Null
        }
    }
}

Write-Host "  ✓ Registry cleaned`n" -ForegroundColor Green

# ========================================
# PHASE 2.7: FIX TEMP FOLDER PERMISSIONS
# ========================================
Write-Host "[Phase 2.7] Fixing temp folder permissions..." -ForegroundColor Yellow

$foldersToFix = @(
    "$env:windir\Temp",
    "$env:windir\Microsoft.NET\Framework64\v4.0.30319\Temporary ASP.NET Files"
)

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
        } catch {
            Write-Host "    ⚠ Could not set permissions: $_" -ForegroundColor Yellow
        }
    }
}

Write-Host "`n  ✓ Permissions fixed`n" -ForegroundColor Green

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

$rebootNow = Read-Host "Reboot now? (Y/N)"
if ($rebootNow -eq 'Y' -or $rebootNow -eq 'y') {
    Write-Host "`nRebooting in 60 seconds..." -ForegroundColor Yellow
    shutdown.exe /r /t 60 /c "WSUS nuclear cleanup complete - rebooting for reinstall"
} else {
    Write-Host "`nPlease reboot manually before running Phase2-Reinstall.ps1`n" -ForegroundColor Yellow
}

# WSUS Service Scripts - Implementation Examples

## Overview

This directory contains PowerShell scripts that serve as examples for implementing the WSUS service repair solution. These scripts should be reviewed and customized for your specific environment before implementation.

## Important Notes

- **Examples Only**: These scripts demonstrate the solution approach but require customization for your environment
- **Test First**: Always test in a non-production environment before implementing
- **Review Code**: Examine each script before running to understand what changes will be made
- **Backup**: Ensure proper backups before running any scripts that modify system services
- **Elevated Privileges**: All scripts require administrative privileges to run properly

## WSUS Cleanup Examples

For additional examples of WSUS optimization and cleanup scripts, see these community resources that demonstrate similar approaches to resolving WSUS service issues:

- [Optimize-WsusServer](https://github.com/awarre/Optimize-WsusServer) - A collection of functions to optimize WSUS server performance and clean up various WSUS-related issues
- [WSUS-Cleanup.ps1](https://github.com/samersultan/wsus-cleanup/blob/master/WSUS-Cleanup.ps1) - A comprehensive WSUS cleanup script that addresses various WSUS-related problems including database cleanup and service optimization

### Reference Script Examples

### Phase0-PreAssessment.ps1
**Purpose**: Example script to capture current WSUS state before making changes

This script demonstrates how to:
- Capture process details and registry state
- Document WSUS configuration (ports, SSL, paths, DB)
- Test service visibility in SCM
- Save sync history if API accessible
- Generate human-readable reports

**Customization needed**:
- Adjust output directory paths to match your environment
- Modify registry paths if your WSUS is installed differently

### Phase1-InPlaceRepair.ps1
**Purpose**: Example script for fixing service registration without full reinstall

This script demonstrates how to:
- Fix ACLs on service registry key (takeown + icacls)
- Stop orphaned WsusService.exe process
- Delete corrupt service registration (`sc delete`)
- Recreate service with proper configuration (`sc create`)
- Set correct dependencies and security descriptors
- Start service and validate

**Customization needed**:
- Verify service paths match your environment
- Adjust service account if using custom account
- Modify dependencies if your setup differs

### Phase2-NuclearCleanup.ps1
**Purpose**: Example script for complete teardown approach

This script demonstrates how to:
- Capture current configuration for restoration
- Stop IIS and all WSUS processes
- Uninstall WSUS Windows Features
- Remove all WSUS directories and registry keys
- Fix temp folder permissions
- Generate cleanup reports

**Customization needed**:
- Adjust paths for your content directory
- Verify registry keys to be deleted match your environment
- Modify SQL configuration if using remote database

### Phase2-Reinstall.ps1
**Purpose**: Example script for WSUS reinstallation

This script demonstrates how to:
- Reinstall WSUS Windows Features
- Create content directory
- Run `wsusutil postinstall` with proper configuration
- Verify service registration
- Generate validation reports

**Customization needed**:
- Set appropriate content directory path
- Configure SSL settings according to your requirements
- Adjust port configuration if using non-standard ports

## Implementation Guidelines

### Before Running Scripts
1. **Understand the Script**: Read through the entire script to understand what changes will be made
2. **Test Environment**: Always test in a non-production environment first
3. **Backups**: Ensure you have recent backups before running any scripts
4. **Permissions**: Run with administrative privileges in elevated PowerShell

### Customization Process
1. **Environment Variables**: Update any hardcoded paths, server names, or configuration settings
2. **Logging**: Adjust logging paths to match your environment's standards
3. **Validation**: Modify validation checks to match your requirements
4. **Error Handling**: Add additional error handling as needed for your environment

### After Running Scripts
1. **Validation**: Verify the service is properly registered and functional
2. **Monitoring**: Monitor for 24-48 hours to ensure stability
3. **Reboot Test**: Test with a reboot during a maintenance window
4. **Documentation**: Document any customizations made for future reference

## Common Modifications

### Path Changes
Many environments have custom installation paths that need to be adjusted:

```powershell
# Default path (may need adjustment)
$wsusContentPath = "C:\WSUS"

# Custom path example
$wsusContentPath = "E:\UpdateServices\WSUS"
```

### Service Configuration
Different environments may require different service configurations:

```powershell
# Default service account
$serviceAccount = "NETWORK SERVICE"

# Custom service account example
$serviceAccount = "DOMAIN\CustomServiceAccount"
```

### Port Configuration
Some environments use different ports:

```powershell
# Default ports
$httpPort = 8530
$httpsPort = 8531

# Custom ports example
$httpPort = 8080
$httpsPort = 8443
```

## Validation Examples

After running any script, validate the results:

```powershell
# Check service registration
Get-Service WSUSService

# Verify service status
sc query WSUSService

# Test service management
Restart-Service WSUSService

# Check ports
Test-NetConnection -ComputerName localhost -Port 8530
Test-NetConnection -ComputerName localhost -Port 8531
```

## Troubleshooting Common Issues

### Access Denied Errors
If you encounter access denied errors after running the scripts:

```cmd
# Reset service security descriptor (example command)
sc sdset WSUSService D:(A;;CCLCSWRPWPDTLOCRRC;;;BA)(A;;CCLCSWRPWPDTLOCRRC;;;SY)
```

### Service Won't Start
If the service won't start after running the repair script:

1. Check Event Viewer for specific error messages
2. Verify that IIS is running
3. Confirm that required dependencies are started
4. Check that the content directory has proper permissions

### Certificate Issues Persist
If certificate issues continue after cleanup:

1. Verify that the problematic GPO has been disabled
2. Check that certificates were properly removed from certificate stores
3. Consider running `gpupdate /force` to ensure Group Policy changes are applied

## Resource Links

For additional information about WSUS service management:

- [Microsoft WSUS Documentation](https://docs.microsoft.com/en-us/windows-server/administration/windows-server-update-services/)
- [Service Control Manager Overview](https://docs.microsoft.com/en-us/windows/win32/services/service-control-manager)
- [WSUS Troubleshooting Guide](https://docs.microsoft.com/en-us/troubleshoot/mem/configmgr/update-management/troubleshoot-software-update-synchronization)

---

*These scripts serve as examples and should be customized for your specific environment before implementation.*

# WSUS Service Control Manager Corruption - Technical Guidance

## Problem Overview

The WSUS service process (WsusService.exe) is running as an orphaned process but is not properly registered with the Windows Service Control Manager (SCM). This creates an unstable state where WSUS appears to function but will fail completely on the next reboot. The root cause has been traced to expired certificates deployed via Group Policy from an abandoned Patch My PC Cloud deployment attempt.

## Key Technical Details

### Symptoms
- `WsusService.exe` process running but not registered with SCM
- `Get-Service WSUSService` returns "ServiceNotFoundException"
- `sc query wsusservice` returns "Access Denied" 
- WSUS console may still open but service is not manageable
- Port 8530/8531 may still respond to requests
- Service will not auto-start after reboot

### Root Cause Analysis
- Expired GPO-deployed certificates named "PatchMyPC" and "WSUS" are causing validation conflicts
- These certificates were part of an abandoned Patch My PC Cloud deployment
- Certificate validation failures are preventing proper service registration
- Group Policy continues to reapply expired certificates on every reboot

## Resolution Strategy

### Phase 0: Assessment
Before making any changes, run the assessment script to capture current state:

```powershell
# Run as Administrator in elevated PowerShell
.\SCRIPTS\Phase0-PreAssessment.ps1
```

This script will:
- Document current process state
- Capture registry configuration
- Test service visibility in SCM
- Generate a human-readable report

### Phase 1: Certificate Cleanup (Critical First Step)
Locate and disable the GPO deploying expired certificates:

1. Check for certificates in the Local Machine store:
```powershell
Get-ChildItem Cert:\LocalMachine\Root | Where-Object {$_.Subject -like "*PatchMyPC*" -or $_.Subject -like "*WSUS*"}
Get-ChildItem Cert:\LocalMachine\TrustedPublisher | Where-Object {$_.Subject -like "*PatchMyPC*" -or $_.Subject -like "*WSUS*"}
```

2. Remove expired certificates:
```powershell
# Remove expired certificates (adjust thumbprints as needed)
Get-ChildItem Cert:\LocalMachine\Root | Where-Object {$_.Subject -like "*PatchMyPC*" -and $_.NotAfter -lt (Get-Date)} | Remove-Item
Get-ChildItem Cert:\LocalMachine\TrustedPublisher | Where-Object {$_.Subject -like "*PatchMyPC*" -and $_.NotAfter -lt (Get-Date)} | Remove-Item
```

3. Locate the GPO that deployed these certificates and disable it to prevent re-deployment on next Group Policy update.

### Phase 2: Service Repair
After certificate cleanup, attempt service repair:

```powershell
# Run as Administrator
.\SCRIPTS\Phase1-InPlaceRepair.ps1
```

This script will:
- Fix ACLs on service registry key (takeown + icacls)
- Stop orphaned WsusService.exe process
- Delete corrupt service registration (`sc delete`)
- Recreate service with proper configuration (`sc create`)
- Set correct dependencies and security descriptors
- Start service and validate

### Phase 3: Nuclear Cleanup (Last Resort)
If Phase 2 fails, use the complete rebuild approach:

```powershell
# Phase 3A: Cleanup
.\SCRIPTS\Phase2-NuclearCleanup.ps1

# After reboot
# Phase 3B: Reinstall
.\SCRIPTS\Phase2-Reinstall.ps1
```

## Correlative Findings from Similar Cases

Based on research of similar WSUS service issues in the field:

### Service Security Descriptor Issues
Sometimes the problem extends beyond certificate issues to corrupted service security descriptors. In such cases, running the following command may help after certificate conflicts are resolved:

```cmd
sc sdset WSUSService D:(A;;CCLCSWRPWPDTLOCRRC;;;BA)(A;;CCLCSWRPWPDTLOCRRC;;;SY)
```

Where:
- `D:` indicates a Discretionary Access Control List (DACL)
- `(A;;...)` grants Allow permissions
- `CCLCSWRPWPDTLOCRRC` represents specific service access rights
- `BA` refers to Built-in Administrators group
- `SY` refers to Local System account

This command grants essential permissions including Connect to Service, Create Pipe, Lock Memory, Change Service Configuration, and Query Service Status.

### Common Service Registration Problems
Similar cases have shown that incomplete WSUS uninstallations often leave registry artifacts that prevent proper service registration. These typically manifest as "Access Denied" errors when attempting to query the service via `sc query` commands, while the process continues to run independently.

## Validation Steps

After implementing any solution:

1. Verify service registration:
   ```powershell
   Get-Service WSUSService
   sc query WSUSService
   ```

2. Test service management:
   ```powershell
   Restart-Service WSUSService
   ```

3. Confirm network connectivity:
   - Test port 8530 (HTTP) connectivity
   - Test port 8531 (HTTPS) if SSL enabled

4. Perform a reboot test during a maintenance window to ensure service survives restart

## Monitoring After Repair

- Check service status every 2 hours for first 24 hours
- Monitor WCM.log for any connection errors
- Watch Event Viewer for WSUS-related errors
- Verify SCCM SUP sync completes successfully

## When to Escalate

Contact Microsoft Support if:
- Certificate cleanup does not resolve the issue
- Service registration continues to fail after proper certificate cleanup
- Nuclear cleanup approach fails to resolve the issue
- Suspect underlying Windows Server corruption

## Additional Resources

- Microsoft's WSUS troubleshooting documentation
- Service Control Manager error codes
- Certificate deployment best practices
- Group Policy certificate management guidelines

---
*Note: This guidance is based on analysis of similar WSUS service control manager issues. Always test solutions in non-production environments first.*

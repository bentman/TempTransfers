# BIOS Update: SCCM-Primary vs Intune-Primary Comparison

## Executive Summary

For an all-Dell, co-managed fleet with Dell Command | Update (DCU) present, you can achieve a mostly-seamless user experience using either SCCM (MECM) or Intune as the primary engine. Both methods are proven in production; the choice depends on your specific requirements:

- **SCCM-Primary (MECM + Dell Business Client Update Catalog)**: Best for tight maintenance-window control, on-prem distribution points, and SUP/WSUS workflows. Leverages MECM's native software-update features (maintenance windows, deadlines, built-in restart UX). Ideal for regulated on-prem fleets.

- **Intune-Primary (Intune Driver Update Management or Intune + DCU ADMX/Proactive Remediations)**: Best for cloud reach and remote coverage. Intune Driver Update (WUfB capsules) provides native BIOS/firmware delivery; DCU via ADMX or Proactive Remediations provides parity for devices already using DCU. Preferred for distributed/off-VPN devices and modern UX (Autopatch/rings).

## Table of Contents
1. [Executive Summary](#executive-summary)
2. [SCCM-Primary Deployment Guide](#sccm-primary-deployment-guide)
3. [Intune-Primary Deployment Guide](#intune-primary-deployment-guide)
4. [Cross-Cutting Safety Requirements](#cross-cutting-safety-requirements)
5. [Troubleshooting and Best Practices](#troubleshooting-and-best-practices)
6. [References](#references)

## SCCM-Primary Deployment Guide

### Overview
Use the Dell Business Client Update Catalog as a third-party software update catalog in MECM/SCCM, publish relevant BIOS updates to your SUP, then deploy them as Software Updates using MECM maintenance windows and restart settings.

### Step-by-Step Process

1. **Subscribe to Dell Business Client Update Catalog**
   - Obtain Dell's Business Client Update Catalog and follow Dell's instructions to import it into your MECM SUP
   - Note: Re-subscribe if you require the newer V3 catalog format (V3 enables richer category filtering for firmware/BIOS)
   - Deploy the vendor signing certificate to clients' Trusted Publishers store before importing third-party updates

2. **Configure SCCM SUP/WSUS for Third-Party Catalogs**
   - Enable third-party software update catalogs in your SUP
   - For Configuration Manager 2103+, be aware of console extension behaviors

3. **Publish and Approve BIOS Updates**
   - Review Dell-catalog items and approve BIOS updates for your models
   - Publish to WSUS/SUP for device scan cycles

4. **Create and Schedule Deployments**
   - Deploy as Required/Required with deadline or Available
   - Use MECM Maintenance Windows, deadlines, and client restart settings

5. **Handle Prerequisites and Safety Steps**
   - **BitLocker**: Suspend before BIOS update and resume after reboot
   - **BIOS Password**: Use approved secret management for password handling
   - **Power**: Ensure devices are on AC power

6. **Logging and Verification**
   - Check DCU/SCCM logs: `C:\ProgramData\Dell\UpdateService\Log\activity.log`
   - Use SCCM compliance reporting and Configuration Baselines

7. **Optional: Dell Command | Integration Suite**
   - Use for driver/package library management and BIOS configuration deployments
   - Does not replace third-party catalog workflow for BIOS updates

### Configuration Notes
- Use catalog method rather than custom task sequences for most BIOS updates
- Avoid DCU CLI with `-reboot=enable` in silent mode; prefer `-reboot=disable`
- Some organizations report Dell catalog metadata corruption in WSUS

## Intune-Primary Deployment Guide

### Overview
Two proven Intune-first patterns: (A) Intune Driver Update Management for native BIOS/firmware delivery, and (B) Intune + Dell Command | Update using ADMX policies + Proactive Remediations.

### Method A: Intune Driver Update Management (WUfB Capsule Method)

#### Why Use It
Dell publishes firmware/BIOS updates as Windows Update capsules; Intune's Driver Update feature can approve and deploy these natively.

#### Proven Steps
1. **Verify Prerequisites**
   - Devices on supported Windows versions with capsule support
   - Verify specific Dell BIOS update availability as Windows Update capsule

2. **Shift Driver Updates Workload to Intune**
   - Move Driver updates workload control to Intune in co-management settings

3. **Create Driver Update Policy**
   - Intune admin center → Devices → Windows → Driver updates → Create profile
   - Use automatic/manual approval and dynamic groups

4. **Configure Update Rings**
   - Control restart behavior and deferral windows
   - Ensure Autopatch entitlement and licensing

5. **Pilot and Rollout**
   - Use rings/pilot groups (1% → 10% → broad)

6. **Monitoring**
   - Use Intune driver update reports and cross-verify via `Get-WmiObject Win32_BIOS`

### Method B: Intune + DCU ADMX or Proactive Remediations (DCU CLI Method)

#### Why Use It
When DCU is already installed and you require DCU-level controls (BIOS password handling, DCU logging, targeted DCU features).

#### Proven Steps
1. **Deploy or Confirm DCU Presence**
   - Ensure Dell Command | Update v5.x+ is installed
   - Deploy as Win32 app if needed via Intune or SCCM

2. **Import DCU ADMX into Intune**
   - Intune → Devices → Configuration profiles → Templates → Imported administrative templates
   - Configure policies: update interval, update scope, notification style, restart deferral settings

3. **Create Proactive Remediations**
   - **Detection script**: Run `dcu-cli.exe /scan --updateType=bios`
   - **Remediation script**: Run `dcu-cli.exe /applyUpdates --updateType=bios --silent --reboot=disable`

4. **BitLocker and BIOS Password Handling**
   - **BitLocker**: Suspend before update using `Suspend-BitLocker -MountPoint 'C:' -RebootCount 2`
   - **BIOS Password**: Use secure secret stores (Azure Key Vault, SCCM masked variables)

5. **UX and Notifications**
   - Use DCU ADMX native toast notifications
   - Scripts execute as SYSTEM context; cannot display toasts directly

6. **Pilot, Monitor, and Expand**
   - Use Autopatch rings or dynamic groups
   - Monitor Intune remediation output and DCU logs

## Cross-Cutting Safety Requirements

### Proven Safety Checklist
- Always test on a pilot ring (1% → 10% → broad)
- Automate BitLocker suspend/resume in update workflows
- Ensure BIOS password handling is secret-backed and audited
- Prefer `-reboot=disable` for CLI runs; let management tool coordinate restart
- Monitor DCU logs and management console reports
- Set compliance target (e.g., ≥90% within 14 days)

### Critical Controls Both Methods Must Implement
- Standardize DCU settings fleet-wide via Intune ADMX or single authoritative channel
- Use audited secret store for BIOS passwords (Azure Key Vault, SCCM masked variables)
- Test with staged rings/pilot groups and document rollback plan

## Troubleshooting and Best Practices

### Common Issues and Solutions
- **Dell catalog metadata corruption in WSUS**: Unsubscribe, clean metadata, re-subscribe
- **Capsule availability**: Not all firmware releases are published to WUfB
- **Double installations**: Ensure only one management plane is authoritative

### Performance Considerations
- Use dynamic groups for targeting
- Implement proper update rings for staged rollout
- Monitor compliance and adjust deployment pace as needed

## References

### Official Documentation
- [Dell Business Client Update Catalog](https://www.dell.com/support/kbdoc/en-us/000133115/dell-command-update-catalog)
- [Microsoft: Third-party software update catalogs in Configuration Manager](https://learn.microsoft.com/en-us/intune/configmgr/sum/deploy-use/third-party-software-update-catalogs)
- [Dell Command | Update ADMX & CLI Reference Guide](https://www.dell.com/support/manuals/en-us/command-update/admx_rg/configure-policy-settings)
- [Dell Command | Update CLI reference](https://www.dell.com/support/manuals/en-us/command-update/dcu_rg/dell-command-%7C-update-cli-commands?guid=guid-92619086-5f7c-4a05-bce2-0d560c15e8ed&lang=en-us)
- [Dell Command | Command Line Interface Error codes](https://www.dell.com/support/manuals/en-us/command-update/dcu_rg/command-line-interface-error-codes?guid=guid-fbb96b06-4603-423a-baec-cbf5963d8948&lang=en-us)
- [Dell Command | Integration Suite for Microsoft System Center](https://www.dell.com/support/manuals/en-us/dell-command-integration-suite-v5.0/dcis_ig_5.0/prerequisites-to-install-dell-command-integration-suite-for-system-center)

### Additional Resources
- Dell Update Strategies guide
- Microsoft Intune: Driver updates / Windows Update for Business driver updates
- Dell Command | Update CLI Error Codes documentation
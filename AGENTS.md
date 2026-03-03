# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Repository Purpose

TempTransfers is a community-driven repository for sharing, documenting, and testing solutions to complex technical issues across various technologies and platforms. Each issue is organized into its own subdirectory containing:

- Comprehensive documentation and analysis
- Diagnostic and remediation scripts
- Multi-source validation (e.g., AI analyses, vendor guidance)
- Progressive remediation strategies (safe → moderate → aggressive)

The repository serves as a testbed where solutions can be validated across different environments before broader deployment.

## Repository Structure

Each issue follows a consistent organizational pattern:

```
TempTransfers/
├── [Issue-Name]/              # Self-contained issue directory
│   ├── CORRECTION_GUIDE.md    # Master remediation document
│   ├── SOURCE/                # Original analyses and references
│   │   ├── _ProblemSummary.txt
│   │   └── [Various analyses].md
│   └── [Remediation Scripts]  # Phased or sequenced fixes
└── README.md                  # Repository overview
```

**Navigation**: Use `ls` or `Get-ChildItem` to discover available issue directories. Each is self-documenting with its own CORRECTION_GUIDE.md.

## Working with Scripts

### General Script Guidelines

**Always review scripts before execution:**
```powershell
# View script content
Get-Content .\[Issue-Dir]\[Script].ps1 | more

# Check for execution requirements
Select-String -Path .\[Issue-Dir]\*.ps1 -Pattern "#Requires"
```

### PowerShell Scripts

**Validate syntax without execution:**
```powershell
$errors = $null
$null = [System.Management.Automation.PSParser]::Tokenize(
    (Get-Content .\[Issue-Dir]\[Script].ps1 -Raw), [ref]$errors
)
if ($errors) { $errors } else { "Syntax OK" }
```

**Most scripts require elevation:**
```powershell
# Verify you're running as Administrator
[Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent() |
    ForEach-Object { $_.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
```

### Common Script Patterns

Issues typically follow a phased approach:
- **Assessment/Diagnostic** (Phase0): READ-ONLY, captures current state
- **In-place repair** (Phase1): MODERATE RISK, targeted fixes
- **Full rebuild** (Phase2+): HIGH RISK, comprehensive remediation

Always start with assessment scripts and follow the sequence documented in each issue's CORRECTION_GUIDE.md.

## Core Principles

### Progressive Remediation

All issues follow a risk-graduated approach:
1. **Assess**: Capture current state without modifications
2. **Targeted repair**: Minimal-risk fixes addressing root cause
3. **Comprehensive rebuild**: High-risk, high-success complete remediation

### Multi-Source Validation

Solutions are synthesized from multiple sources:
- AI/LLM analyses (Claude, OpenAI, Qwen, etc.)
- Vendor documentation and support guidance
- Community testing across different environments
- Real-world production validation

### Documentation-First

Each issue includes:
- **Problem summary**: Original symptoms and environment
- **Root cause analysis**: Technical deep-dive from multiple perspectives
- **Decision trees**: Guided troubleshooting paths
- **Validation checklists**: Post-remediation verification steps

## Working with Issue Directories

### Finding Issues

```powershell
# List all issues
Get-ChildItem -Directory | Where-Object { Test-Path "$_\CORRECTION_GUIDE.md" }

# Search for specific technology
Get-ChildItem -Directory | Where-Object { $_.Name -like "*WSUS*" -or $_.Name -like "*SQL*" }
```

### Understanding Each Issue

1. **Start with CORRECTION_GUIDE.md**: Master remediation document synthesizing all analyses
2. **Review SOURCE/ directory**: Original problem statements and multiple analytical perspectives
3. **Follow script sequence**: Execute in order documented in CORRECTION_GUIDE.md
4. **Validate results**: Use provided checklists before considering issue resolved

### Documentation Hierarchy

- **CORRECTION_GUIDE.md**: Primary source, actionable remediation steps
- **SOURCE/**: Historical reference, helpful for understanding different approaches
- **Scripts**: Executable implementations of documented solutions

## Contributing New Issues

### Directory Structure Standard

Create a new subdirectory following this pattern:
```
[Technology-IssueType]/
├── CORRECTION_GUIDE.md           # Master remediation guide
├── SOURCE/                       # Original analyses and references
│   ├── _ProblemSummary.txt      # Initial issue description
│   └── [Source].md              # AI analyses, vendor docs, etc.
└── [Remediation-Scripts]         # Sequenced/phased fixes
```

**Naming conventions:**
- Use `PascalCase` or `kebab-case` for directory names
- Be descriptive but concise (e.g., `Wsus-Sup`, `SQL-Deadlock`, `AD-Replication`)
- Scripts should indicate sequence: `Phase0-`, `Phase1-`, or `Step1-`, `Step2-`

### Documentation Standards

**CORRECTION_GUIDE.md must include:**
- Executive summary (problem, root cause, current state, risk)
- Root cause analysis with supporting evidence
- Phase-based remediation approach
- Validation checklists
- Decision trees for troubleshooting
- Known issues and when to escalate

**Script standards:**
- Include `#Requires` statements for prerequisites
- Use color-coded output (Cyan/Yellow/Green/Red for status)
- Export diagnostic data to timestamped directories
- Validate prerequisites before making changes
- Include inline comments explaining non-obvious logic
- Never hardcode environment-specific values

### Security Requirements

**CRITICAL** - Scripts in this repository often run with elevated privileges:
1. Always capture state before modifications
2. Validate all file paths exist before operations
3. Never embed credentials or secrets
4. Include risk warnings in script headers
5. Document rollback procedures

## Common Tasks

### Validate Scripts in an Issue Directory

```powershell
# Validate all PowerShell scripts in a specific issue
$issueDir = ".\[Issue-Name]"
Get-ChildItem -Path $issueDir\*.ps1 | ForEach-Object {
    Write-Host "Checking $($_.Name)..." -ForegroundColor Cyan
    $errors = $null
    $null = [System.Management.Automation.PSParser]::Tokenize(
        (Get-Content $_.FullName -Raw), [ref]$errors
    )
    if ($errors) {
        Write-Host "  ERRORS FOUND:" -ForegroundColor Red
        $errors | Format-Table -AutoSize
    } else {
        Write-Host "  OK" -ForegroundColor Green
    }
}
```

### Find Assessment Output

```powershell
# Locate most recent diagnostic output (common pattern)
$assessmentDirs = Get-ChildItem C:\Temp -Directory -Filter "*PreFix*", "*Assessment*", "*Diagnostic*" |
    Sort-Object CreationTime -Descending

if ($assessmentDirs) {
    Write-Host "Recent assessments found:"
    $assessmentDirs | Select-Object -First 5 | Format-Table Name, CreationTime
}
```

### Search for Specific Issue Types

```powershell
# Find issues related to a technology
$technology = "SQL"  # or "WSUS", "AD", "IIS", etc.
Get-ChildItem -Directory | Where-Object {
    $_.Name -like "*$technology*" -or
    (Test-Path "$_\CORRECTION_GUIDE.md" -and 
     (Select-String -Path "$_\CORRECTION_GUIDE.md" -Pattern $technology -Quiet))
}
```

## Environment Context

### Platform Considerations

**Primary focus**: Windows-based infrastructure and enterprise systems
- Most scripts are PowerShell (5.1+ or 7+)
- Many require Administrator privileges
- Some target specific Windows Server roles (AD, SCCM, SQL Server, etc.)

**Multi-platform support**: Issues may include Linux/Unix solutions where applicable

### Dependencies

Each issue directory should document its specific requirements:
- Required PowerShell modules
- Windows Features or Server roles
- Third-party tools or utilities
- Minimum OS versions

Check CORRECTION_GUIDE.md in each issue for prerequisites.

### Security Considerations

**General principles:**
- Scripts often require elevated privileges
- May modify system registry, services, or critical configurations
- Always run assessment/diagnostic scripts first
- Backup directories may contain sensitive configuration data
- Never run scripts from untrusted sources without review

## Related Documentation

Per project documentation standards:
- This file (WARP.md): AI assistant rules and development guidance
- README.md: Project overview and GitHub context
- CORRECTION_GUIDE.md: Primary technical remediation documentation

## Troubleshooting

### Script Execution Issues

**Access Denied errors:**
```powershell
# Verify PowerShell is elevated
[Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent() |
    ForEach-Object { $_.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
# Should return: True
```

**Execution policy blocks:**
```powershell
# Check current policy
Get-ExecutionPolicy -List

# Run script bypassing policy (one-time)
powershell.exe -ExecutionPolicy Bypass -File .\[Script].ps1
```

### When Solutions Don't Work

1. **Review CORRECTION_GUIDE.md** for decision trees and escalation paths
2. **Check prerequisites** in the issue's documentation
3. **Examine diagnostic output** from assessment scripts
4. **Compare with SOURCE/** analyses to understand different perspectives
5. **Document your findings** and consider contributing updates

## Git Workflow

This repository uses a simple workflow:
```powershell
# Stage changes
git add .

# Commit with descriptive message
git commit -m "Add [IssueType]: [Brief Description]"

# Push to remote
git push origin main
```

### Commit Message Conventions

- `Add [IssueName]: [Description]` - New issue directories
- `Update [IssueName]: [Description]` - Modifications to existing issues
- `Fix [IssueName]: [Description]` - Bug fixes in scripts
- `Docs: [Description]` - Documentation-only changes
- `Validate [IssueName]: [Description]` - Testing results from different environments

## Repository Philosophy

TempTransfers serves as a collaborative testbed where:

1. **Complex issues** are documented comprehensively
2. **Multiple perspectives** are captured and synthesized
3. **Solutions are validated** across different environments
4. **Risk is managed** through progressive remediation approaches
5. **Knowledge is shared** for community benefit

When working with any issue:
- Trust but verify - solutions work in some environments but may need adaptation
- Document your testing results
- Follow the progressive risk approach (assess → targeted → comprehensive)
- Contribute back your findings and improvements

# x64-ARM64 Architecture Development Guide

## Overview
This guide consolidates research on handling x64 and ARM64 builds in a FastAPI/Tauri repo using VS Code and Cline, prioritizing reliability over manual terminal management.

## Validated Requirements
- MSVC toolchain via `vcvarsall.bat` for environment setup [Microsoft Learn](https://learn.microsoft.com/en-us/cpp/build/how-to-enable-a-64-bit-visual-cpp-toolset-on-the-command-line).
- Rust `aarch64-pc-windows-msvc` target and ARM64 build tools for Tauri [Tauri v2 Docs](https://v2.tauri.app/distribute/windows-installer/).
- Python native extensions require arch-specific builds [Python setuptools](https://setuptools.pypa.io/en/latest/userguide/ext_modules.html).

## Recommended Workflow: Python Runner
Use a script in `backend/.venv` to detect arch, invoke `vcvarsall.bat`, and spawn commands. Example: `python run_dev.py --arch arm64 tauri build`.

## Architecture Mapping
| Mode | Host | Target | Rust Target | MSVC Arg |
|------|------|--------|-------------|----------|
| x64 | x64 | x64 | x86_64-pc-windows-msvc | x64 |
| arm64 | ARM64 | ARM64 | aarch64-pc-windows-msvc | arm64 |
| cross | x64 | ARM64 | aarch64-pc-windows-msvc | x64_arm64 |

## Alternatives
- VS Code profiles: Convenient but unreliable for Cline [GitHub Issue #3295](https://github.com/cline/cline/issues/3295).
- Developer PowerShell: Microsoft-supported but shell-specific.

## Risks
- Cline env inheritance uncertain; test with subprocess injection.
- ARM64 wheel availability; verify deps.
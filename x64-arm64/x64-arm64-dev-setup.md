# x64-ARM64 Development Setup: Implementation Decision Note

## Objective
This note defines the implementation decision for reliable x64/ARM64 development in the FastAPI/Tauri repo. It focuses on boundary ownership, explicit architecture handling, and the role of a repo-owned Python dev runner.

## Validated Direction
- Use a repo-owned Python dev runner as the primary architecture-sensitive execution boundary.
- The runner is invoked by the `backend/.venv` Python executable.
- `.venv` is disposable environment state and must not contain the runner implementation.
- Use Microsoft `vcvarsall.bat` / native and cross compiler environment setup for Windows MSVC capture.
- Respect Tauri Windows ARM64 target/build support.
- Respect Python packaging dependency groups if referenced.
- Pass explicit Rust/Tauri targets for architecture-sensitive builds.
- Treat VS Code terminal profiles, Developer Command Prompt / Developer PowerShell, and Cline CLI from a prepared shell as fallbacks only.

## Runner Ownership and Invocation
- The runner code lives in versioned repo source.
- The runner is invoked by the `backend/.venv` Python executable.
- The `.venv` Python executable is the command entrypoint, not the implementation location.
- `backend/.venv` must remain disposable environment state; the implementation must live in repo source, not under `.venv`.
- FastAPI runtime code, Tauri runtime config, frontend code, and package install scripts must not own MSVC architecture selection.

## Windows Environment Capture Method
On Windows, the Python runner should capture the Visual Studio/MSVC environment by launching a child `cmd` process, sourcing the selected Visual Studio variables, parsing the emitted environment, and then running the requested command with that captured environment dictionary.

Conceptual method:
```cmd
call vcvarsall.bat <arch> && set
```

Then parse the output of `set` into an environment dictionary and execute the requested command under that captured environment.

This MSVC environment capture is Windows-only; on non-Windows hosts, the Python runner should execute normal subprocess commands without Visual Studio environment capture.

## Architecture Mapping
```
x64 native
  Host: Windows x64
  Target: Windows x64
  Rust target: x86_64-pc-windows-msvc
  MSVC arg: amd64 or x64

ARM64 native
  Host: Windows ARM64
  Target: Windows ARM64
  Rust target: aarch64-pc-windows-msvc
  MSVC arg: arm64
  Must be proven on the ARM64 host with installed ARM64-native Visual Studio tools.

x64-to-ARM64 cross-target
  Host: Windows x64
  Target: Windows ARM64
  Rust target: aarch64-pc-windows-msvc
  MSVC arg: amd64_arm64 or x64_arm64
```

## Dependency Provisioning Boundaries
- `pyproject.toml` owns declared Python dependencies and optional dependency groups if the repo adopts or already uses pyproject-based packaging.
- `backend/.venv` owns installed local environment state.
- Dependency installation must be explicit.
- Normal check/build commands should validate and fail with remediation, not silently install missing packages or tools.
- Architecture-sensitive or hardware-sensitive dependencies must not be blindly universalized.

## Command Category Boundaries
```
deps-check
  Non-mutating. Reports missing Python packages, Rust targets, Node packages, and Visual Studio components where detectable.

deps-sync
  Explicit, mutating install/sync of declared dependencies into backend/.venv.

check --arch <arch>
  Non-mutating architecture and toolchain validation.

tauri-build --arch <arch>
  Build-only execution. No hidden install, only normal build artifacts.
```

## Acceptance Criteria
A valid first implementation slice proves:
- `backend/.venv` Python can invoke the repo-owned Python dev runner.
- The runner can select x64 or ARM64 mode.
- On Windows, it can capture the selected Visual Studio/MSVC environment.
- It verifies `VSCMD_VER`, `cl` path, `cl /Bv`, Rust toolchain, installed Rust target, active Python executable, and Python `platform.machine()`.
- It can run or dry-run the intended Tauri command under the captured environment.
- Dependency checks are explicit and non-mutating unless a deliberate `deps-sync` command is invoked.

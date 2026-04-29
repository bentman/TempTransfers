### Validated facts
- **Architecture ownership:** Must sit at the **repo orchestration layer** (task runner/wrapper), not IDE terminals or user shells. Persistent shell state is unreliable for AI agents and automated CI/CD.
- **Microsoft tooling:** `vswhere.exe` (shipped with VS Installer/Build Tools) is the current standard for locating installations. Initialization uses `vcvarsall.bat` or `VsDevCmd.bat` with architecture arguments (`x64`, `arm64`, or cross `x64_arm64`). No official PowerShell-native replacement exists; batch invocation remains the supported path.
- **Rust/Tauri constraints:** Windows builds require the MSVC toolchain. ARM64 requires `aarch64-pc-windows-msvc`. Tauri v2 delegates to `cargo`, so `CARGO_BUILD_TARGET` or `.cargo/config.toml` controls arch. Cross-compiling x64→ARM64 is fully supported but requires explicit target installation and MSVC cross-linker components.
- **Python native extensions:** Compile against the active Python interpreter’s architecture. Windows cross-compilation for Python extensions is poorly supported; native builds per architecture are strongly recommended. Build tools (`scikit-build-core`, `setuptools`) respect `VSCMD_ARG_TGT_ARCH`, `Platform`, and `DISTUTILS_USE_SDK`.
- **Cline behavior:** Executes commands in isolated or terminal-bound contexts without guaranteed VS Code profile inheritance. Environment variables must be injected per invocation, not exported in a persistent shell.

### Assumptions requiring proof
- Cline’s command execution model passes through environment variables set by a parent process/subprocess wrapper without sanitization or reset.
- Target machines have Visual Studio Build Tools (or full VS) with **C++ x64/ARM64 build tools** and **Windows SDK** workloads installed.
- Required Python dependencies provide prebuilt `win_arm64` wheels or can be compiled locally on ARM64 hardware.
- Tauri’s frontend toolchain (npm/pnpm/yarn + bundler) contains no architecture-specific native addons that fail on ARM64.

### Recommended direction
**Use a repo-local, shell-neutral task runner or Python entrypoint (leveraging `backend/.venv`) that explicitly initializes MSVC, sets architecture targets, and delegates to build/run commands per invocation.**

- **How it works:** The wrapper detects or accepts a `TARGET_ARCH` flag (`x64`/`arm64`). It calls `vswhere` to locate `vcvarsall.bat`, captures the environment it sets, injects Rust/Python arch variables (`CARGO_BUILD_TARGET`, `VSCMD_ARG_TGT_ARCH`), and executes the requested command via subprocess.
- **Why this is most reliable for Cline:** Bypasses terminal-profile inheritance entirely. Each command starts with a clean, explicitly configured environment. Works identically whether invoked by Cline, CI, or a human.
- **x64/ARM64/cross handling:** 
  - Native builds preferred: run `vcvarsall.bat x64` on x64 hosts, `vcvarsall.bat arm64` on ARM64 hosts.
  - Cross-targeting: use `vcvarsall.bat x64_arm64` + `CARGO_BUILD_TARGET=aarch64-pc-windows-msvc`. Avoid cross-targeting Python extensions unless using `cibuildwheel` or precompiled wheels.
- **Trade-offs (shell-neutral vs shell-specific):** 
  - *Shell-neutral (Python/just/Task):* Portable, explicit, agent-friendly, but requires careful environment capture and subprocess mapping.
  - *Shell-specific (PS/Batch profiles):* Tighter MSVC integration, simpler syntax, but fragile across agents, non-standard shells, and CI runners.
- **Best balance:** Python entrypoint in `.venv` or `justfile`. Python offers direct `os.environ` manipulation, `subprocess` control, and zero additional runtime. `just` offers declarative cross-platform recipes with minimal boilerplate. Both keep architecture logic centralized and Cline-resilient.

### Fallback options
1. **`just` with OS-conditioned recipes:** Calls `cmd /c "vcvarsall.bat <arch> && <command>"`. Highly reliable, but delegates env setup to Windows shell, losing some Python ecosystem integration.
2. **VS Code terminal profiles + explicit `devcontainer.json`-style setup:** Works if Cline is forced to use a specific profile, but reintroduces the inheritance fragility you want to avoid.
3. **npm/pnpm script orchestration:** Wraps batch/PowerShell init scripts. Viable if the repo already treats Node as the entrypoint, but couples the backend to Node and adds Windows shell dependencies.

### Risks or caveats
- **Python ARM64 wheel gaps:** Some C-extension packages still lack `win_arm64` wheels. If cross-compilation is forced, builds will likely fail without a native ARM64 build agent or manual toolchain patching.
- **Cline env stripping:** If Cline runs commands through a sandboxed executor, parent-set variables may be dropped. The wrapper must inject variables directly into the `subprocess`/`exec` environment block, not rely on shell `export`/`$env:`.
- **VS workload drift:** `vswhere` finds the install, but missing `Desktop development with C++` or `ARM64 build tools` components causes silent MSVC linker failures. CI/dev machines require workload verification.
- **Tauri frontend arch sensitivity:** If the frontend uses native addons (e.g., `sharp`, `sqlite3`), they must be rebuilt for ARM64 or swapped for pure-JS/ARM64-compatible equivalents.
- **Cross-target debug friction:** x64→ARM64 cross-builds work but break IDE debugger attachment and increase artifact size. Reserve cross-targeting for CI; recommend native ARM64 dev on ARM64 hardware.
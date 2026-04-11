# JARVIS Capability Comparison Census

## Executive Summary
Across v1→v5, JARVIS evolves from a basic chat + conditional voice stack into a broader orchestration platform with stronger task lifecycle control, persistent memory surfaces, governance/policy gates, and operator-facing runtime controls. The largest step-change appears in v4/v5 with explicit controller workflows, tool governance, and richer operations APIs.

Quality progression is non-linear: v2 and v4 show broader, better-covered backend capabilities (both 3.5/5 overall), while v3 and v5 retain meaningful functionality but also notable conditional/runtime fragility (both 3/5 overall). Runtime dependency gating (models, binaries, provider keys, Redis, endpoint availability) is a major cross-version caveat and materially affects real-world capability reliability.

## Shared Comparison Categories
- **Task Orchestration & Workflow Execution**
- **Backend API Surface & Contract Maturity**
- **Chat/Inference Pipeline**
- **Memory & Retrieval**
- **Voice Capabilities (STT/TTS/Wake/Session)**
- **External Search/Tool Governance**
- **Frontend Integration & UX Wiring**
- **Validation/Setup Automation Harness**

## Capability Comparison Matrix
Legend: `✓` present, `◐` partial/conditional, `—` not materially present in census; quality shown as `(x/5)` where provided.

| Category | v1 | v2 | v3 | v4 | v5 |
|---|---|---|---|---|---|
| Task Orchestration & Workflow Execution | — | ◐ (chat flow only) | ✓ (3/5) workflow engine + streaming | ✓ (4/5) controller lifecycle + resume/archive | ✓ (4/5) PLAN→EXECUTE→VALIDATE→COMMIT→ARCHIVE |
| Backend API Surface & Contract Maturity | ✓ (3/5) basic chat/status/voice routes | ✓ (4/5) broad v1 endpoints with governance wiring | ✓ (3/5) broad APIs, some simulated/not implemented | ✓ (3/5) task + voice + health/metrics | ✓ (4/5) task/upload/stream/workflow + health/settings/budget/memory |
| Chat/Inference Pipeline | ✓ (3/5) Ollama-or-echo fallback | ✓ (4/5) budget-gated inference + persistence + stream | ✓ (3/5) workflow-driven chat + SSE | ◐ (embedded via task/controller execution) | ◐ (task-centric execution vs classic chat endpoint model) |
| Memory & Retrieval | — (minimal/no substantive retrieval layer) | ✓ (4/5) semantic memory + tagging + import/export + stats | ✓ (4/5) SQLite persistence + semantic search + checkpoints | ◐ (task/workflow archival and summaries) | ✓ (4/5) semantic + episodic search/delete + controller writes |
| Voice Capabilities (STT/TTS/Wake/Session) | ◐ (2/5) APIs present; wake detector not initialized | ✓ (3/5) STT/TTS/wake/session with lazy init/fallbacks | ◐ (2/5) endpoints exist, runtime-binary/model fragile | ◐ (3/5) tool wrappers + lifecycle orchestration | ◐ (3/5) voice APIs present but dependency-gated/503 paths |
| External Search/Tool Governance | — | ✓ (3/5) unified search + optional remote escalation + privacy/budget gates | ◐ (provider routing exists; remote delegation partial) | ✓ (3/5) tool registry + web search with privacy/budget/cache/provider fallback | ✓ (3/5) policy + permission + budget-gated search/fetch dispatch |
| Frontend Integration & UX Wiring | ✓ (3/5) chat UI + voice panel wiring | ◐ (2/5) substantial UI but contract mismatches/incomplete wiring | ✓ (3/5) chat + SSE + workflow visual + voice hooks | ✓ (3/5) minimal but functional task submission client | ✓ (3/5) operator UI with streaming/upload/settings/budget/memory/workflow panels |
| Validation/Setup Automation Harness | ✓ (3/5) staged PowerShell setup/install scripts | ✓ (2/5 for FE+scripts category in census; setup automation exists) | ◐ (no PowerShell setup scripts; testing present) | ✓ (4/5) robust Python backend validation harness; no PowerShell setup | ✓ (3/5) Python validation harness; no PowerShell setup |

### Major Caveats Affecting Comparison
- **Runtime dependency gating is persistent across versions**: model files/runtimes, STT/TTS binaries, provider credentials, Redis/cache availability, and environment config often determine whether a “present” capability is actually usable at runtime.
- **v2 frontend/backend contract drift** materially reduces end-to-end confidence despite strong backend depth (e.g., TTS request-shape mismatch, hardware schema mismatch, unpropagated toggles/state).
- **v3 includes explicit non-final surfaces** (simulated workflow status, template execute marked `not_implemented`), reducing parity with similarly broad API exposure in v2/v4/v5.
- **PowerShell setup automation is version-skewed**: strong in v1 (and present in v2 scripts), absent as a setup surface in v3/v4/v5 census scope.

## Key Trends
- **Capabilities present in all versions**
  - Backend API surface exists in each version.
  - A working user-interaction path exists in each version (chat/task-oriented).
  - Some form of voice capability is present in all versions, but reliability is consistently conditional.
  - Runtime/environment dependency sensitivity is a constant across all versions.

- **Major improvements**
  - **Orchestration maturity** rises sharply in v4/v5 (deterministic lifecycle execution, archival, replay/telemetry).
  - **Memory surfaces** mature from limited/implicit (v1) to rich retrieval and management (v2, v3, v5).
  - **Governance/tool controls** become explicit from v2 onward and formalized in v4/v5 (budget, privacy/policy, permission checks).
  - **Operations/runtime controls** are strongest in v5 (detailed health, settings with restart semantics, budget endpoints).

- **Regressions / weaker phases**
  - **v3** shows broader architecture but lower confidence in some advanced surfaces due to simulated/not-implemented endpoints and dependency fragility.
  - **v5 overall score** (3/5) is lower than v4 (3.5/5), indicating that broader capability integration still carries operational fragility.

- **Capabilities appearing only in later versions**
  - Deterministic controller task lifecycle with archival/replay semantics (notably v4/v5).
  - Rich operator/runtime management APIs (especially v5 settings/budget/detailed health).
  - Policy/permission-first search tool dispatch behavior (v4/v5 emphasis).

## Advisor Notes
- **Stable category names to reuse**
  1. Task Orchestration & Workflow Execution
  2. Backend API Surface & Contract Maturity
  3. Chat/Inference Pipeline
  4. Memory & Retrieval
  5. Voice Capabilities (STT/TTS/Wake/Session)
  6. External Search/Tool Governance
  7. Frontend Integration & UX Wiring
  8. Validation/Setup Automation Harness

- **Recommended comparison metrics (keep consistent)**
  - **Presence state** per category: `✓ / ◐ / —`.
  - **Category quality score** as reported by each census (no re-scoring).
  - **Runtime gating severity**: low/medium/high conditionality from stated caveats.
  - **End-to-end contract consistency**: backend capability vs frontend/client wiring alignment.
  - **Test evidence strength**: unit/integration/agentic coverage depth and whether tests are dependency-skipped or mock-heavy.

- **Naming drift / overlap issues to watch**
  - “Chat” vs “Task execution” surfaces diverge in later versions; keep them separate but cross-referenced.
  - “Memory” can mean conversation persistence, semantic vectors, episodic decisions, or workflow archives; label sub-scope explicitly.
  - “Tooling/Search” overlaps with governance and provider integration; track both capability existence and gating path.
  - “Setup automation” changed modality (PowerShell-heavy early vs Python validation later); compare as **automation harness**, not script language.

## Conclusion
JARVIS capability breadth and architectural sophistication increase materially from v1 to v5, with strongest strategic advances in orchestration, governance, and operational control surfaces. However, cross-version reliability remains highly sensitive to runtime dependencies and integration consistency; advisor decisions should weight conditionality and end-to-end contract fidelity as heavily as raw feature presence.
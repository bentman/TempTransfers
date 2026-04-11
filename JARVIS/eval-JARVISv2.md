# JARVISv2 Codebase Capability Census

## Executive Summary
JARVISv2 contains a real, multi-surface local-assistant implementation: FastAPI endpoints, service-layer logic, persistent memory, budget/privacy controls, search integration, and a React frontend shell. The strongest areas are backend API/service wiring and memory/governance behavior with test coverage. The most notable limitations are runtime dependency fragility (model binaries, Whisper/Piper/Redis/provider keys), and partial frontend wiring to newer backend options.

**Overall quality score: 3.5/5 (between functional-with-limitations and solid-with-gaps).**

### Chat inference + persistence pipeline (Quality: 4/5)
**What actually works**
- `/api/v1/chat/send` and `/api/v1/chat/send/stream` enforce budget before inference, create/reuse conversations, persist user/assistant messages, and call model inference.
- Retrieval context is added from local semantic memory, with optional web augmentation.
- Chat responses are cached via Redis when available.

**Implementation details**
- Core flow is implemented in endpoint code, not stubs.
- Budget enforcement is hard-gated (`429`) when limits are exceeded.
- Behavior is conditional on external runtime:
  - local GGUF model files + llama executable must exist and pass hash checks.
  - Redis must be reachable for cache hits/sets.

**Code evidence**
- `backend/app/api/v1/endpoints/chat.py`: `send_message`, `send_message_stream`.
- `backend/app/services/model_router.py`: `generate_response`, `generate_response_stream`, integrity check.
- `backend/app/services/memory_service.py`: `add_message`, `semantic_search`.
- `backend/tests/integration/test_budget_enforcement.py`: verifies chat blocked with HTTP 429 when budget exceeded.

### Memory + retrieval + import/export/tagging (Quality: 4/5)
**What actually works**
- Conversation/message CRUD-like operations are implemented through DB service methods.
- Message content is indexed into vector store on add (best effort), and semantic search returns DB messages from vector hits.
- Tagging endpoints for conversations/messages, filtering by tags, export/import roundtrip, and conversation stats are implemented.

**Implementation details**
- DB layer supports optional encrypt-at-rest for message content and decrypt-on-read.
- Semantic search is FAISS/embedding dependent; failures degrade to empty/no-hit behavior without crashing major flows.
- Import path remaps IDs and reports skipped/missing references.

**Code evidence**
- `backend/app/models/database.py`: `add_message`, `get_messages`, `export_all`, `import_data`, tag helpers, stats.
- `backend/app/api/v1/endpoints/memory.py`: tag/filter/export/import/stats endpoints.
- `backend/tests/integration/test_memory_tags_export.py`, `test_memory_stats_endpoint.py`.
- `backend/tests/unit/test_vector_store.py`.

### Privacy + budget governance controls (Quality: 4/5)
**What actually works**
- Privacy settings are persisted and exposed via API.
- Data classification/redaction/local-processing recommendation endpoints are implemented.
- Retention cleanup endpoint deletes old messages.
- Budget config/status APIs and token-cost event logging are implemented and used by chat/voice/search flows.

**Implementation details**
- Privacy classification is regex/keyword-based (deterministic but heuristic).
- Budget accounting enforces a minimum effective token floor per event (`max(tokens, 50)`), which materially affects spend tracking behavior.
- Governance is integrated into runtime paths (not isolated utility code).

**Code evidence**
- `backend/app/api/v1/endpoints/privacy.py`, `backend/app/services/privacy_service.py`.
- `backend/app/api/v1/endpoints/budget.py`, `backend/app/services/budget_service.py`.
- `backend/tests/unit/test_privacy.py`.
- Chat/voice/search code paths call budget/privacy services.

### Unified search + optional remote LLM escalation (Quality: 3/5)
**What actually works**
- `/api/v1/search/unified` supports local semantic retrieval and optional web provider aggregation.
- Optional LLM summarization/escalation exists and is privacy-redacted before outbound call.
- Provider failures are tolerated; search continues with available providers.

**Implementation details**
- Web search is strongly conditional: `SEARCH_ENABLED`, provider key/config presence, and privacy level not `local_only`.
- LLM escalation is conditional: `REMOTE_LLM_ENABLED`, provider credentials/model, and web results available.
- Endpoint explicitly returns `503` for requested web search when disabled/unconfigured.

**Code evidence**
- `backend/app/api/v1/endpoints/search.py`: `unified` prechecks.
- `backend/app/services/unified_search_service.py`: provider initialization, privacy gate, LLM escalation logic.
- `backend/app/services/search_providers.py` and `external_llm_providers.py`.
- `backend/tests/integration/test_unified_search_toggle.py`, `test_unified_search_llm_toggle.py` (includes mock-driven scenarios).

### Voice/STT/TTS/wake-word session flow (Quality: 3/5)
**What actually works**
- Voice endpoints exist for STT (`/stt`), TTS (`/tts`), wake-word, upload-audio, and one-shot voice session (`/session`).
- Voice session flow integrates wake-word check -> STT -> chat-style generation -> TTS output.
- Service has lazy initialization and fallback logic (e.g., espeak when Piper unavailable).

**Implementation details**
- Highly runtime-dependent: Whisper executable + model weights, Piper/espeak availability, optional openwakeword module.
- Endpoint error handling mostly maps runtime failures to `503`/error payloads.
- Some path fragility remains (external binary discovery/install assumptions).

**Code evidence**
- `backend/app/api/v1/endpoints/voice.py`: STT/TTS/session handlers.
- `backend/app/services/voice_service.py`: lazy init, wake-word detection, STT/TTS execution + fallbacks.
- `backend/tests/unit/test_voice_lazy_init.py`: validates failure mode when Whisper not available.

### Frontend wiring + setup PowerShell automation (Quality: 2/5)
**What actually works**
- React UI renders chat surface, settings modal, hardware status polling, and API client methods for chat/hardware/privacy/budget/voice.
- PowerShell scripts implement real setup/dev/deploy flows: prerequisite checks, model downloads/checksums, dependency install, docker compose orchestration.

**Implementation details**
- Frontend wiring is partially inconsistent with backend contracts:
  - `ApiService.textToSpeech` posts JSON body, while backend `/voice/tts` expects `text` as a simple parameter (query style), causing likely request mismatch.
  - `HardwareStatus` expects nested `capabilities.cpu/gpu`, but backend response model exposes flattened `cpu_cores/cpu_architecture/gpu_vendor` fields.
  - `includeWeb` UI toggle is not passed in `sendMessage` requests.
  - `voiceService` processes STT result internally but does not propagate transcript to UI state.
- Setup scripts are functional but repetitive (notably `main.ps1` duplicates substantial setup/model logic).

**Code evidence**
- Frontend: `frontend/src/components/ChatInterface.tsx`, `HardwareStatus.tsx`, `SettingsModal.tsx`; `frontend/src/services/api.ts`, `voiceService.ts`.
- Scripts: `scripts/setup.ps1`, `scripts/dev-setup.ps1`, `scripts/main.ps1`.

## Gap Analysis
| Area | Code-grounded gap | Impact |
|---|---|---|
| Frontend TTS integration | `ApiService.textToSpeech` sends `{text}` JSON body while backend `/voice/tts` signature is `text: str` parameter | Likely 422/request mismatch in real use |
| Hardware status UI contract | Frontend expects nested CPU/GPU objects; backend returns flattened hardware capability fields | UI can break or display incorrect hardware data |
| Web-search toggle in chat UI | `includeWeb` state exists in `ChatInterface` but is not sent in `ApiService.sendMessage` request | UI control does not affect backend chat retrieval behavior |
| Voice UX path | `voiceService.processAudio` logs transcript but does not emit it back to chat state | Voice capture flow appears incomplete from user perspective |
| Runtime dependencies | llama/Whisper/Piper/Redis/web providers are external and config-dependent | Capabilities are present but conditionally available at runtime |

## Conclusion
JARVISv2 has a substantive backend implementation with real capability coverage across chat, memory, privacy, budget, search, and voice. Core logic is present and partially reinforced by unit/integration tests, indicating meaningful functional behavior rather than scaffolding.

Current maturity is limited mainly by contract mismatches and incomplete frontend wiring, plus dependency/config gating for voice/search/model execution. Backend capability depth is stronger than end-to-end UX consistency.
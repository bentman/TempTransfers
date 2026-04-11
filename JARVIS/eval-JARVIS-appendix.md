

# Appendix A: The Explicit Learning Loop (Target State)

> **Phase II Vision**
> This appendix describes the **target architecture for cognitive weight adaptation** within JARVISv5. It extends the deterministic control plane with a closed-loop learning system, allowing the agent to convert episodic experience into persistent capability updates. This represents the transition from a static inference engine to an adaptive system that internalizes improvements rather than accumulating prompt context.

---

## 1. 🚀 Vision: Self-Healing Cognition

JARVISv5 evolves from a **performer of tasks** to a **learner from experience**. Instead of relying solely on external context injection to handle edge cases, the system mines high-quality interactions from the Episodic Trace to fine-tune local models. This creates a feedback loop where user corrections and successful patterns are permanently encoded into model weights via LoRA adapters.

### Core Learning Invariants

1.  **Experience → Weight Pipeline:** The only path for model behavior change is via structured training data, not prompt adjustments.
2.  **Guard-Railed Training:** All new adapters must pass the existing Regression Harness before promotion.
3.  **Curriculum Curation:** Training data is algorithmically curated for signal-to-noise ratio; not all logs are trainable.
4.  **Deterministic Rollback:** Adapter versioning allows immediate reversion if regression is detected in production.

---

## 2. 🏗️ Learning Architecture

### 2.1 The "Audit-to-Adapter" Pipeline

The learning system operates as an asynchronous background pipeline that ingests the **Episodic Trace** and outputs versioned **LoRA Adapters**.

**Component Stack:**
*   **Curator Agent:** A specialized micro-agent responsible for mining the SQLite `decisions` and `validations` tables for high-quality `(input, output)` tuples.
*   **Dataset Builder:** Converts curated logs into Alpaca/ShareGPT JSONL format, applying PII redaction via existing Security modules.
*   **Unsloth Trainer:** The training engine responsible for parameter-efficient fine-tuning (QLoRA) on local hardware.
*   **Adapter Registry:** Version-controlled storage for trained weights, integrated with the Model Router.

### 2.2 Integration with Existing Control Plane

| Existing Component | New Interaction |
|--------------------|-----------------|
| **Episodic Trace** | Source of truth for mining `success` and `corrected` events. |
| **Model Router** | Queries the Adapter Registry to load the latest validated adapter per task type (e.g., `code-adapter-v3`, `chat-adapter-v1`). |
| **Regression Harness** | Acts as the **Gatekeeper**; rejects adapters that drop success rates below the baseline. |
| **Security** | Sanitizes logs before they enter the training dataset to prevent PII leakage into weights. |

---

## 3. 🧠 Curriculum Curation Strategy

**Not all experience is equal.** The Curator Agent applies strict filters to generate the training curriculum:

1.  **Outcome-Based Filtering:**
    *   *Include:* Tasks where `validator` returned `pass` or user provided explicit positive feedback.
    *   *Include:* Tasks where `validator` returned `fail` BUT user provided a specific correction (diff-based learning).
    *   *Exclude:* Tasks with `timeout` or `system_error` (prevents learning from infrastructure failures).

2.  **Semantic Deduplication:**
    *   Vector embeddings of task inputs are clustered to prevent overfitting to repetitive commands (e.g., "what time is it").

3.  **Basal Mixing:**
    *   Curated local data is mixed at a 70/30 ratio with a "basal dataset" of general instructions to prevent catastrophic forgetting of base capabilities.

---

## 4. ⚙️ Training & Deployment Workflow

### 4.1 Trigger Conditions
Training cycles are triggered automatically based on system activity:
*   **Threshold Reached:** N (e.g., 100) new high-quality episodes logged.
*   **Drift Detected:** Monitoring dashboard indicates a drop in `task_success` metric.
*   **Manual Request:** User initiates "Learn from current session" via UI.

### 4.2 Execution Flow

1.  **Extraction:** Curator queries `data/episodic/` for candidates since the last training cycle.
2.  **Sanitization:** Security module redacts secrets/PII from selected logs.
3.  **Fine-Tuning:** Unsloth service spins up (using GPU profile), trains QLoRA adapter (Rank 16, Epochs 3).
4.  **Validation (The Gate):**
    *   New adapter is loaded into a staging Model Router.
    *   `scripts/validate_backend.py` (Regression Harness) is executed against the adapter.
5.  **Promotion or Rollback:**
    *   *If Pass:* Adapter is tagged `stable` and moved to `models/adapters/`. Model Router updates routing table.
    *   *If Fail:* Adapter is archived to `models/adapters/rejected/`. System logs failure reason and alerts user.

---

## 5. 🗂️ Target Repository Extensions

The following directory structure reflects the intended organization for the learning subsystem:

```text
JARVISv5/
├── backend/
│   ├── learning/                           # 🆕 Cognitive adaptation module
│   │   ├── curator/                        # Log mining and dataset generation
│   │   │   ├── episode_miner.py            # Extracts (input, output) pairs
│   │   │   └── deduplication_engine.py     # Semantic clustering
│   │   ├── trainer/                        # Unsloth integration wrapper
│   │   │   ├── unsloth_service.py          # Training job management
│   │   │   └── lora_config.yaml            # Rank, alpha, dropout params
│   │   └── gates/                          # Safety & validation
│   │       └── regression_gate.py          # Interface to validate_backend.py
│   └── models/
│       ├── adapters/                       # 🆕 Versioned LoRA weights
│       │   ├── code/
│       │   │   ├── v1/
│       │   │   ├── v2/
│       │   │   └── latest -> v2
│       │   └── chat/
│       │       ├── v1/
│       │       └── latest -> v1
│       └── base/                           # Frozen base models (Llama, Mistral)
├── data/
│   └── curriculum/                         # 🆕 Training datasets (JSONL)
│       ├── raw_extracted.jsonl
│       ├── sanitized_curriculum.jsonl
│       └── basal_dataset.jsonl
└── scripts/
    └── trigger_training_cycle.sh           # 🆕 Manual trigger for learning pipeline
```

---

## 6. ✅ Verification & Success Metrics

### 6.1 Learning KPIs

| Metric | Target | Definition |
|--------|--------|------------|
| **Adapter Retention** | >95% | % of new adapters passing the Regression Harness. |
| **Drift Reduction** | <2% | Reduction in behavioral variance on repeated tasks post-update. |
| **Training Velocity** | <4 hrs | Time to generate a candidate adapter on target hardware (RTX 3090/4090). |
| **Catastrophic Forgetting** | 0% | Baseline general capability score must not drop. |

### 6.2 Validation Strategy

*   **Shadow Mode:** New adapters initially serve "shadow" requests (log only, don't return) to compare outputs against the current stable adapter.
*   **A/B Testing:** Router randomly routes 5% of traffic to the new adapter for real-world validation before full promotion.
*   **Automated Rollback:** If `task_success` drops >5% after promotion, the Model Router automatically reverts to `adapter:previous`.

---

**Document Status:** Future State Appendix  
**Dependencies:** Phase I (Core Control Plane & Episodic Trace) must be stable.  
**Next Action:** Implement Curator Agent and integrate with existing Episodic Trace schema.
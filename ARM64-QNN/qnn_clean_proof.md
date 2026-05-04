# Description
Script to execute a clean Qualcomm QNN/ONNX Runtime proof sequence using the probe report and an optional artifact recommendation.

# Explanation
This script creates or reuses a `.venv-qnn`, installs the pinned runtime packages, acquires the exact artifact by path or download, inspects layout and metadata, verifies QNN provider visibility, loads encoder/decoder sessions, runs a minimal inference smoke test, and writes a final evidence report.

# Usage
```powershell
python qnn_clean_proof.py \
  --probe qnn_device_probe_report.json \
  --recommendation qnn_public_artifact_recommendation.json \
  --artifact C:\path\to\downloaded\whisper_artifact
```

Or download the recommended Hugging Face ZIP when `download_url` is available:

```powershell
python qnn_clean_proof.py \
  --probe qnn_device_probe_report.json \
  --recommendation qnn_public_artifact_recommendation.json \
  --download-dir .\qnn-artifacts
```

# Steps
0. Define the exact target from `qnn_device_probe_report.json`.
1. Create or reuse `.venv-qnn` and install `onnxruntime`, `onnxruntime-qnn`, `onnx`, and `numpy`.
2. Acquire the exact artifact from a local path or download the recommended public ZIP.
3. Inspect artifact metadata and file layout.
4. Verify QNN provider visibility inside the virtual environment.
5. Load the encoder session with CPU fallback disabled.
6. Load the decoder session with CPU fallback disabled.
7. Run the smallest synthetic inference smoke test using ONNX Runtime input metadata.
8. Mark the real audio smoke-test boundary and note when artifact-specific adapters are required.
9. Write the final pass/fail evidence report to `qnn_clean_proof_report.json` and `qnn_clean_proof.log`.

# Output Example
```text
qnn_clean_proof.log
qnn_clean_proof_report.json
.venv-qnn\
```

# Result Interpretation
`PASS_LOAD_PROOF__AUDIO_TRANSCRIPT_NOT_CLAIMED` means runtime/provider/artifact compatibility passed, but real transcript proof is not claimed.

`NEEDS_ARTIFACT_SPECIFIC_ADAPTER` at Step 8 means the generic proof boundary was reached and the next stage requires model-specific preprocessing or decode-loop code.

`FAIL` at Step 4 indicates provider/runtime/device visibility issues.

`FAIL` at Step 5 or 6 indicates artifact/runtime/provider mismatch, broken ONNX+BIN layout, or unsupported QNN context.

`FAIL_OR_NEEDS_ARTIFACT_SPECIFIC_INPUTS` at Step 7 means session load proof may be valid, but synthetic inputs do not satisfy the model contract.

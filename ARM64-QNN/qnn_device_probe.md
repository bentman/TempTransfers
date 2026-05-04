# Description
Script to probe the host device for Qualcomm QNN capabilities and runtime status.

# Explanation
Collects OS, SOC, Qualcomm devices, Python runtime info, and optionally inspects artifact directory to recommend next steps for QNN proof.

# Usage
```powershell
python qnn_device_probe.py [--artifact <path>] [--out <output.json>]
```

# Output Example
```json
{
  "host_class": "Windows ARM64 Snapdragon-class host",
  "runtime_path": "Prefer onnxruntime + onnxruntime-qnn plugin path...",
  "artifact_path": "Prefer Qualcomm AI Hub/HF precompiled_qnn_onnx...",
  "next_proof": [
    "QNN provider registration passed; next load encoder/decoder with CPU fallback disabled."
  ],
  "blocking_findings": []
}
```

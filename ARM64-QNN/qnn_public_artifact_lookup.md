# Description
Script to find the best public Qualcomm artifact for the probed device.

# Explanation
Reads probe report, queries Hugging Face Qualcomm model READMEs, parses downloadable artifact tables, ranks candidates by chipset match and runtime preference, and emits the best artifact/runtime/acquisition method.

# Usage
```powershell
python qnn_public_artifact_lookup.py --probe <probe.json> [--chipset <chipset>] [--models <repos>] [--out <output.json>]
```

# Output Example
```json
{
  "target_chipset": "Snapdragon X Elite",
  "recommended": {
    "repo": "qualcomm/Whisper-Tiny",
    "model_name": "Whisper-Tiny",
    "source": "Hugging Face Qualcomm: https://huggingface.co/qualcomm/Whisper-Tiny",
    "runtime": "PRECOMPILED_QNN_ONNX",
    "precision": "float",
    "chipset": "Snapdragon X Elite",
    "sdk_versions": "QAIRT 2.37, ONNX Runtime 1.23.0",
    "download_url": "https://...",
    "acquisition_method": "Download Hugging Face Qualcomm pre-exported ZIP; preserve ONNX + BIN layout.",
    "score": 235,
    "reasons": [
      "preferred Python ONNX Runtime QNN proof artifact",
      "exact chipset string match",
      "declares ONNX Runtime 1.23.0",
      "Tiny model is preferred for first smoke proof"
    ]
  },
  "top_candidates": [...],
  "ai_hub_fallback": {...},
  "decision_rule": {...}
}
```

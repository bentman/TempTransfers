# qnn_device_eval.py

## Description

`qnn_device_eval.py` checks whether the current Windows ARM64 Snapdragon device is ready to run a Qualcomm QNN / ONNX Runtime Whisper-style speech-to-text artifact.

It combines three checks into one script:

1. Detect the local device, OS, processor, and Qualcomm/NPU driver visibility.
2. Look up public Qualcomm Whisper-style model artifacts.
3. Test whether the selected artifact can load through ONNX Runtime QNN.

The script is intended as a compatibility proof before writing application code.

## Purpose

Use this script to answer:

- Is this machine a valid Snapdragon Windows ARM64 QNN test host?
- Which public Qualcomm Whisper artifact is the best first choice?
- Can ONNX Runtime QNN register and discover QNN devices?
- Can the artifact’s encoder and decoder sessions load?
- Is `test.wav` present and readable for a future real STT smoke test?
- What failed, if anything?

This does not prove full transcription quality by itself. Full speech-to-text output still requires artifact-specific audio preprocessing, tokenizer handling, and decoder-loop code.

## Files Created

The script writes three outputs:

```text
qnn_device_probe.json
qnn_device_recommendations.json
qnn_device_stt_readiness.log
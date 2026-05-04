# qnn_public_artifact_lookup.py
# Minimum dependencies: Python stdlib only.
#
# Purpose:
#   Determine the best public Qualcomm Whisper-style artifact candidate for the
#   current Snapdragon/Windows ARM64 device facts collected by qnn_device_probe.py.
#
# Example:
#   python qnn_public_artifact_lookup.py --probe qnn_device_probe_report.json
#
# Optional:
#   python qnn_public_artifact_lookup.py --chipset "Snapdragon X Elite"
#   python qnn_public_artifact_lookup.py --models qualcomm/Whisper-Tiny qualcomm/Whisper-Base

import argparse
import json
import re
import sys
import urllib.request
from dataclasses import dataclass, asdict
from typing import Dict, List, Optional, Tuple


DEFAULT_MODELS = [
    "qualcomm/Whisper-Tiny",
    "qualcomm/Whisper-Base",
]

HF_RAW_README = "https://huggingface.co/{repo}/raw/main/README.md"
HF_MODEL_PAGE = "https://huggingface.co/{repo}"
AI_HUB_MODEL_PAGE = "https://aihub.qualcomm.com/models/{model_slug}"


@dataclass
class ArtifactCandidate:
    repo: str
    model_name: str
    source: str
    runtime: str
    precision: str
    chipset: str
    sdk_versions: str
    download_url: str
    acquisition_method: str
    score: int
    reasons: List[str]


def http_get(url: str, timeout: int = 30) -> str:
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "qnn-public-artifact-lookup/1.0",
            "Accept": "text/plain,text/markdown,text/html,*/*",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", errors="replace")


def normalize(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", (s or "").lower()).strip()


def compact_key(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", (s or "").lower())


def extract_probe_chipset(probe: Dict) -> Optional[str]:
    # Prefer explicit CPU name.
    cpu = probe.get("soc", {}).get("cpu")
    if isinstance(cpu, list) and cpu:
        cpu_text = json.dumps(cpu[0])
    else:
        cpu_text = json.dumps(cpu)

    # Then PnP/driver candidates.
    pnp_text = json.dumps(probe.get("qualcomm_devices", {}).get("pnp_candidates", []))
    driver_text = json.dumps(probe.get("qualcomm_devices", {}).get("signed_driver_candidates", []))
    combined = " ".join([cpu_text, pnp_text, driver_text])

    patterns = [
        r"Snapdragon\s+X\s+Elite",
        r"Snapdragon\s+X\s+Plus",
        r"Snapdragon\s+X2\s+Elite",
        r"Snapdragon\s+8\s+Elite\s+Gen\s+5",
        r"Snapdragon\s+8\s+Elite",
        r"Snapdragon\s+8\s+Gen\s+3",
        r"QCS9075",
        r"QCS8550",
        r"QCS8450",
        r"SA8775P",
        r"SA8295P",
    ]

    for pat in patterns:
        m = re.search(pat, combined, flags=re.I)
        if m:
            return m.group(0)

    # Fallback for common Snapdragon X CPU strings that do not include marketing name.
    if re.search(r"\bX1P\b|\bX1E\b|\bOryon\b|Snapdragon", combined, flags=re.I):
        return "Snapdragon X Elite"

    return None


def parse_markdown_artifact_rows(repo: str, readme: str) -> List[Dict[str, str]]:
    """
    Parses rows like:
    | PRECOMPILED_QNN_ONNX | float | Snapdragon® X Elite | QAIRT 2.37, ONNX Runtime 1.23.0 | [Download](...) |
    """
    rows = []
    for line in readme.splitlines():
        line = line.strip()
        if not line.startswith("|"):
            continue

        if "Download" not in line:
            continue

        # Remove markdown strikethrough markers from commit/blame pages if copied.
        clean = line.replace("~~", "")
        cells = [c.strip() for c in clean.strip("|").split("|")]

        if len(cells) < 5:
            continue

        runtime, precision, chipset, sdk_versions, download_cell = cells[:5]

        m = re.search(r"\]\((https?://[^)]+)\)", download_cell)
        if not m:
            continue

        if "QNN" not in runtime.upper() and "ONNX" not in runtime.upper():
            continue

        rows.append({
            "repo": repo,
            "runtime": runtime.strip(),
            "precision": precision.strip(),
            "chipset": chipset.replace("®", "").strip(),
            "sdk_versions": sdk_versions.strip(),
            "download_url": m.group(1).strip(),
        })

    return rows


def extract_versions(sdk_versions: str) -> Dict[str, Optional[str]]:
    qairt = None
    ort = None

    m = re.search(r"QAIRT\s*([0-9]+(?:\.[0-9]+)+)", sdk_versions, flags=re.I)
    if m:
        qairt = m.group(1)

    m = re.search(r"ONNX\s*Runtime\s*([0-9]+(?:\.[0-9]+)+)", sdk_versions, flags=re.I)
    if m:
        ort = m.group(1)

    return {"qairt": qairt, "onnxruntime": ort}


def score_candidate(row: Dict[str, str], target_chipset: Optional[str]) -> Tuple[int, List[str]]:
    score = 0
    reasons = []

    runtime_key = compact_key(row["runtime"])
    chipset_key = compact_key(row["chipset"])
    target_key = compact_key(target_chipset or "")

    # Runtime priority for Python ORT proof.
    if "precompiledqnnonnx" in runtime_key:
        score += 100
        reasons.append("preferred Python ONNX Runtime QNN proof artifact")
    elif "qdqonnx" in runtime_key:
        score += 70
        reasons.append("QDQ ONNX can be valid, but requires compile/session proof")
    elif "qnncontextbinary" in runtime_key:
        score += 30
        reasons.append("raw QNN context binary is lower priority for Python ORT unless paired with EPContext wrapper")
    else:
        score += 10
        reasons.append("unknown/less preferred runtime")

    # Chipset match.
    if target_key and chipset_key == target_key:
        score += 100
        reasons.append("exact chipset string match")
    elif target_key and (target_key in chipset_key or chipset_key in target_key):
        score += 80
        reasons.append("near chipset string match")
    elif target_key and "snapdragonxelite" in target_key and "snapdragonxelite" in chipset_key:
        score += 100
        reasons.append("Snapdragon X Elite match")
    elif target_key:
        score -= 20
        reasons.append(f"chipset differs from target: {target_chipset}")
    else:
        reasons.append("no target chipset available; runtime preference only")

    # Prefer artifacts with ORT version stated.
    versions = extract_versions(row["sdk_versions"])
    if versions["onnxruntime"]:
        score += 20
        reasons.append(f"declares ONNX Runtime {versions['onnxruntime']}")
    else:
        score -= 5
        reasons.append("no ONNX Runtime version declared")

    if versions["qairt"]:
        score += 10
        reasons.append(f"declares QAIRT {versions['qairt']}")

    # Prefer smaller model for first proof.
    repo_key = compact_key(row["repo"])
    if "whispertiny" in repo_key:
        score += 15
        reasons.append("Tiny model is preferred for first smoke proof")
    elif "whisperbase" in repo_key:
        score += 5
        reasons.append("Base model is acceptable but heavier than Tiny")

    return score, reasons


def model_slug_from_repo(repo: str) -> str:
    name = repo.split("/")[-1]
    # Qualcomm AI Hub commonly uses lowercase underscore slugs.
    return name.replace("-", "_").lower()


def build_candidate(row: Dict[str, str], target_chipset: Optional[str]) -> ArtifactCandidate:
    score, reasons = score_candidate(row, target_chipset)
    model_name = row["repo"].split("/")[-1]
    runtime = row["runtime"]

    if compact_key(runtime) == "precompiledqnnonnx":
        acquisition = "Download Hugging Face Qualcomm pre-exported ZIP; preserve ONNX + BIN layout."
    elif compact_key(runtime) == "qnncontextbinary":
        acquisition = "Download Hugging Face Qualcomm QNN context binary ZIP; not preferred for direct Python ORT proof unless wrapper/sample expects it."
    else:
        acquisition = "Download listed artifact and inspect layout before use."

    return ArtifactCandidate(
        repo=row["repo"],
        model_name=model_name,
        source=f"Hugging Face Qualcomm: {HF_MODEL_PAGE.format(repo=row['repo'])}",
        runtime=row["runtime"],
        precision=row["precision"],
        chipset=row["chipset"],
        sdk_versions=row["sdk_versions"],
        download_url=row["download_url"],
        acquisition_method=acquisition,
        score=score,
        reasons=reasons,
    )


def lookup_hf_candidates(repos: List[str], target_chipset: Optional[str]) -> List[ArtifactCandidate]:
    candidates = []

    for repo in repos:
        url = HF_RAW_README.format(repo=repo)
        try:
            readme = http_get(url)
        except Exception as e:
            print(f"WARN: failed to read {url}: {e}", file=sys.stderr)
            continue

        rows = parse_markdown_artifact_rows(repo, readme)
        for row in rows:
            candidates.append(build_candidate(row, target_chipset))

    candidates.sort(key=lambda c: c.score, reverse=True)
    return candidates


def ai_hub_fallback(model_repo: str, target_chipset: Optional[str]) -> Dict:
    model_slug = model_slug_from_repo(model_repo)
    return {
        "source": f"Qualcomm AI Hub: {AI_HUB_MODEL_PAGE.format(model_slug=model_slug)}",
        "runtime": "precompiled_qnn_onnx",
        "acquisition_method": (
            "Use Qualcomm AI Hub / qai-hub-models export for the exact target device. "
            "Export target runtime should be precompiled_qnn_onnx. "
            "Use the exact device name shown by AI Hub, not a guessed marketing name."
        ),
        "example_command_shape": (
            "python -m qai_hub_models.models.<model>.export "
            "--target-runtime precompiled_qnn_onnx "
            f"--device \"{target_chipset or '<exact AI Hub device name>'}\""
        ),
        "note": (
            "Use this path when no public Hugging Face ZIP exactly matches the device, "
            "or when a newer AI Hub compile is required."
        ),
    }


def load_probe(path: Optional[str]) -> Dict:
    if not path:
        return {}
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--probe", help="Path to qnn_device_probe_report.json")
    ap.add_argument("--chipset", help="Override detected chipset, e.g. 'Snapdragon X Elite'")
    ap.add_argument("--models", nargs="*", default=DEFAULT_MODELS, help="HF repos to inspect")
    ap.add_argument("--out", default="qnn_public_artifact_recommendation.json")
    ap.add_argument("--top", type=int, default=8)
    args = ap.parse_args()

    probe = load_probe(args.probe)
    target_chipset = args.chipset or extract_probe_chipset(probe)

    candidates = lookup_hf_candidates(args.models, target_chipset)
    best = candidates[0] if candidates else None

    result = {
        "target_chipset": target_chipset,
        "recommended": asdict(best) if best else None,
        "top_candidates": [asdict(c) for c in candidates[: args.top]],
        "ai_hub_fallback": ai_hub_fallback(args.models[0], target_chipset),
        "decision_rule": {
            "preferred_runtime": "precompiled_qnn_onnx",
            "preferred_source": "Hugging Face Qualcomm direct ZIP if exact chipset match exists; otherwise Qualcomm AI Hub export for exact device.",
            "not_preferred_for_first_python_ort_proof": [
                "raw qnn_context_binary without EPContext ONNX wrapper",
                "generic Whisper ONNX not compiled/validated for QNN",
                "artifact compiled for a different Snapdragon target",
            ],
        },
    }

    print(json.dumps(result, indent=2))
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2)

    print(f"\nWrote: {args.out}")


if __name__ == "__main__":
    main()
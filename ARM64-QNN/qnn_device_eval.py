# qnn_device_eval.py
#
# Combined QNN / ONNX Runtime / Whisper-style STT readiness evaluator.
#
# Outputs:
#   1) qnn_device_probe.json
#   2) qnn_device_recommendations.json
#   3) qnn_device_stt_readiness.log
#
# Host dependencies:
#   Python stdlib only.
#
# Venv created:
#   .venv-qnn
#
# Venv dependencies:
#   onnxruntime
#   onnxruntime-qnn
#   onnx
#   numpy
#
# Optional:
#   Put test.wav next to this script, or pass --test-wav C:\path\to\test.wav
#
# Typical usage:
#   python qnn_device_eval.py --artifact C:\path\to\artifact
#
# With public lookup and auto-download if recommendation exposes download_url:
#   python qnn_device_eval.py --download-dir .\qnn-artifacts
#
# Pin runtime versions:
#   python qnn_device_eval.py --ort-version 1.24.3 --qnn-package-version 2.1.0 --artifact C:\artifact

import argparse
import json
import os
import platform
import re
import subprocess
import sys
import time
import urllib.request
import zipfile
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple


PROBE_OUT = "qnn_device_probe.json"
RECOMMENDATIONS_OUT = "qnn_device_recommendations.json"
READINESS_LOG = "qnn_device_stt_readiness.log"
DEFAULT_VENV = ".venv-qnn"

DEFAULT_MODELS = [
    "qualcomm/Whisper-Tiny",
    "qualcomm/Whisper-Base",
]

HF_RAW_README = "https://huggingface.co/{repo}/raw/main/README.md"
HF_MODEL_PAGE = "https://huggingface.co/{repo}"
AI_HUB_MODEL_PAGE = "https://aihub.qualcomm.com/models/{model_slug}"


# --------------------------------------------------------------------------------------
# Logging / subprocess helpers
# --------------------------------------------------------------------------------------

def now():
    return time.strftime("%Y-%m-%d %H:%M:%S")


class Logger:
    def __init__(self, path: Path):
        self.path = path
        self.path.write_text("", encoding="utf-8")

    def write(self, message=""):
        msg = str(message)
        print(msg, flush=True)
        with self.path.open("a", encoding="utf-8") as f:
            f.write(msg + "\n")

    def step(self, number, title):
        self.write("")
        self.write(f"[{now()}] STEP {number}: {title}")
        self.write("-" * 88)


def run(cmd, log: Optional[Logger] = None, cwd=None, timeout=None, check=False):
    cmd = [str(x) for x in cmd]

    if log:
        log.write(f"$ {' '.join(cmd)}")

    try:
        p = subprocess.run(
            cmd,
            cwd=str(cwd) if cwd else None,
            text=True,
            capture_output=True,
            timeout=timeout,
            shell=False,
        )
        result = {
            "cmd": cmd,
            "rc": p.returncode,
            "stdout": p.stdout.strip(),
            "stderr": p.stderr.strip(),
        }
    except Exception as e:
        result = {
            "cmd": cmd,
            "rc": -1,
            "stdout": "",
            "stderr": repr(e),
        }

    if log:
        if result["stdout"]:
            log.write(result["stdout"])
        if result["stderr"]:
            log.write(result["stderr"])

    if check and result["rc"] != 0:
        raise RuntimeError(f"Command failed rc={result['rc']}: {' '.join(cmd)}")

    return result


def ps(command, log: Optional[Logger] = None):
    return run(
        [
            "powershell",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            command,
        ],
        log=log,
    )


def safe_json(text):
    if not text:
        return None
    try:
        return json.loads(text)
    except Exception:
        return text


def normalize_json_list(obj):
    if obj is None:
        return []
    if isinstance(obj, list):
        return obj
    return [obj]


def compact_key(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", (s or "").lower())


def venv_python(venv_dir: Path) -> Path:
    if os.name == "nt":
        return venv_dir / "Scripts" / "python.exe"
    return venv_dir / "bin" / "python"


# --------------------------------------------------------------------------------------
# Phase 1: device probe
# --------------------------------------------------------------------------------------

def get_os_info():
    info = {
        "platform": platform.platform(),
        "machine": platform.machine(),
        "processor": platform.processor(),
        "python": sys.version,
        "is_windows": os.name == "nt",
        "is_arm64": platform.machine().lower() in {"arm64", "aarch64"},
    }

    if os.name == "nt":
        r = ps(
            "Get-CimInstance Win32_OperatingSystem | "
            "Select-Object Caption,Version,BuildNumber,OSArchitecture | "
            "ConvertTo-Json -Compress"
        )
        info["windows_os_cim"] = safe_json(r["stdout"])
        info["windows_os_cim_raw"] = r

    return info


def get_soc_info():
    info = {}

    if os.name != "nt":
        return info

    cpu = ps(
        "Get-CimInstance Win32_Processor | "
        "Select-Object Name,Manufacturer,Architecture,NumberOfCores,NumberOfLogicalProcessors | "
        "ConvertTo-Json -Compress"
    )
    info["cpu"] = safe_json(cpu["stdout"])
    info["cpu_raw"] = cpu

    cs = ps(
        "Get-CimInstance Win32_ComputerSystem | "
        "Select-Object Manufacturer,Model,SystemType | "
        "ConvertTo-Json -Compress"
    )
    info["computer_system"] = safe_json(cs["stdout"])
    info["computer_system_raw"] = cs

    return info


def get_qualcomm_devices():
    info = {}

    if os.name != "nt":
        return info

    pnp = ps(
        "Get-CimInstance Win32_PnPEntity | "
        "Where-Object { "
        "$_.Name -match 'Qualcomm|Hexagon|NPU|Neural|AI|HTP|QNN|Snapdragon' -or "
        "$_.Manufacturer -match 'Qualcomm' "
        "} | "
        "Select-Object Name,Manufacturer,PNPClass,DeviceID,Status | "
        "ConvertTo-Json -Compress"
    )
    info["pnp_candidates"] = normalize_json_list(safe_json(pnp["stdout"]))
    info["pnp_candidates_raw"] = pnp

    drivers = ps(
        "Get-CimInstance Win32_PnPSignedDriver | "
        "Where-Object { "
        "$_.DeviceName -match 'Qualcomm|Hexagon|NPU|Neural|AI|HTP|QNN|Snapdragon' -or "
        "$_.Manufacturer -match 'Qualcomm' "
        "} | "
        "Select-Object DeviceName,Manufacturer,DriverVersion,DriverDate,InfName,DeviceID | "
        "ConvertTo-Json -Compress"
    )
    info["signed_driver_candidates"] = normalize_json_list(safe_json(drivers["stdout"]))
    info["signed_driver_candidates_raw"] = drivers

    return info


def inspect_artifact_dir_stdlib(path):
    if not path:
        return None

    root = Path(path)
    result = {
        "path": str(root),
        "exists": root.exists(),
        "files": [],
        "artifact_guess": None,
        "warnings": [],
    }

    if not root.exists():
        return result

    files = []
    for p in root.rglob("*"):
        if p.is_file():
            files.append(
                {
                    "relative": str(p.relative_to(root)),
                    "suffix": p.suffix.lower(),
                    "size_bytes": p.stat().st_size,
                }
            )

    result["files"] = files

    suffixes = {f["suffix"] for f in files}
    names = [f["relative"].lower() for f in files]

    has_onnx = ".onnx" in suffixes
    has_bin = ".bin" in suffixes
    has_dlc = ".dlc" in suffixes

    if has_onnx and has_bin:
        result["artifact_guess"] = "precompiled_qnn_onnx / EPContext-style ONNX + QNN context binary"
    elif has_onnx:
        result["artifact_guess"] = "plain ONNX or QDQ ONNX; graph inspection required"
    elif has_bin:
        result["artifact_guess"] = "raw QNN context binary; not preferred for direct Python ORT without ONNX wrapper"
    elif has_dlc:
        result["artifact_guess"] = "QNN/Genie DLC; not preferred for Python ORT Whisper proof"
    else:
        result["artifact_guess"] = "unknown"

    if has_onnx and has_bin:
        if not any(Path(n).name == "model.bin" for n in names):
            result["warnings"].append(
                "No model.bin found. Qualcomm samples often require preserving original .bin names/relative paths."
            )

    return result


def probe_recommendation(report):
    os_info = report.get("os", {})
    soc = report.get("soc", {})
    qdev = report.get("qualcomm_devices", {})
    artifact = report.get("artifact")

    rec = {
        "host_class": "unknown",
        "runtime_path": "unknown",
        "artifact_path": "unknown",
        "next_proof": [],
        "blocking_findings": [],
    }

    cpu_name = json.dumps(soc.get("cpu", ""), default=str).lower()
    pnp_text = json.dumps(qdev.get("pnp_candidates", []), default=str).lower()
    drv_text = json.dumps(qdev.get("signed_driver_candidates", []), default=str).lower()
    combined = cpu_name + " " + pnp_text + " " + drv_text

    is_windows = os_info.get("is_windows")
    is_arm64 = os_info.get("is_arm64")
    is_snapdragonish = any(
        x in combined
        for x in [
            "snapdragon",
            "qualcomm",
            "x1",
            "oryon",
            "hexagon",
            "npu",
            "neural",
            "htp",
        ]
    )

    if is_windows and is_arm64 and is_snapdragonish:
        rec["host_class"] = "Windows ARM64 Snapdragon-class host"
        rec["runtime_path"] = (
            "Prefer onnxruntime + onnxruntime-qnn plugin path, unless artifact metadata "
            "requires older built-in provider flow."
        )
        rec["artifact_path"] = "Prefer Qualcomm AI Hub/HF precompiled_qnn_onnx for this exact chipset."
    elif is_windows and is_arm64:
        rec["host_class"] = "Windows ARM64 host, Snapdragon/NPU not proven from system lookup"
        rec["runtime_path"] = "QNN proof may be blocked until Qualcomm NPU/HTP device and driver are visible."
        rec["artifact_path"] = "Do not select a device-specific QNN context binary until exact Snapdragon target is known."
        rec["blocking_findings"].append("Snapdragon/Qualcomm/NPU device identity not proven.")
    else:
        rec["host_class"] = "Not a Windows ARM64 Snapdragon proof host"
        rec["runtime_path"] = "Use this host only for CPU/export inspection, not final QNN NPU compatibility proof."
        rec["artifact_path"] = "Acquire artifact on/for the actual Snapdragon Windows ARM64 target."
        rec["blocking_findings"].append("Host is not confirmed Windows ARM64 Snapdragon.")

    if artifact:
        rec["next_proof"].append(f"Artifact guess: {artifact.get('artifact_guess')}")
        if artifact.get("warnings"):
            rec["blocking_findings"].extend(artifact["warnings"])
    else:
        rec["next_proof"].append("No artifact directory inspected.")

    return rec


def build_probe_report(artifact_path: Optional[str]):
    report = {
        "os": get_os_info(),
        "soc": get_soc_info(),
        "qualcomm_devices": get_qualcomm_devices(),
        "artifact": inspect_artifact_dir_stdlib(artifact_path),
    }
    report["recommendation"] = probe_recommendation(report)
    return report


# --------------------------------------------------------------------------------------
# Phase 2: public artifact recommendation lookup
# --------------------------------------------------------------------------------------

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
            "User-Agent": "qnn-device-eval/1.1",
            "Accept": "text/plain,text/markdown,text/html,*/*",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", errors="replace")


def extract_probe_chipset(probe: Dict) -> Optional[str]:
    cpu = probe.get("soc", {}).get("cpu")
    if isinstance(cpu, list) and cpu:
        cpu_text = json.dumps(cpu[0])
    else:
        cpu_text = json.dumps(cpu)

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

    if re.search(r"\bX1P\b|\bX1E\b|\bOryon\b|Snapdragon", combined, flags=re.I):
        return "Snapdragon X Elite"

    return None


def parse_markdown_artifact_rows(repo: str, readme: str) -> List[Dict[str, str]]:
    rows = []

    for line in readme.splitlines():
        line = line.strip()
        if not line.startswith("|"):
            continue
        if "Download" not in line:
            continue

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

        rows.append(
            {
                "repo": repo,
                "runtime": runtime.strip(),
                "precision": precision.strip(),
                "chipset": chipset.replace("®", "").strip(),
                "sdk_versions": sdk_versions.strip(),
                "download_url": m.group(1).strip(),
            }
        )

    return rows


def extract_versions(sdk_versions: str) -> Dict[str, Optional[str]]:
    qairt = None
    ort = None

    m = re.search(r"QAIRT\s*([0-9]+(?:\.[0-9]+)+)", sdk_versions or "", flags=re.I)
    if m:
        qairt = m.group(1)

    m = re.search(r"ONNX\s*Runtime\s*([0-9]+(?:\.[0-9]+)+)", sdk_versions or "", flags=re.I)
    if m:
        ort = m.group(1)

    return {"qairt": qairt, "onnxruntime": ort}


def score_candidate(row: Dict[str, str], target_chipset: Optional[str]) -> Tuple[int, List[str]]:
    score = 0
    reasons = []

    runtime_key = compact_key(row["runtime"])
    chipset_key = compact_key(row["chipset"])
    target_key = compact_key(target_chipset or "")

    if "precompiledqnnonnx" in runtime_key:
        score += 100
        reasons.append("preferred Python ONNX Runtime QNN proof artifact")
    elif "qdqonnx" in runtime_key:
        score += 70
        reasons.append("QDQ ONNX can be valid but requires compile/session proof")
    elif "qnncontextbinary" in runtime_key:
        score += 30
        reasons.append("raw QNN context binary is lower priority for Python ORT unless paired with EPContext wrapper")
    else:
        score += 10
        reasons.append("unknown/less preferred runtime")

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

    repo_key = compact_key(row["repo"])
    if "whispertiny" in repo_key:
        score += 15
        reasons.append("Tiny model is preferred for first smoke proof")
    elif "whisperbase" in repo_key:
        score += 5
        reasons.append("Base model is acceptable but heavier than Tiny")

    return score, reasons


def model_slug_from_repo(repo: str) -> str:
    return repo.split("/")[-1].replace("-", "_").lower()


def build_candidate(row: Dict[str, str], target_chipset: Optional[str]) -> ArtifactCandidate:
    score, reasons = score_candidate(row, target_chipset)

    runtime_key = compact_key(row["runtime"])
    if runtime_key == "precompiledqnnonnx":
        acquisition = "Download Hugging Face Qualcomm pre-exported ZIP; preserve ONNX + BIN relative layout."
    elif runtime_key == "qnncontextbinary":
        acquisition = (
            "Download Hugging Face Qualcomm QNN context binary ZIP; not preferred for direct Python ORT "
            "unless paired with EPContext ONNX wrapper."
        )
    else:
        acquisition = "Download listed artifact and inspect layout before use."

    return ArtifactCandidate(
        repo=row["repo"],
        model_name=row["repo"].split("/")[-1],
        source=HF_MODEL_PAGE.format(repo=row["repo"]),
        runtime=row["runtime"],
        precision=row["precision"],
        chipset=row["chipset"],
        sdk_versions=row["sdk_versions"],
        download_url=row["download_url"],
        acquisition_method=acquisition,
        score=score,
        reasons=reasons,
    )


def lookup_hf_candidates(repos: List[str], target_chipset: Optional[str], log: Logger) -> List[ArtifactCandidate]:
    candidates = []

    for repo in repos:
        url = HF_RAW_README.format(repo=repo)
        try:
            log.write(f"Public lookup: {url}")
            readme = http_get(url)
        except Exception as e:
            log.write(f"WARN: failed to read {url}: {e}")
            continue

        rows = parse_markdown_artifact_rows(repo, readme)
        for row in rows:
            candidates.append(build_candidate(row, target_chipset))

    candidates.sort(key=lambda c: c.score, reverse=True)
    return candidates


def ai_hub_fallback(model_repo: str, target_chipset: Optional[str]) -> Dict:
    model_slug = model_slug_from_repo(model_repo)
    return {
        "source": AI_HUB_MODEL_PAGE.format(model_slug=model_slug),
        "runtime": "precompiled_qnn_onnx",
        "acquisition_method": (
            "Use Qualcomm AI Hub / qai-hub-models export for the exact target device. "
            "Export target runtime should be precompiled_qnn_onnx."
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


def build_public_recommendations(probe_report: Dict, models: List[str], log: Logger) -> Dict:
    target_chipset = extract_probe_chipset(probe_report)
    candidates = lookup_hf_candidates(models, target_chipset, log)
    best = candidates[0] if candidates else None

    return {
        "target_chipset": target_chipset,
        "recommended": asdict(best) if best else None,
        "top_candidates": [asdict(c) for c in candidates[:8]],
        "ai_hub_fallback": ai_hub_fallback(models[0], target_chipset),
        "decision_rule": {
            "preferred_runtime": "precompiled_qnn_onnx",
            "preferred_source": (
                "Hugging Face Qualcomm direct ZIP if exact chipset match exists; "
                "otherwise Qualcomm AI Hub export for exact device."
            ),
            "not_preferred_for_first_python_ort_proof": [
                "raw qnn_context_binary without EPContext ONNX wrapper",
                "generic Whisper ONNX not compiled/validated for QNN",
                "artifact compiled for a different Snapdragon target",
            ],
        },
    }


# --------------------------------------------------------------------------------------
# Artifact acquisition
# --------------------------------------------------------------------------------------

def download_artifact(recommendations: Dict, download_dir: Path, log: Logger) -> Optional[Path]:
    rec = recommendations.get("recommended") if recommendations else None
    if not rec:
        log.write("No public recommended artifact found; skipping artifact download.")
        return None

    url = rec.get("download_url")
    if not url:
        log.write("Recommended artifact has no download_url; skipping artifact download.")
        return None

    download_dir.mkdir(parents=True, exist_ok=True)
    filename = url.split("?")[0].rstrip("/").split("/")[-1] or "artifact.zip"
    target = download_dir / filename

    if target.exists():
        log.write(f"Artifact archive already exists: {target}")
    else:
        log.write(f"Downloading artifact: {url}")
        log.write(f"Destination: {target}")
        req = urllib.request.Request(url, headers={"User-Agent": "qnn-device-eval/1.1"})
        with urllib.request.urlopen(req, timeout=180) as r:
            target.write_bytes(r.read())
        log.write(f"Downloaded {target.stat().st_size} bytes")

    if zipfile.is_zipfile(target):
        extract_dir = download_dir / target.stem
        marker = extract_dir / ".extracted"
        if marker.exists():
            log.write(f"Artifact already extracted: {extract_dir}")
        else:
            extract_dir.mkdir(parents=True, exist_ok=True)
            log.write(f"Extracting ZIP to: {extract_dir}")
            with zipfile.ZipFile(target, "r") as z:
                z.extractall(extract_dir)
            marker.write_text(now(), encoding="utf-8")
        return extract_dir

    return target.parent


# --------------------------------------------------------------------------------------
# Venv helper script for ORT/QNN/ONNX/Numpy surfaces
# --------------------------------------------------------------------------------------

def create_venv_helper_script(work_dir: Path) -> Path:
    helper = work_dir / "_qnn_device_eval_helper.py"
    helper.write_text(
        r'''
import argparse
import json
import re
import sys
import traceback
import wave
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort


def package_version(name):
    try:
        from importlib.metadata import version
        return version(name)
    except Exception as e:
        return f"unavailable: {repr(e)}"


def compact(s):
    return re.sub(r"[^a-z0-9]+", "", (s or "").lower())


def result(name, status, detail=None, evidence=None):
    return {
        "name": name,
        "status": status,
        "detail": detail,
        "evidence": evidence or {},
    }


def jdefault(obj):
    try:
        return str(obj)
    except Exception:
        return repr(obj)


def find_model_files(root):
    root = Path(root)
    onnx_files = list(root.rglob("*.onnx"))
    bin_files = list(root.rglob("*.bin"))

    files = {
        "root": str(root),
        "onnx_files": [str(p) for p in onnx_files],
        "bin_files": [str(p) for p in bin_files],
        "encoder_candidates": [],
        "decoder_candidates": [],
        "other_onnx": [],
    }

    for p in onnx_files:
        key = compact(p.name + " " + str(p.parent))
        if "encoder" in key:
            files["encoder_candidates"].append(str(p))
        elif "decoder" in key:
            files["decoder_candidates"].append(str(p))
        else:
            files["other_onnx"].append(str(p))

    return files


def onnx_metadata(path):
    m = onnx.load(path, load_external_data=False)

    node_types = {}
    for n in m.graph.node:
        node_types[n.op_type] = node_types.get(n.op_type, 0) + 1

    def value_info(v):
        t = v.type.tensor_type
        shape = []
        for d in t.shape.dim:
            if d.dim_value:
                shape.append(d.dim_value)
            elif d.dim_param:
                shape.append(d.dim_param)
            else:
                shape.append(None)
        return {
            "name": v.name,
            "elem_type": t.elem_type,
            "shape": shape,
        }

    epcontext_nodes = []
    for n in m.graph.node:
        if n.op_type == "EPContext":
            attrs = {}
            for a in n.attribute:
                try:
                    val = onnx.helper.get_attribute_value(a)
                    if isinstance(val, bytes):
                        val = val.decode("utf-8", errors="replace")
                    attrs[a.name] = val
                except Exception:
                    attrs[a.name] = "<unreadable>"
            epcontext_nodes.append({"name": n.name, "domain": n.domain, "attrs": attrs})

    return {
        "path": str(path),
        "ir_version": m.ir_version,
        "producer_name": m.producer_name,
        "producer_version": m.producer_version,
        "opset_import": [{"domain": x.domain, "version": x.version} for x in m.opset_import],
        "inputs": [value_info(v) for v in m.graph.input],
        "outputs": [value_info(v) for v in m.graph.output],
        "node_types": node_types,
        "has_qdq": bool(node_types.get("QuantizeLinear") or node_types.get("DequantizeLinear")),
        "has_epcontext": bool(epcontext_nodes),
        "epcontext_nodes": epcontext_nodes,
    }


def infer_artifact_type(files, metas):
    has_bin = bool(files["bin_files"])
    has_epcontext = any(m.get("has_epcontext") for m in metas)
    has_qdq = any(m.get("has_qdq") for m in metas)

    if has_epcontext and has_bin:
        return "precompiled_qnn_onnx / EPContext ONNX + external QNN context binary"
    if has_epcontext:
        return "EPContext ONNX, possibly embedded context"
    if has_qdq:
        return "QDQ ONNX"
    if has_bin and not files["onnx_files"]:
        return "raw QNN context binary only"
    if files["onnx_files"]:
        return "plain ONNX or unknown ONNX"
    return "unknown"


def register_qnn_provider():
    out = {
        "ort_version": getattr(ort, "__version__", None),
        "installed_packages": {
            "onnxruntime": package_version("onnxruntime"),
            "onnxruntime-qnn": package_version("onnxruntime-qnn"),
            "onnx": package_version("onnx"),
            "numpy": package_version("numpy"),
        },
        "available_providers_before": ort.get_available_providers(),
        "plugin_import": None,
        "registration": None,
        "qnn_ep_devices": [],
        "provider_options": {},
        "visibility_interpretation": None,
    }

    try:
        import onnxruntime_qnn as qnn_ep
        out["plugin_import"] = "PASS"
        out["provider_options"]["library_path"] = qnn_ep.get_library_path()
        out["provider_options"]["backend_path"] = qnn_ep.get_qnn_htp_path()

        try:
            ort.register_execution_provider_library("QNNExecutionProvider", qnn_ep.get_library_path())
            out["registration"] = "PASS"
        except Exception as e:
            out["registration"] = f"FAIL: {repr(e)}"

        try:
            devices = ort.get_ep_devices()
            out["all_ep_devices"] = [str(d) for d in devices]
            out["qnn_ep_devices"] = [
                str(d) for d in devices
                if getattr(d, "ep_name", None) == "QNNExecutionProvider"
            ]
        except Exception as e:
            out["ep_devices_error"] = repr(e)

        out["available_providers_after"] = ort.get_available_providers()

        if out["registration"] == "PASS" and out["qnn_ep_devices"]:
            out["visibility_interpretation"] = (
                "plugin-style QNN provider success: registration passed and QNN EP devices were discovered. "
                "It is acceptable if get_available_providers() still lists only built-in providers."
            )
        elif "QNNExecutionProvider" in out["available_providers_after"]:
            out["visibility_interpretation"] = "built-in/provider-list QNN provider is visible."
        else:
            out["visibility_interpretation"] = "QNN provider was not proven visible."

        return out

    except Exception as e:
        out["plugin_import"] = f"FAIL: {repr(e)}"
        out["available_providers_after"] = ort.get_available_providers()
        out["visibility_interpretation"] = "onnxruntime_qnn import failed; plugin-style QNN provider unavailable."
        return out


def make_session_options(provider_registration, disable_cpu_fallback=True):
    so = ort.SessionOptions()
    if disable_cpu_fallback:
        so.add_session_config_entry("session.disable_cpu_ep_fallback", "1")

    plugin_error = None

    try:
        devices = ort.get_ep_devices()
        qnn_devices = [
            d for d in devices
            if getattr(d, "ep_name", None) == "QNNExecutionProvider"
        ]
        backend_path = provider_registration.get("provider_options", {}).get("backend_path")
        if qnn_devices and backend_path and hasattr(so, "add_provider_for_devices"):
            so.add_provider_for_devices(qnn_devices, {"backend_path": backend_path})
            return so, "plugin_add_provider_for_devices", None
    except Exception as e:
        plugin_error = repr(e)

    return so, "provider_list_fallback", plugin_error


def load_session(path, provider_registration):
    so, style, plugin_error = make_session_options(provider_registration)

    evidence = {
        "path": str(path),
        "style": style,
        "plugin_error": plugin_error,
        "cpu_fallback_disabled": True,
    }

    try:
        if style == "plugin_add_provider_for_devices":
            sess = ort.InferenceSession(str(path), sess_options=so)
        else:
            backend_path = provider_registration.get("provider_options", {}).get("backend_path")
            if backend_path:
                sess = ort.InferenceSession(
                    str(path),
                    sess_options=so,
                    providers=["QNNExecutionProvider"],
                    provider_options=[{"backend_path": backend_path}],
                )
            else:
                sess = ort.InferenceSession(
                    str(path),
                    sess_options=so,
                    providers=["QNNExecutionProvider"],
                )

        evidence["providers"] = sess.get_providers()
        evidence["provider_options"] = sess.get_provider_options()
        evidence["inputs"] = [
            {"name": x.name, "type": x.type, "shape": x.shape}
            for x in sess.get_inputs()
        ]
        evidence["outputs"] = [
            {"name": x.name, "type": x.type, "shape": x.shape}
            for x in sess.get_outputs()
        ]
        return sess, result("session_load", "PASS", evidence=evidence)

    except Exception as e:
        evidence["error"] = repr(e)
        evidence["traceback"] = traceback.format_exc()
        return None, result("session_load", "FAIL", detail=repr(e), evidence=evidence)


def dtype_from_ort_type(t):
    t = (t or "").lower()
    if "float16" in t:
        return np.float16
    if "float" in t:
        return np.float32
    if "double" in t:
        return np.float64
    if "int64" in t:
        return np.int64
    if "int32" in t:
        return np.int32
    if "int16" in t:
        return np.int16
    if "int8" in t:
        return np.int8
    if "uint8" in t:
        return np.uint8
    if "bool" in t:
        return bool
    return np.float32


def concrete_shape(shape):
    result_shape = []

    for dim in shape:
        if isinstance(dim, int) and dim > 0:
            result_shape.append(dim)
            continue

        if isinstance(dim, str):
            key = compact(dim)
            if key in {"batch", "batchsize", "n"}:
                result_shape.append(1)
            elif "sequence" in key or "seqlen" in key or key in {"s", "t"}:
                result_shape.append(1)
            elif "audio" in key or "mel" in key or "feature" in key:
                result_shape.append(80)
            else:
                result_shape.append(1)
            continue

        result_shape.append(1)

    safe = []
    for x in result_shape:
        if x is None or x <= 0:
            safe.append(1)
        elif x > 4096:
            safe.append(1)
        else:
            safe.append(x)

    return safe


def make_input_array(inp):
    shape = concrete_shape(inp.shape)
    dtype = dtype_from_ort_type(inp.type)

    name = compact(inp.name)
    if np.issubdtype(np.dtype(dtype), np.integer):
        arr = np.zeros(shape, dtype=dtype)
        if "token" in name or "inputids" in name:
            arr[...] = 50258 if arr.size else 0
        return arr

    return np.zeros(shape, dtype=dtype)


def run_synthetic_inference(sess):
    evidence = {"inputs": [], "outputs": []}
    feed = {}

    for inp in sess.get_inputs():
        arr = make_input_array(inp)
        feed[inp.name] = arr
        evidence["inputs"].append(
            {
                "name": inp.name,
                "ort_type": inp.type,
                "ort_shape": inp.shape,
                "actual_shape": list(arr.shape),
                "dtype": str(arr.dtype),
            }
        )

    try:
        out = sess.run(None, feed)
        for item in out:
            if hasattr(item, "shape"):
                evidence["outputs"].append(
                    {"shape": list(item.shape), "dtype": str(item.dtype)}
                )
            else:
                evidence["outputs"].append({"type": type(item).__name__})
        return result("synthetic_inference", "PASS", evidence=evidence)

    except Exception as e:
        evidence["error"] = repr(e)
        evidence["traceback"] = traceback.format_exc()
        return result(
            "synthetic_inference",
            "FAIL_OR_NEEDS_ARTIFACT_SPECIFIC_INPUTS",
            detail=repr(e),
            evidence=evidence,
        )


def inspect_wav(path):
    p = Path(path)
    if not p.exists():
        return result(
            "8_real_audio_smoke_test",
            "WARN",
            detail=f"test.wav not present: {p}",
            evidence={"test_wav": str(p)},
        )

    try:
        with wave.open(str(p), "rb") as w:
            evidence = {
                "test_wav": str(p),
                "channels": w.getnchannels(),
                "sample_width_bytes": w.getsampwidth(),
                "sample_rate_hz": w.getframerate(),
                "frame_count": w.getnframes(),
                "duration_seconds": round(w.getnframes() / float(w.getframerate()), 3)
                if w.getframerate()
                else None,
            }

        wav_ok = (
            evidence["channels"] in {1, 2}
            and evidence["sample_width_bytes"] in {2, 4}
            and evidence["sample_rate_hz"] in {16000, 44100, 48000}
            and evidence["duration_seconds"] is not None
            and evidence["duration_seconds"] > 0
        )

        if not wav_ok:
            return result(
                "8_real_audio_smoke_test",
                "WARN",
                detail="test.wav exists but does not look like a straightforward PCM WAV for smoke testing.",
                evidence=evidence,
            )

        return result(
            "8_real_audio_smoke_test",
            "NEEDS_ARTIFACT_SPECIFIC_ADAPTER",
            detail=(
                "test.wav exists and is readable. Full transcript proof requires artifact-specific "
                "audio preprocessing, tokenizer, decoder loop, and KV-cache handling."
            ),
            evidence=evidence,
        )

    except Exception as e:
        return result(
            "8_real_audio_smoke_test",
            "WARN",
            detail=f"test.wav exists but could not be read as WAV: {repr(e)}",
            evidence={"test_wav": str(p), "traceback": traceback.format_exc()},
        )


def choose_encoder_decoder(files):
    encoder_path = files["encoder_candidates"][0] if files["encoder_candidates"] else None
    decoder_path = files["decoder_candidates"][0] if files["decoder_candidates"] else None

    if not encoder_path and len(files["onnx_files"]) == 2:
        encoder_path = files["onnx_files"][0]

    if not decoder_path and len(files["onnx_files"]) == 2:
        decoder_path = files["onnx_files"][1]

    if not encoder_path and len(files["onnx_files"]) == 1:
        encoder_path = files["onnx_files"][0]

    return encoder_path, decoder_path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--artifact", required=True)
    ap.add_argument("--probe", required=True)
    ap.add_argument("--recommendations", required=True)
    ap.add_argument("--test-wav", required=True)
    args = ap.parse_args()

    probe = json.loads(Path(args.probe).read_text(encoding="utf-8"))
    recommendations = json.loads(Path(args.recommendations).read_text(encoding="utf-8"))

    readiness = {
        "steps": [],
        "artifact": {},
        "provider": {},
        "sessions": {},
        "final": {},
    }

    # Step 0
    readiness["steps"].append(
        result(
            "0_define_exact_target",
            "PASS",
            evidence={
                "probe_recommendation": probe.get("recommendation"),
                "host_os": probe.get("os"),
                "soc": probe.get("soc"),
                "qualcomm_device_candidates": probe.get("qualcomm_devices", {}),
                "artifact_recommendation": recommendations.get("recommended"),
                "runtime_request": recommendations.get("runtime_request"),
            },
        )
    )

    # Step 1
    readiness["steps"].append(
        result(
            "1_install_exact_runtime_package",
            "PASS",
            evidence={
                "python": sys.version,
                "installed_packages": {
                    "onnxruntime": package_version("onnxruntime"),
                    "onnxruntime-qnn": package_version("onnxruntime-qnn"),
                    "onnx": package_version("onnx"),
                    "numpy": package_version("numpy"),
                },
                "onnxruntime_version": getattr(ort, "__version__", None),
                "available_providers": ort.get_available_providers(),
                "runtime_request": recommendations.get("runtime_request"),
                "runtime_pairing_note": recommendations.get("runtime_pairing_note"),
            },
        )
    )

    # Step 2 / 3
    files = find_model_files(args.artifact)
    metas = []
    meta_results = []

    for f in files["onnx_files"]:
        try:
            md = onnx_metadata(f)
            metas.append(md)
            meta_results.append(result("inspect_onnx", "PASS", evidence=md))
        except Exception as e:
            meta_results.append(result("inspect_onnx", "FAIL", detail=f"{f}: {repr(e)}"))

    artifact_type = infer_artifact_type(files, metas)

    readiness["artifact"] = {
        "files": files,
        "onnx_metadata": metas,
        "artifact_type_guess": artifact_type,
    }

    readiness["steps"].append(
        result(
            "2_acquire_exact_artifact",
            "PASS" if files["onnx_files"] else "FAIL",
            detail=None if files["onnx_files"] else "No .onnx files found under artifact directory.",
            evidence={
                "artifact_root": str(args.artifact),
                "onnx_count": len(files["onnx_files"]),
                "bin_count": len(files["bin_files"]),
            },
        )
    )

    readiness["steps"].append(
        result(
            "3_inspect_artifact_metadata_layout",
            "PASS" if files["onnx_files"] else "FAIL",
            evidence={
                "artifact_type_guess": artifact_type,
                "metadata_results": meta_results,
            },
        )
    )

    # Step 4
    provider = register_qnn_provider()
    readiness["provider"] = provider

    qnn_visible = (
        bool(provider.get("qnn_ep_devices"))
        or "QNNExecutionProvider" in provider.get("available_providers_after", [])
    )

    readiness["steps"].append(
        result(
            "4_verify_provider_visibility",
            "PASS" if qnn_visible else "FAIL",
            detail=None if qnn_visible else "QNNExecutionProvider not visible/discoverable.",
            evidence=provider,
        )
    )

    encoder_path, decoder_path = choose_encoder_decoder(files)

    # Step 5
    encoder_sess = None
    if encoder_path:
        encoder_sess, enc = load_session(encoder_path, provider)
        enc["name"] = "5_load_encoder_session"
        readiness["steps"].append(enc)
        readiness["sessions"]["encoder"] = enc
    else:
        readiness["steps"].append(
            result(
                "5_load_encoder_session",
                "FAIL",
                detail="No encoder candidate found.",
                evidence=files,
            )
        )

    # Step 6
    decoder_sess = None
    if decoder_path:
        decoder_sess, dec = load_session(decoder_path, provider)
        dec["name"] = "6_load_decoder_session"
        readiness["steps"].append(dec)
        readiness["sessions"]["decoder"] = dec
    else:
        readiness["steps"].append(
            result(
                "6_load_decoder_session",
                "SKIP_OR_NOT_APPLICABLE",
                detail="No decoder candidate found. Single-model artifact or incomplete artifact layout.",
                evidence=files,
            )
        )

    # Step 7
    if encoder_sess:
        syn = run_synthetic_inference(encoder_sess)
        syn["name"] = "7_smallest_encoder_inference"
        readiness["steps"].append(syn)
    else:
        readiness["steps"].append(
            result("7_smallest_encoder_inference", "SKIP", detail="Encoder session did not load.")
        )

    if decoder_sess:
        syn = run_synthetic_inference(decoder_sess)
        syn["name"] = "7_smallest_decoder_inference"
        readiness["steps"].append(syn)
    else:
        readiness["steps"].append(
            result(
                "7_smallest_decoder_inference",
                "SKIP_OR_NOT_APPLICABLE",
                detail="Decoder session did not load or decoder not present.",
            )
        )

    # Step 8
    readiness["steps"].append(inspect_wav(args.test_wav))

    # Step 9
    hard_fail_steps = [s for s in readiness["steps"] if s["status"] == "FAIL"]
    warnings = [s for s in readiness["steps"] if s["status"] == "WARN"]

    encoder_load_pass = any(
        s["name"] == "5_load_encoder_session" and s["status"] == "PASS"
        for s in readiness["steps"]
    )

    decoder_required = bool(decoder_path)
    decoder_load_pass = any(
        s["name"] == "6_load_decoder_session" and s["status"] == "PASS"
        for s in readiness["steps"]
    )

    provider_pass = any(
        s["name"] == "4_verify_provider_visibility" and s["status"] == "PASS"
        for s in readiness["steps"]
    )

    synthetic_statuses = {
        s["name"]: s["status"]
        for s in readiness["steps"]
        if s["name"].startswith("7_smallest_")
    }

    if hard_fail_steps:
        final_status = "FAIL"
    elif provider_pass and encoder_load_pass and (not decoder_required or decoder_load_pass):
        final_status = "PASS_LOAD_PROOF__AUDIO_TRANSCRIPT_NOT_CLAIMED"
    else:
        final_status = "INCOMPLETE"

    final = result(
        "9_define_pass_fail_evidence",
        final_status,
        evidence={
            "cpu_fallback_disabled": True,
            "encoder_path": encoder_path,
            "decoder_path": decoder_path,
            "artifact_type_guess": artifact_type,
            "hard_fail_steps": [s["name"] for s in hard_fail_steps],
            "warnings": [s["name"] for s in warnings],
            "synthetic_inference_statuses": synthetic_statuses,
            "test_wav": str(args.test_wav),
            "installed_packages": provider.get("installed_packages", {}),
            "runtime_request": recommendations.get("runtime_request"),
            "runtime_pairing_note": recommendations.get("runtime_pairing_note"),
            "provider_visibility_interpretation": provider.get("visibility_interpretation"),
            "pass_definition": {
                "provider_visible": provider_pass,
                "encoder_session_loaded": encoder_load_pass,
                "decoder_session_loaded_if_required": (not decoder_required or decoder_load_pass),
                "real_audio_transcript_claimed": False,
            },
            "claim": (
                "PASS_LOAD_PROOF__AUDIO_TRANSCRIPT_NOT_CLAIMED proves package/provider/artifact "
                "session compatibility only. It does not prove full STT transcript quality until an "
                "artifact-specific preprocessing/tokenizer/decode-loop adapter runs test.wav end to end."
            ),
        },
    )

    readiness["steps"].append(final)
    readiness["final"] = final

    print(json.dumps(readiness, indent=2, default=jdefault))


if __name__ == "__main__":
    main()
''',
        encoding="utf-8",
    )
    return helper


# --------------------------------------------------------------------------------------
# Runtime pinning / venv setup
# --------------------------------------------------------------------------------------

def extract_ort_version_from_text(text):
    if not text:
        return None
    m = re.search(r"ONNX\s*Runtime\s*([0-9]+(?:\.[0-9]+)+)", text, flags=re.I)
    if m:
        return m.group(1)
    return None


def derive_runtime_request(args, recommendations: Dict):
    rec = recommendations.get("recommended") if recommendations else None
    sdk_versions = rec.get("sdk_versions", "") if rec else ""

    requested_ort = args.ort_version or extract_ort_version_from_text(sdk_versions)
    requested_qnn = args.qnn_package_version

    if requested_ort:
        ort_request = {
            "package": "onnxruntime",
            "requested": requested_ort,
            "specifier": f"onnxruntime=={requested_ort}",
            "source": "cli_override" if args.ort_version else "artifact_metadata",
        }
    else:
        ort_request = {
            "package": "onnxruntime",
            "requested": "latest",
            "specifier": "onnxruntime",
            "source": "default_latest",
            "reason": "No ONNX Runtime version was declared by artifact metadata and no CLI override was supplied.",
        }

    if requested_qnn:
        qnn_request = {
            "package": "onnxruntime-qnn",
            "requested": requested_qnn,
            "specifier": f"onnxruntime-qnn=={requested_qnn}",
            "source": "cli_override",
        }
    else:
        qnn_request = {
            "package": "onnxruntime-qnn",
            "requested": "latest",
            "specifier": "onnxruntime-qnn",
            "source": "default_latest",
            "reason": "Artifact metadata did not declare an onnxruntime-qnn Python package version.",
        }

    note_parts = []
    if rec:
        note_parts.append(f"Artifact SDK metadata: {sdk_versions or 'not declared'}.")
    note_parts.append(f"ONNX Runtime request: {ort_request['requested']}.")
    note_parts.append(f"onnxruntime-qnn request: {qnn_request['requested']}.")
    if qnn_request["requested"] == "latest":
        note_parts.append(
            "A null/missing qnn package pin is reported as latest by design; installed version is captured after pip resolution."
        )

    return {
        "onnxruntime": ort_request,
        "onnxruntime_qnn": qnn_request,
        "runtime_pairing_note": " ".join(note_parts),
    }


def ensure_venv_and_packages(args, runtime_request: Dict, log: Logger) -> Path:
    venv_dir = Path(args.venv)
    py = venv_python(venv_dir)

    if not venv_dir.exists():
        log.write(f"Creating venv: {venv_dir}")
        run([sys.executable, "-m", "venv", str(venv_dir)], log=log, check=True)
    else:
        log.write(f"Using existing venv: {venv_dir}")

    run([str(py), "-m", "pip", "install", "--upgrade", "pip"], log=log, check=True)

    if args.no_install:
        log.write("--no-install set; skipping package installation.")
        return py

    packages = [
        runtime_request["onnxruntime"]["specifier"],
        runtime_request["onnxruntime_qnn"]["specifier"],
        "onnx",
        "numpy",
    ]

    log.write("Package install request:")
    log.write(json.dumps(packages, indent=2))

    run([str(py), "-m", "pip", "install", *packages], log=log, check=True)

    freeze = run([str(py), "-m", "pip", "freeze"], log=None, check=False)
    installed = {}
    for line in freeze.get("stdout", "").splitlines():
        key = line.lower()
        for pkg in ["onnxruntime", "onnxruntime-qnn", "onnx", "numpy"]:
            if key.startswith(pkg.lower() + "=="):
                installed[pkg] = line.split("==", 1)[1]

    runtime_request["installed_runtime"] = installed
    log.write("Installed runtime evidence:")
    log.write(json.dumps(installed, indent=2))

    return py


# --------------------------------------------------------------------------------------
# Main orchestration
# --------------------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--artifact", help="Local artifact directory containing ONNX/BIN files")
    ap.add_argument("--download-dir", default="qnn-artifacts")
    ap.add_argument("--test-wav", default="test.wav")
    ap.add_argument("--venv", default=DEFAULT_VENV)
    ap.add_argument("--models", nargs="*", default=DEFAULT_MODELS)
    ap.add_argument("--ort-version", help="Override ONNX Runtime version, e.g. 1.24.3")
    ap.add_argument("--qnn-package-version", help="Override onnxruntime-qnn package version, e.g. 2.1.0")
    ap.add_argument("--no-install", action="store_true")
    ap.add_argument("--no-download", action="store_true")
    args = ap.parse_args()

    log = Logger(Path(READINESS_LOG))

    log.write(f"QNN device eval started: {now()}")
    log.write(f"Working directory: {Path.cwd()}")
    log.write(f"Python host: {sys.executable}")
    log.write(f"Platform: {platform.platform()}")

    artifact_path = Path(args.artifact).resolve() if args.artifact else None

    # Step 0 starts with device target definition.
    log.step(0, "Define exact target from local system probe")

    probe_report = build_probe_report(str(artifact_path) if artifact_path else None)
    Path(PROBE_OUT).write_text(json.dumps(probe_report, indent=2), encoding="utf-8")
    log.write(f"Wrote {PROBE_OUT}")
    log.write(json.dumps(probe_report.get("recommendation"), indent=2))

    # Public recommendations.
    log.write("")
    log.write("Public artifact lookup / recommendation")
    log.write("-" * 88)

    recommendations = build_public_recommendations(probe_report, args.models, log)

    runtime_request = derive_runtime_request(args, recommendations)
    recommendations["runtime_request"] = runtime_request
    recommendations["runtime_pairing_note"] = runtime_request["runtime_pairing_note"]

    Path(RECOMMENDATIONS_OUT).write_text(json.dumps(recommendations, indent=2), encoding="utf-8")
    log.write(f"Wrote {RECOMMENDATIONS_OUT}")
    log.write("Recommended artifact:")
    log.write(json.dumps(recommendations.get("recommended"), indent=2))
    log.write("Runtime request:")
    log.write(json.dumps(runtime_request, indent=2))

    # Acquire artifact if not supplied.
    log.step(2, "Acquire exact artifact")

    if artifact_path and artifact_path.exists():
        log.write(f"Using provided artifact: {artifact_path}")
    elif args.no_download:
        log.write("WARN: no artifact provided and --no-download set.")
        artifact_path = None
    else:
        artifact_path = download_artifact(recommendations, Path(args.download_dir), log)

    if not artifact_path or not Path(artifact_path).exists():
        final = {
            "name": "9_define_pass_fail_evidence",
            "status": "FAIL",
            "detail": "No artifact directory available. Pass --artifact or allow download from qnn_device_recommendations.json.",
            "evidence": {
                "outputs": {
                    "probe": PROBE_OUT,
                    "recommendations": RECOMMENDATIONS_OUT,
                    "log": READINESS_LOG,
                }
            },
        }
        log.step(9, "Define pass/fail evidence")
        log.write(json.dumps(final, indent=2))

        recommendations["stt_readiness_final"] = final
        Path(RECOMMENDATIONS_OUT).write_text(json.dumps(recommendations, indent=2), encoding="utf-8")
        return 1

    # Runtime setup.
    log.step(1, "Install exact runtime package in .venv-qnn")

    log.write("Runtime request:")
    log.write(json.dumps(runtime_request, indent=2))

    py = ensure_venv_and_packages(args, runtime_request, log)

    recommendations["runtime_request"] = runtime_request
    recommendations["runtime_pairing_note"] = runtime_request["runtime_pairing_note"]
    Path(RECOMMENDATIONS_OUT).write_text(json.dumps(recommendations, indent=2), encoding="utf-8")

    # Helper does steps 3-9 and emits JSON to stdout.
    helper = create_venv_helper_script(Path.cwd())

    log.step(3, "Inspect artifact metadata/layout")
    log.write(f"Artifact queued for helper: {artifact_path}")

    log.step(4, "Verify provider visibility")
    log.write(
        "Provider registration/discovery runs inside .venv-qnn helper. "
        "For plugin-style QNN, get_ep_devices() evidence is stronger than get_available_providers()."
    )

    log.step(5, "Load encoder/session")
    log.write("Encoder session load runs with CPU fallback disabled.")

    log.step(6, "Load decoder/session")
    log.write("Decoder session load runs with CPU fallback disabled when decoder candidate exists.")

    log.step(7, "Run smallest inference/smoke test")
    log.write("Synthetic zero-input inference is attempted using ONNX Runtime input metadata.")

    log.step(8, "Run one real audio smoke test")
    test_wav = Path(args.test_wav).resolve()
    if not test_wav.exists():
        log.write(f"WARN: {test_wav} not present. Step 8 will be WARN.")
    else:
        log.write(f"test.wav found: {test_wav}")
        log.write(
            "Generic evaluator validates WAV readability only. Full transcript proof still needs "
            "artifact-specific Whisper preprocessing/tokenizer/decode loop."
        )

    log.step(9, "Define pass/fail evidence")

    cmd = [
        str(py),
        str(helper),
        "--artifact",
        str(Path(artifact_path).resolve()),
        "--probe",
        str(Path(PROBE_OUT).resolve()),
        "--recommendations",
        str(Path(RECOMMENDATIONS_OUT).resolve()),
        "--test-wav",
        str(test_wav),
    ]

    helper_result = run(cmd, log=log, check=False)

    if helper_result["rc"] != 0:
        final = {
            "name": "9_define_pass_fail_evidence",
            "status": "FAIL",
            "detail": "Helper failed before producing readiness evidence.",
            "evidence": {
                "helper_return_code": helper_result["rc"],
                "outputs": {
                    "probe": PROBE_OUT,
                    "recommendations": RECOMMENDATIONS_OUT,
                    "log": READINESS_LOG,
                },
            },
        }
        log.write(json.dumps(final, indent=2))
        recommendations["stt_readiness_final"] = final
        Path(RECOMMENDATIONS_OUT).write_text(json.dumps(recommendations, indent=2), encoding="utf-8")
        return helper_result["rc"]

    try:
        readiness = json.loads(helper_result["stdout"])
    except Exception:
        final = {
            "name": "9_define_pass_fail_evidence",
            "status": "FAIL",
            "detail": "Helper completed but stdout was not valid JSON.",
            "evidence": {
                "outputs": {
                    "probe": PROBE_OUT,
                    "recommendations": RECOMMENDATIONS_OUT,
                    "log": READINESS_LOG,
                },
            },
        }
        log.write(json.dumps(final, indent=2))
        recommendations["stt_readiness_final"] = final
        Path(RECOMMENDATIONS_OUT).write_text(json.dumps(recommendations, indent=2), encoding="utf-8")
        return 1

    final = readiness.get("final", {})
    recommendations["stt_readiness"] = readiness
    recommendations["stt_readiness_final"] = final
    recommendations["outputs"] = {
        "probe": PROBE_OUT,
        "recommendations": RECOMMENDATIONS_OUT,
        "log": READINESS_LOG,
    }

    Path(RECOMMENDATIONS_OUT).write_text(json.dumps(recommendations, indent=2), encoding="utf-8")

    log.write("")
    log.write("FINAL")
    log.write("-" * 88)
    log.write(json.dumps(final, indent=2))
    log.write("")
    log.write("Outputs:")
    log.write(f"  {PROBE_OUT}")
    log.write(f"  {RECOMMENDATIONS_OUT}")
    log.write(f"  {READINESS_LOG}")

    return 0 if final.get("status", "").startswith("PASS") else 1


if __name__ == "__main__":
    raise SystemExit(main())
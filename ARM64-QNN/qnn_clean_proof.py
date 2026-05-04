# qnn_clean_proof.py
#
# Purpose:
#   Run the clean QNN/ONNX Runtime compatibility proof sequence using:
#     - qnn_device_probe_report.json
#     - optional qnn_public_artifact_recommendation.json
#     - optional local artifact directory
#
# Host dependencies:
#   Python stdlib only.
#
# Venv dependencies installed into .venv-qnn:
#   onnxruntime
#   onnxruntime-qnn
#   onnx
#   numpy
#
# Example:
#   python qnn_clean_proof.py ^
#     --probe qnn_device_probe_report.json ^
#     --recommendation qnn_public_artifact_recommendation.json ^
#     --artifact C:\path\to\downloaded\artifact
#
# If artifact is not already downloaded:
#   python qnn_clean_proof.py ^
#     --probe qnn_device_probe_report.json ^
#     --recommendation qnn_public_artifact_recommendation.json ^
#     --download-dir .\qnn-artifacts
#
# Optional pin overrides:
#   python qnn_clean_proof.py --ort-version 1.24.3 --qnn-package-version 2.1.0 ...

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import textwrap
import time
import urllib.request
import zipfile
from pathlib import Path


DEFAULT_VENV = ".venv-qnn"
REPORT_NAME = "qnn_clean_proof_report.json"
LOG_NAME = "qnn_clean_proof.log"


def now():
    return time.strftime("%Y-%m-%d %H:%M:%S")


class Logger:
    def __init__(self, log_path: Path):
        self.log_path = log_path
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        self.log_path.write_text("", encoding="utf-8")

    def write(self, msg=""):
        line = str(msg)
        print(line, flush=True)
        with self.log_path.open("a", encoding="utf-8") as f:
            f.write(line + "\n")

    def step(self, number, title):
        self.write("")
        self.write(f"[{now()}] STEP {number}: {title}")
        self.write("-" * 80)


def run(cmd, log: Logger, cwd=None, timeout=None, check=False):
    log.write(f"$ {' '.join(map(str, cmd))}")
    p = subprocess.run(
        list(map(str, cmd)),
        cwd=str(cwd) if cwd else None,
        text=True,
        capture_output=True,
        timeout=timeout,
        shell=False,
    )
    if p.stdout:
        log.write(p.stdout.rstrip())
    if p.stderr:
        log.write(p.stderr.rstrip())
    if check and p.returncode != 0:
        raise RuntimeError(f"Command failed with rc={p.returncode}: {' '.join(map(str, cmd))}")
    return {
        "cmd": list(map(str, cmd)),
        "rc": p.returncode,
        "stdout": p.stdout,
        "stderr": p.stderr,
    }


def venv_python(venv_dir: Path) -> Path:
    if os.name == "nt":
        return venv_dir / "Scripts" / "python.exe"
    return venv_dir / "bin" / "python"


def load_json(path):
    if not path:
        return None
    p = Path(path)
    if not p.exists():
        return None
    return json.loads(p.read_text(encoding="utf-8"))


def extract_ort_version_from_text(text):
    if not text:
        return None
    m = re.search(r"ONNX\s*Runtime\s*([0-9]+(?:\.[0-9]+)+)", text, flags=re.I)
    if m:
        return m.group(1)
    return None


def derive_runtime_pins(args, recommendation):
    ort_version = args.ort_version
    qnn_pkg_version = args.qnn_package_version

    rec = None
    if recommendation:
        rec = recommendation.get("recommended") or recommendation

    if not ort_version and rec:
        ort_version = extract_ort_version_from_text(rec.get("sdk_versions", ""))

    return {
        "onnxruntime": ort_version,
        "onnxruntime_qnn": qnn_pkg_version,
    }


def download_artifact(recommendation, download_dir: Path, log: Logger):
    rec = recommendation.get("recommended") if recommendation else None
    if not rec:
        log.write("No recommendation file or recommended artifact entry found; skipping download.")
        return None

    url = rec.get("download_url")
    if not url:
        log.write("Recommended artifact has no download_url; skipping download.")
        return None

    download_dir.mkdir(parents=True, exist_ok=True)
    filename = url.split("?")[0].rstrip("/").split("/")[-1] or "artifact.zip"
    target = download_dir / filename

    log.write(f"Downloading artifact: {url}")
    log.write(f"Destination: {target}")

    req = urllib.request.Request(url, headers={"User-Agent": "qnn-clean-proof/1.0"})
    with urllib.request.urlopen(req, timeout=120) as r:
        target.write_bytes(r.read())

    log.write(f"Downloaded {target.stat().st_size} bytes")

    if zipfile.is_zipfile(target):
        extract_dir = download_dir / target.stem
        extract_dir.mkdir(parents=True, exist_ok=True)
        log.write(f"Extracting ZIP to: {extract_dir}")
        with zipfile.ZipFile(target, "r") as z:
            z.extractall(extract_dir)
        return extract_dir

    return target.parent


def create_helper_script(work_dir: Path):
    helper = work_dir / "_qnn_clean_proof_helper.py"
    helper.write_text(
        r'''
import argparse
import json
import os
import re
import sys
import traceback
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort


def jdefault(obj):
    try:
        return str(obj)
    except Exception:
        return repr(obj)


def status(name, state, detail=None, evidence=None):
    return {
        "name": name,
        "status": state,
        "detail": detail,
        "evidence": evidence or {},
    }


def compact(s):
    return re.sub(r"[^a-z0-9]+", "", (s or "").lower())


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
            epcontext_nodes.append({
                "name": n.name,
                "domain": n.domain,
                "attrs": {a.name: onnx.helper.get_attribute_value(a) for a in n.attribute},
            })

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


def register_qnn_provider():
    result = {
        "ort_version": getattr(ort, "__version__", None),
        "available_providers_before": ort.get_available_providers(),
        "plugin_import": None,
        "registration": None,
        "qnn_ep_devices": [],
        "provider_options": {},
    }

    try:
        import onnxruntime_qnn as qnn_ep
        result["plugin_import"] = "PASS"
        result["provider_options"]["library_path"] = qnn_ep.get_library_path()
        result["provider_options"]["backend_path"] = qnn_ep.get_qnn_htp_path()

        try:
            ort.register_execution_provider_library(
                "QNNExecutionProvider",
                qnn_ep.get_library_path(),
            )
            result["registration"] = "PASS"
        except Exception as e:
            result["registration"] = f"FAIL: {repr(e)}"

        try:
            devices = ort.get_ep_devices()
            result["all_ep_devices"] = [str(d) for d in devices]
            result["qnn_ep_devices"] = [str(d) for d in devices if getattr(d, "ep_name", None) == "QNNExecutionProvider"]
        except Exception as e:
            result["ep_devices_error"] = repr(e)

        result["available_providers_after"] = ort.get_available_providers()
        return result

    except Exception as e:
        result["plugin_import"] = f"FAIL: {repr(e)}"
        result["available_providers_after"] = ort.get_available_providers()
        return result


def make_session_options(provider_registration, disable_cpu_fallback=True):
    so = ort.SessionOptions()
    if disable_cpu_fallback:
        so.add_session_config_entry("session.disable_cpu_ep_fallback", "1")

    # Plugin style.
    try:
        devices = ort.get_ep_devices()
        qnn_devices = [d for d in devices if getattr(d, "ep_name", None) == "QNNExecutionProvider"]
        backend_path = provider_registration.get("provider_options", {}).get("backend_path")
        if qnn_devices and backend_path and hasattr(so, "add_provider_for_devices"):
            so.add_provider_for_devices(qnn_devices, {"backend_path": backend_path})
            return so, "plugin_add_provider_for_devices", None
    except Exception as e:
        plugin_error = repr(e)
    else:
        plugin_error = None

    return so, "provider_list_fallback", plugin_error


def load_session(path, provider_registration):
    so, style, plugin_error = make_session_options(provider_registration)

    evidence = {
        "path": str(path),
        "style": style,
        "plugin_error": plugin_error,
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
        return sess, status("session_load", "PASS", evidence=evidence)
    except Exception as e:
        evidence["error"] = repr(e)
        evidence["traceback"] = traceback.format_exc()
        return None, status("session_load", "FAIL", detail=repr(e), evidence=evidence)


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
    result = []
    for dim in shape:
        if isinstance(dim, int) and dim > 0:
            result.append(dim)
        elif isinstance(dim, str):
            key = compact(dim)
            if key in {"batch", "batchsize", "n"}:
                result.append(1)
            elif "sequence" in key or "seqlen" in key or key in {"s", "t"}:
                result.append(1)
            elif "audio" in key or "mel" in key or "feature" in key:
                result.append(80)
            else:
                result.append(1)
        else:
            result.append(1)

    # Avoid accidental huge dynamic tensors, but keep static Whisper shapes.
    safe = []
    for x in result:
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
        # token-ish inputs should start with a non-negative token.
        if "token" in name or "inputids" in name:
            arr[...] = 50258 if arr.size else 0
        return arr

    return np.zeros(shape, dtype=dtype)


def run_synthetic_inference(sess):
    evidence = {
        "inputs": [],
        "outputs": [],
    }

    feed = {}
    for inp in sess.get_inputs():
        arr = make_input_array(inp)
        feed[inp.name] = arr
        evidence["inputs"].append({
            "name": inp.name,
            "ort_type": inp.type,
            "ort_shape": inp.shape,
            "actual_shape": list(arr.shape),
            "dtype": str(arr.dtype),
        })

    try:
        out = sess.run(None, feed)
        for item in out:
            if hasattr(item, "shape"):
                evidence["outputs"].append({
                    "shape": list(item.shape),
                    "dtype": str(item.dtype),
                })
            else:
                evidence["outputs"].append({"type": type(item).__name__})
        return status("synthetic_inference", "PASS", evidence=evidence)
    except Exception as e:
        evidence["error"] = repr(e)
        evidence["traceback"] = traceback.format_exc()
        return status(
            "synthetic_inference",
            "FAIL_OR_NEEDS_ARTIFACT_SPECIFIC_INPUTS",
            detail=repr(e),
            evidence=evidence,
        )


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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--artifact", required=True)
    ap.add_argument("--probe", required=True)
    ap.add_argument("--recommendation")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    report = {
        "steps": [],
        "artifact": {},
        "provider": {},
        "sessions": {},
        "final": {},
    }

    probe = json.loads(Path(args.probe).read_text(encoding="utf-8"))
    recommendation = None
    if args.recommendation and Path(args.recommendation).exists():
        recommendation = json.loads(Path(args.recommendation).read_text(encoding="utf-8"))

    # Step 0
    report["steps"].append(status(
        "0_define_exact_target",
        "PASS",
        evidence={
            "probe_recommendation": probe.get("recommendation"),
            "host_os": probe.get("os"),
            "soc": probe.get("soc"),
            "qualcomm_devices_count": len(probe.get("qualcomm_devices", {}).get("pnp_candidates", [])),
            "artifact_recommendation": recommendation.get("recommended") if recommendation else None,
        },
    ))

    # Step 1
    report["steps"].append(status(
        "1_runtime_imports",
        "PASS",
        evidence={
            "python": sys.version,
            "onnxruntime_version": getattr(ort, "__version__", None),
            "available_providers": ort.get_available_providers(),
        },
    ))

    # Step 2 and 3
    files = find_model_files(args.artifact)
    metas = []
    meta_statuses = []
    for f in files["onnx_files"]:
        try:
            md = onnx_metadata(f)
            metas.append(md)
            meta_statuses.append(status("inspect_onnx", "PASS", evidence=md))
        except Exception as e:
            meta_statuses.append(status("inspect_onnx", "FAIL", detail=f"{f}: {repr(e)}"))

    artifact_type = infer_artifact_type(files, metas)
    report["artifact"] = {
        "files": files,
        "onnx_metadata": metas,
        "artifact_type_guess": artifact_type,
    }

    if files["onnx_files"]:
        report["steps"].append(status(
            "2_acquire_exact_artifact",
            "PASS",
            evidence={"artifact_root": str(args.artifact), "onnx_count": len(files["onnx_files"]), "bin_count": len(files["bin_files"])},
        ))
    else:
        report["steps"].append(status(
            "2_acquire_exact_artifact",
            "FAIL",
            detail="No .onnx files found under artifact directory.",
            evidence=files,
        ))

    report["steps"].append(status(
        "3_inspect_artifact_metadata_layout",
        "PASS" if files["onnx_files"] else "FAIL",
        evidence={"artifact_type_guess": artifact_type, "metadata_results": meta_statuses},
    ))

    # Step 4
    provider = register_qnn_provider()
    report["provider"] = provider
    qnn_visible = bool(provider.get("qnn_ep_devices")) or "QNNExecutionProvider" in provider.get("available_providers_after", [])
    report["steps"].append(status(
        "4_verify_qnn_provider_visibility",
        "PASS" if qnn_visible else "FAIL",
        detail=None if qnn_visible else "QNNExecutionProvider not visible/discoverable.",
        evidence=provider,
    ))

    # Choose encoder/decoder
    encoder_path = files["encoder_candidates"][0] if files["encoder_candidates"] else None
    decoder_path = files["decoder_candidates"][0] if files["decoder_candidates"] else None

    # Fallback if there are exactly two ONNX files but names do not include encoder/decoder.
    if not encoder_path and len(files["onnx_files"]) == 2:
        encoder_path = files["onnx_files"][0]
    if not decoder_path and len(files["onnx_files"]) == 2:
        decoder_path = files["onnx_files"][1]

    if not encoder_path and len(files["onnx_files"]) == 1:
        encoder_path = files["onnx_files"][0]

    # Step 5
    encoder_sess = None
    if encoder_path:
        encoder_sess, enc_status = load_session(encoder_path, provider)
        enc_status["name"] = "5_load_encoder_session"
        report["steps"].append(enc_status)
        report["sessions"]["encoder"] = enc_status
    else:
        report["steps"].append(status(
            "5_load_encoder_session",
            "FAIL",
            detail="No encoder candidate found.",
            evidence=files,
        ))

    # Step 6
    decoder_sess = None
    if decoder_path:
        decoder_sess, dec_status = load_session(decoder_path, provider)
        dec_status["name"] = "6_load_decoder_session"
        report["steps"].append(dec_status)
        report["sessions"]["decoder"] = dec_status
    else:
        report["steps"].append(status(
            "6_load_decoder_session",
            "SKIP_OR_NOT_APPLICABLE",
            detail="No decoder candidate found. Single-model artifact or incomplete artifact layout.",
            evidence=files,
        ))

    # Step 7
    if encoder_sess:
        syn = run_synthetic_inference(encoder_sess)
        syn["name"] = "7_smallest_encoder_inference"
        report["steps"].append(syn)
    else:
        report["steps"].append(status(
            "7_smallest_encoder_inference",
            "SKIP",
            detail="Encoder session did not load.",
        ))

    if decoder_sess:
        syn = run_synthetic_inference(decoder_sess)
        syn["name"] = "7_smallest_decoder_inference"
        report["steps"].append(syn)
    else:
        report["steps"].append(status(
            "7_smallest_decoder_inference",
            "SKIP_OR_NOT_APPLICABLE",
            detail="Decoder session did not load or decoder not present.",
        ))

    # Step 8
    report["steps"].append(status(
        "8_real_audio_smoke_test",
        "NEEDS_ARTIFACT_SPECIFIC_ADAPTER",
        detail=(
            "Generic script proved load/synthetic surfaces only. Real Whisper transcript proof "
            "requires artifact-specific preprocessing, tokenizer, decoder loop, and cache handling."
        ),
        evidence={
            "required_items": [
                "audio preprocessing/log-mel implementation",
                "tokenizer files/source",
                "decoder start/suppress/end token rules",
                "KV cache tensor construction",
                "loop termination criteria",
            ]
        },
    ))

    # Step 9
    hard_fail_steps = [
        s for s in report["steps"]
        if s["status"] == "FAIL"
    ]

    load_pass = any(s["name"] == "5_load_encoder_session" and s["status"] == "PASS" for s in report["steps"])
    decoder_required = bool(decoder_path)
    decoder_pass = any(s["name"] == "6_load_decoder_session" and s["status"] == "PASS" for s in report["steps"])

    if hard_fail_steps:
        final_status = "FAIL"
    elif load_pass and (not decoder_required or decoder_pass):
        final_status = "PASS_LOAD_PROOF__AUDIO_TRANSCRIPT_NOT_CLAIMED"
    else:
        final_status = "INCOMPLETE"

    report["steps"].append(status(
        "9_pass_fail_evidence",
        final_status,
        evidence={
            "cpu_fallback_disabled": True,
            "encoder_path": encoder_path,
            "decoder_path": decoder_path,
            "artifact_type_guess": artifact_type,
            "hard_fail_steps": [s["name"] for s in hard_fail_steps],
            "claim": (
                "This proves package/provider/artifact session compatibility only if encoder/decoder load passed. "
                "It does not prove full STT transcript quality unless Step 8 is replaced by an artifact-specific runner."
            ),
        },
    ))

    report["final"] = report["steps"][-1]

    Path(args.out).write_text(json.dumps(report, indent=2, default=jdefault), encoding="utf-8")
    print(json.dumps(report["final"], indent=2, default=jdefault))


if __name__ == "__main__":
    main()
''',
        encoding="utf-8",
    )
    return helper


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--probe", default="qnn_device_probe_report.json")
    ap.add_argument("--recommendation", default="qnn_public_artifact_recommendation.json")
    ap.add_argument("--artifact", help="Local artifact directory containing encoder/decoder ONNX files")
    ap.add_argument("--download-dir", default="qnn-artifacts", help="Directory for downloaded artifact ZIPs")
    ap.add_argument("--venv", default=DEFAULT_VENV)
    ap.add_argument("--out", default=REPORT_NAME)
    ap.add_argument("--log", default=LOG_NAME)
    ap.add_argument("--ort-version", help="Override ONNX Runtime version, e.g. 1.24.3")
    ap.add_argument("--qnn-package-version", help="Override onnxruntime-qnn package version, e.g. 2.1.0")
    ap.add_argument("--no-install", action="store_true", help="Reuse existing venv packages without pip install")
    args = ap.parse_args()

    log = Logger(Path(args.log))
    root = Path.cwd()
    venv_dir = root / args.venv
    py = venv_python(venv_dir)

    probe = load_json(args.probe)
    recommendation = load_json(args.recommendation)

    log.step(0, "Define exact target from qnn_device_probe_report.json")
    if not probe:
        raise SystemExit(f"Missing probe report: {args.probe}")

    log.write(json.dumps({
        "probe_recommendation": probe.get("recommendation"),
        "python_host": platform.platform(),
        "venv": str(venv_dir),
    }, indent=2))

    pins = derive_runtime_pins(args, recommendation)
    log.write("Runtime pins derived:")
    log.write(json.dumps(pins, indent=2))

    log.step(1, "Create/reuse .venv-qnn and install exact runtime packages")
    if not venv_dir.exists():
        run([sys.executable, "-m", "venv", str(venv_dir)], log, check=True)
    else:
        log.write(f"Venv already exists: {venv_dir}")

    run([str(py), "-m", "pip", "install", "--upgrade", "pip"], log, check=True)

    if not args.no_install:
        packages = []

        if pins["onnxruntime"]:
            packages.append(f"onnxruntime=={pins['onnxruntime']}")
        else:
            packages.append("onnxruntime")

        if pins["onnxruntime_qnn"]:
            packages.append(f"onnxruntime-qnn=={pins['onnxruntime_qnn']}")
        else:
            packages.append("onnxruntime-qnn")

        packages.extend(["onnx", "numpy"])

        run([str(py), "-m", "pip", "install", *packages], log, check=True)
    else:
        log.write("--no-install set; skipping pip install.")

    log.step(2, "Acquire exact artifact")
    artifact_dir = Path(args.artifact).resolve() if args.artifact else None

    if artifact_dir and artifact_dir.exists():
        log.write(f"Using existing artifact directory: {artifact_dir}")
    else:
        downloaded = download_artifact(recommendation, Path(args.download_dir), log)
        if downloaded:
            artifact_dir = Path(downloaded).resolve()
            log.write(f"Using downloaded/extracted artifact directory: {artifact_dir}")
        else:
            raise SystemExit(
                "No artifact directory provided and no downloadable recommended artifact found. "
                "Pass --artifact <path> or provide qnn_public_artifact_recommendation.json with download_url."
            )

    log.step(3, "Inspect artifact metadata/layout")
    log.write(f"Artifact root queued for helper inspection: {artifact_dir}")

    log.step(4, "Verify provider visibility")
    log.write("Provider registration/discovery runs inside venv helper.")

    log.step(5, "Load encoder/session")
    log.write("Encoder candidate detection and session load run inside venv helper with CPU fallback disabled.")

    log.step(6, "Load decoder/session")
    log.write("Decoder candidate detection and session load run inside venv helper with CPU fallback disabled.")

    log.step(7, "Run smallest inference/smoke test")
    log.write("Synthetic zero-input inference will be attempted from ONNX Runtime input metadata.")

    log.step(8, "Real audio smoke-test boundary")
    log.write(
        "Generic proof will mark real audio transcript as NEEDS_ARTIFACT_SPECIFIC_ADAPTER "
        "unless a future artifact-specific runner is added."
    )

    log.step(9, "Write final pass/fail evidence report")
    helper = create_helper_script(root)

    helper_cmd = [
        str(py),
        str(helper),
        "--artifact", str(artifact_dir),
        "--probe", str(Path(args.probe).resolve()),
        "--out", str(Path(args.out).resolve()),
    ]

    if recommendation and Path(args.recommendation).exists():
        helper_cmd.extend(["--recommendation", str(Path(args.recommendation).resolve())])

    result = run(helper_cmd, log, check=False)

    log.write("")
    log.write(f"Helper return code: {result['rc']}")
    log.write(f"Final JSON report: {Path(args.out).resolve()}")
    log.write(f"Log: {Path(args.log).resolve()}")

    if result["rc"] != 0:
        raise SystemExit(result["rc"])


if __name__ == "__main__":
    main()

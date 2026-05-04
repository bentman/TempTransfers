# qnn_device_probe.py
# Minimum dependencies: Python stdlib only.
# Purpose: collect host/device facts needed to choose/validate a Qualcomm QNN/ORT artifact path.

import json
import os
import platform
import re
import subprocess
import sys
from pathlib import Path


def run(cmd, timeout=20):
    try:
        p = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            shell=False,
        )
        return {
            "cmd": cmd,
            "rc": p.returncode,
            "stdout": p.stdout.strip(),
            "stderr": p.stderr.strip(),
        }
    except Exception as e:
        return {"cmd": cmd, "rc": -1, "stdout": "", "stderr": repr(e)}


def ps(command):
    return run([
        "powershell",
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-Command", command,
    ])


def wmic(args):
    return run(["wmic", *args])


def read_registry(path, name=None):
    if name:
        cmd = ["reg", "query", path, "/v", name]
    else:
        cmd = ["reg", "query", path]
    return run(cmd)


def parse_wmic_table(text):
    lines = [x.strip() for x in text.splitlines() if x.strip()]
    if len(lines) < 2:
        return []
    header = re.split(r"\s{2,}", lines[0])
    rows = []
    for line in lines[1:]:
        parts = re.split(r"\s{2,}", line)
        rows.append(dict(zip(header, parts)))
    return rows


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
    """
    Finds Qualcomm/NPU/Hexagon/HTP-related PnP devices and signed drivers.
    This is intentionally broad; exact naming varies by OEM/driver package.
    """
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


def get_installed_python_runtime():
    info = {}

    try:
        import onnxruntime as ort
        info["onnxruntime"] = {
            "installed": True,
            "version": getattr(ort, "__version__", None),
            "available_providers": getattr(ort, "get_available_providers", lambda: [])(),
        }

        # Newer plugin-style API may expose EP devices only after provider registration.
        try:
            info["onnxruntime"]["ep_devices_before_qnn_registration"] = [
                str(x) for x in ort.get_ep_devices()
            ]
        except Exception as e:
            info["onnxruntime"]["ep_devices_before_qnn_registration_error"] = repr(e)

    except Exception as e:
        info["onnxruntime"] = {
            "installed": False,
            "error": repr(e),
        }

    try:
        import onnxruntime_qnn as qnn_ep
        qnn = {
            "installed": True,
            "library_path": maybe_call(qnn_ep, "get_library_path"),
            "qnn_htp_path": maybe_call(qnn_ep, "get_qnn_htp_path"),
            "qnn_cpu_path": maybe_call(qnn_ep, "get_qnn_cpu_path"),
        }

        try:
            import onnxruntime as ort
            ort.register_execution_provider_library(
                "QNNExecutionProvider",
                qnn_ep.get_library_path(),
            )
            qnn["registration"] = "PASS"
            qnn["ep_devices_after_registration"] = [
                str(x) for x in ort.get_ep_devices()
            ]
        except Exception as e:
            qnn["registration"] = "FAIL"
            qnn["registration_error"] = repr(e)

        info["onnxruntime_qnn"] = qnn

    except Exception as e:
        info["onnxruntime_qnn"] = {
            "installed": False,
            "error": repr(e),
        }

    return info


def inspect_artifact_dir(path):
    """
    Optional artifact inspection.
    Pass a path to a Qualcomm AI Hub / HF artifact directory.
    Does not require onnx package; this only inspects file layout/names.
    """
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
            files.append({
                "relative": str(p.relative_to(root)),
                "suffix": p.suffix.lower(),
                "size_bytes": p.stat().st_size,
            })

    result["files"] = files

    suffixes = {f["suffix"] for f in files}
    names = [f["relative"].lower() for f in files]

    has_onnx = ".onnx" in suffixes
    has_bin = ".bin" in suffixes
    has_dlc = ".dlc" in suffixes

    if has_onnx and has_bin:
        result["artifact_guess"] = "precompiled_qnn_onnx / EPContext-style ONNX + QNN context binary"
    elif has_onnx:
        result["artifact_guess"] = "plain ONNX or QDQ ONNX; inspect graph metadata separately"
    elif has_bin:
        result["artifact_guess"] = "raw QNN context binary; probably not directly loadable by Python ORT without wrapper"
    elif has_dlc:
        result["artifact_guess"] = "QNN/Genie DLC; not the simplest Python ORT Whisper path"
    else:
        result["artifact_guess"] = "unknown"

    if has_onnx and has_bin:
        if not any(Path(n).name == "model.bin" for n in names):
            result["warnings"].append(
                "No model.bin found. Qualcomm samples often require preserving original .bin names/relative paths."
            )

    return result


def recommend(report):
    os_info = report.get("os", {})
    soc = report.get("soc", {})
    qdev = report.get("qualcomm_devices", {})
    py = report.get("python_runtime", {})
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

    is_windows = os_info.get("is_windows")
    is_arm64 = os_info.get("is_arm64")
    is_snapdragonish = any(x in cpu_name + pnp_text + drv_text for x in [
        "snapdragon", "qualcomm", "x1", "oryon", "hexagon", "npu", "neural", "htp"
    ])

    if is_windows and is_arm64 and is_snapdragonish:
        rec["host_class"] = "Windows ARM64 Snapdragon-class host"
        rec["runtime_path"] = "Prefer onnxruntime + onnxruntime-qnn plugin path, unless artifact metadata requires older built-in provider flow."
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

    ort = py.get("onnxruntime", {})
    qnn = py.get("onnxruntime_qnn", {})

    if not ort.get("installed"):
        rec["next_proof"].append("Install exact onnxruntime version required by artifact metadata.")
    else:
        rec["next_proof"].append(f"Captured onnxruntime version: {ort.get('version')}")

    if not qnn.get("installed"):
        rec["next_proof"].append("Install exact onnxruntime-qnn version required by artifact metadata.")
    elif qnn.get("registration") != "PASS":
        rec["blocking_findings"].append("onnxruntime-qnn installed but QNN provider registration failed.")
    else:
        rec["next_proof"].append("QNN provider registration passed; next load encoder/decoder with CPU fallback disabled.")

    if artifact:
        rec["next_proof"].append(f"Artifact guess: {artifact.get('artifact_guess')}")
        if artifact.get("warnings"):
            rec["blocking_findings"].extend(artifact["warnings"])
    else:
        rec["next_proof"].append("No artifact directory inspected. Add --artifact <path> once downloaded.")

    return rec


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


def maybe_call(module, func_name):
    try:
        f = getattr(module, func_name)
        return f()
    except Exception as e:
        return {"error": repr(e)}


def main():
    artifact_path = None
    out_path = "qnn_device_probe_report.json"

    args = sys.argv[1:]
    for i, arg in enumerate(args):
        if arg == "--artifact" and i + 1 < len(args):
            artifact_path = args[i + 1]
        if arg == "--out" and i + 1 < len(args):
            out_path = args[i + 1]

    report = {
        "os": get_os_info(),
        "soc": get_soc_info(),
        "qualcomm_devices": get_qualcomm_devices(),
        "python_runtime": get_installed_python_runtime(),
        "artifact": inspect_artifact_dir(artifact_path),
    }

    report["recommendation"] = recommend(report)

    print(json.dumps(report["recommendation"], indent=2))
    Path(out_path).write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"\nWrote full report: {out_path}")


if __name__ == "__main__":
    main()